unit transitionstate;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, fpjson, transitionstorage, transitionsecurity, transitionbackup;

type
  TTransitionState = (tsPrecheck, tsPrecheckFailed, tsPrepared,
    tsBackupInProgress, tsBackupVerified, tsInstalling, tsVerifying,
    tsCompleted, tsRollingBack, tsRolledBack, tsRecoveryRequired, tsAborted);

  TRelayEntryAction = (reaClaim, reaResume, reaCleanup, reaRecovery);

  ETransitionState = class(Exception);

  TLocalMetadata = record
    UUID, Hostname, IdentificationMode, SourceURL, SourceVersion,
    InstallDir, ConfigPath, KeyPath, CertificatePath, DatabasePath,
    ServiceState, TargetURL, TargetVersion: UTF8String;
  end;


  TTransitionStore = class
  private
    FRoot: UnicodeString;
    FLock: THandle;
    FIsolated: Boolean;
    FDirectoryPins: TDirectoryPins;
    procedure Log(const MessageText: string);
    function TryLog(const MessageText: string): Boolean;
    function InstallerPending: Boolean;
    procedure RequireStagedRelayImage;
    function Load: TJSONObject;
    procedure Save(Data: TJSONObject);
    function CommitState(Next: TTransitionState; const Diagnostic: string = '';
      const BackupDigest: string = ''; InitialServiceState: DWORD = 0;
      const InventoryDigest: string = ''): Boolean;
  public
    constructor Create(const Root: UnicodeString = '');
    destructor Destroy; override;
    // On return, state.json is committed. False reports a journal write failure only.
    function Initialize: Boolean;
    function ReadState: TTransitionState;
    // Same result as Initialize. Before recording ABORTED, the orchestrator must
    // restore normal operation of the historical agent if necessary.
    function Advance(Next: TTransitionState): Boolean;
    // Policy must come from trusted configuration, never the transition package.
    function RunFullPrecheck(const Policy: TTransitionSignerPolicy): Boolean;
    function ConfirmFixture(const Service: UnicodeString; const ServerURL, UUID, Version,
      ExpectedDigest, ReceivedDigest: string): Boolean;
    // No CLI invokes backup in 2C.1. Isolated execution accepts only a
    // dedicated fixture service, never the installed historical WAPTService.
    function RunBackup(const IsolatedService: UnicodeString = ''): Boolean;
    function RunFixtureCutover(const Service, Scenario: UnicodeString; const InstallerHash: string;
      Timeout: DWORD; const RestoreScope, InstalledFiles: TBackupPaths): Boolean;
    // The orchestrator supplies trusted roots and the exact additions recorded by the installer.
    function RunRollback(const RestoreScope, InstalledFiles: TBackupPaths;
      const IsolatedService: UnicodeString = ''): Boolean;
    // Persist local results without advancing. Only the future orchestrator may
    // enter PREPARED after all local, network and cryptographic checks pass.
    function RecordLocalMetadata(const Metadata: TLocalMetadata): Boolean;
    procedure StageHistoricalSnapshot(const Snapshot: UTF8String);
    procedure RecordAuthenticatedPayload(const ManifestDigest: string);
    procedure ProgramHistoricalRelay;
    procedure VerifyHistoricalRelay(const TransitionID: string);
    procedure PrepareFixtureHandoff(const SourceDir: UnicodeString; const Snapshot, ManifestDigest: UTF8String);
    // The fixture owns the returned exclusive admission handle until it finishes.
    function AcquireFixtureHandoff(Producer: THandle; const Database: UnicodeString; Timeout: DWORD): THandle;
    function HasBackup: Boolean;
    procedure RecordPrecheckFailure(const Diagnostic: string);
    property RootDirectory: UnicodeString read FRoot;
  end;

function ClassifyRelayEntry(State: TTransitionState; Claimed, InstallPending: Boolean): TRelayEntryAction;
function CanAdvance(Current, Next: TTransitionState): Boolean;

function IsSafeServerURL(const Value: string): Boolean;

implementation

uses
  Classes, DateUtils, URIParser, jsonparser, jsonscanner, IniFiles, transitionprecheck,
  transitionrestore, transitionbackupwindows, transitioninstall, transitionhandoff, transitionrelay;

const
  SchemaVersion = 1;
  MaxStateBytes = 65536;
  MOVEFILE_WRITE_THROUGH = $00000008; // Win32 flag absent from FPC 3.2.2.
  StateNames: array[TTransitionState] of string = (
    'PRECHECK', 'PRECHECK_FAILED', 'PREPARED', 'BACKUP_IN_PROGRESS',
    'BACKUP_VERIFIED', 'INSTALLING', 'VERIFYING', 'COMPLETED',
    'ROLLING_BACK', 'ROLLED_BACK', 'RECOVERY_REQUIRED', 'ABORTED');
  Successors: array[TTransitionState] of set of TTransitionState = (
    [tsPrecheckFailed, tsPrepared, tsRecoveryRequired],                         // PRECHECK
    [],                                                     // PRECHECK_FAILED
    [tsBackupInProgress, tsAborted, tsRecoveryRequired],                        // PREPARED
    [tsBackupVerified, tsRecoveryRequired, tsAborted],      // BACKUP_IN_PROGRESS
    [tsInstalling, tsAborted, tsRecoveryRequired],          // BACKUP_VERIFIED
    [tsVerifying, tsRollingBack, tsRecoveryRequired],       // INSTALLING
    [tsCompleted, tsRollingBack, tsRecoveryRequired],       // VERIFYING
    [],                                                     // COMPLETED
    [tsRolledBack, tsRecoveryRequired],                     // ROLLING_BACK
    [],                                                     // ROLLED_BACK
    [],                                                     // RECOVERY_REQUIRED
    []);                                                    // ABORTED

function ClassifyRelayEntry(State: TTransitionState; Claimed, InstallPending: Boolean): TRelayEntryAction;
begin
  case State of
    tsRecoveryRequired: Exit(reaRecovery);
    tsPrecheckFailed, tsCompleted, tsRolledBack, tsAborted:
      begin
        if InstallPending then
          raise ETransitionState.Create('Terminal state conflicts with an uncertain installer outcome');
        Exit(reaCleanup);
      end;
    tsBackupInProgress, tsInstalling, tsRollingBack: Exit(reaRecovery);
  end;
  if InstallPending then Exit(reaRecovery);
  if Claimed then Exit(reaResume);
  if State = tsPrecheck then Exit(reaClaim);
  raise ETransitionState.Create('Historical relay claim is missing from advanced state');
end;

function CanAdvance(Current, Next: TTransitionState): Boolean;
begin
  Result := Next in Successors[Current];
end;

function IsFailure(State: TTransitionState): Boolean;
begin
  Result := State in [tsPrecheckFailed, tsRecoveryRequired];
end;

function ParseState(const Name: string): TTransitionState;
begin
  for Result := Low(TTransitionState) to High(TTransitionState) do
    if Name = StateNames[Result] then
      Exit;
  raise ETransitionState.Create('Unknown transition state');
end;

function UtcNow: string;
var
  Time: TSystemTime;
begin
  GetSystemTime(Time);
  Result := DateToISO8601(SystemTimeToDateTime(Time), True);
end;

function IsUtc(const Value: string): Boolean;
var
  Time: TDateTime;
begin
  Result := (Length(Value) = 24) and TryISO8601ToDate(Value, Time, True) and
    (DateToISO8601(Time, True) = Value);
end;

function NewId: string;
var
  Id: TGUID;
begin
  if CreateGUID(Id) <> 0 then
    raise ETransitionState.Create('Could not create a transition identifier');
  Result := GUIDToString(Id);
end;

function Field(Data: TJSONObject; const Name: string; Kind: TJSONType): TJSONData;
begin
  Result := Data.Find(Name);
  if (Result = nil) or (Result.JSONType <> Kind) then
    raise ETransitionState.Create('Missing or invalid field: ' + Name);
end;

function EmptyFields(const Names: array of string): TJSONObject;
var
  Name: string;
begin
  Result := TJSONObject.Create;
  for Name in Names do
    Result.Add(Name);
end;

function IsSafeServerURL(const Value: string): Boolean;
var
  URL: TURI;
  C: Char;
begin
  Result := False;
  if not ((Pos('http://', Value) = 1) or (Pos('https://', Value) = 1)) then Exit;
  for C in Value do
    if not (C in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/', ':', '[', ']']) then Exit;
  URL := ParseURI(Value, False);
  Result := (URL.Host <> '') and (URL.Username = '') and (URL.Password = '');
end;

procedure ValidateMetadata(Data: TJSONObject; const Names: array of string;
  AllowStrings: Boolean; RequiredCount: Integer);
var
  Value: TJSONData;
  Name: string;
  I, Found: Integer;
  C: Char;
begin
  Found := 0;
  for I := 0 to High(Names) do
  begin
    Name := Names[I];
    Value := Data.Find(Name);
    if Value = nil then
    begin
      if I < RequiredCount then
        raise ETransitionState.Create('Missing state metadata field: ' + Name);
      Continue;
    end;
    Inc(Found);
    if Value.JSONType = jtNull then Continue;
    if not AllowStrings or (Value.JSONType <> jtString) or
       (Value.AsString = '') or (Length(Value.AsString) > 4096) then
      raise ETransitionState.Create('Invalid state metadata field: ' + Name);
    for C in Value.AsString do
      if C < #32 then
        raise ETransitionState.Create('Invalid state metadata field: ' + Name);
    if (Name = 'url') and not IsSafeServerURL(Value.AsString) then
      raise ETransitionState.Create('Unsafe server URL in state metadata');
  end;
  if Data.Count <> Found then
    raise ETransitionState.Create('Unexpected fields in state metadata');
end;

procedure AddMetadata(Data: TJSONObject; const M: TLocalMetadata);
begin
  with Data.Objects['host'] do
  begin
    Strings['uuid'] := M.UUID;
    Strings['hostname'] := M.Hostname;
    Strings['identification_mode'] := M.IdentificationMode;
  end;
  with Data.Objects['source'] do
  begin
    Strings['url'] := M.SourceURL;
    Strings['agent_version'] := M.SourceVersion;
    Strings['install_dir'] := M.InstallDir;
    Strings['config_path'] := M.ConfigPath;
    Strings['key_path'] := M.KeyPath;
    Strings['certificate_path'] := M.CertificatePath;
    Strings['db_path'] := M.DatabasePath;
    Strings['service_state'] := M.ServiceState;
  end;
  with Data.Objects['target'] do
  begin
    Strings['url'] := M.TargetURL;
    Strings['agent_version'] := M.TargetVersion;
  end;
end;

function IsConfirmationDigest(const Value: string): Boolean;
var
  C: AnsiChar;
begin
  if Length(Value) <> 64 then Exit(False);
  for C in Value do
    if not (C in ['0'..'9', 'a'..'f']) then Exit(False);
  Result := True;
end;

procedure Validate(Data: TJSONObject);
var
  Current, Previous: TTransitionState;
  CreatedAt, UpdatedAt, Identifier: string;
  Id: TGUID;
  Backup, Confirmation: TJSONObject;
begin
  if Field(Data, 'schema_version', jtNumber).AsJSON <> IntToStr(SchemaVersion) then
    raise ETransitionState.Create('Unsupported state schema version');

  Identifier := Field(Data, 'transition_id', jtString).AsString;
  if not TryStringToGUID(Identifier, Id) or (GUIDToString(Id) <> Identifier) then
    raise ETransitionState.Create('Invalid transition identifier');
  Current := ParseState(Field(Data, 'state', jtString).AsString);
  if Data.Find('payload_sha256') <> nil then
    if not IsConfirmationDigest(Field(Data, 'payload_sha256', jtString).AsString) then
      raise ETransitionState.Create('Invalid approved payload manifest digest');
  if Data.Find('relay_claimed') <> nil then
    if (Data.Find('payload_sha256') = nil) or not Field(Data, 'relay_claimed', jtBoolean).AsBoolean then
      raise ETransitionState.Create('Invalid historical relay claim');
  if Data.Count <> 11 + Ord(Current = tsCompleted) + Ord(Data.Find('payload_sha256') <> nil) +
    Ord(Data.Find('relay_claimed') <> nil) then
    raise ETransitionState.Create('Unexpected fields in state document');
  if Current = tsCompleted then
  begin
    Confirmation := TJSONObject(Field(Data, 'confirmation', jtObject));
    if (Confirmation.Count <> 2) or not IsConfirmationDigest(Field(Confirmation, 'inventory_sha256', jtString).AsString)
      or not IsUtc(Field(Confirmation, 'confirmed_at', jtString).AsString) then
      raise ETransitionState.Create('Invalid migration confirmation');
  end;
  if Current = tsPrecheck then
    Field(Data, 'previous_state', jtNull)
  else
  begin
    Previous := ParseState(Field(Data, 'previous_state', jtString).AsString);
    if not CanAdvance(Previous, Current) then
      raise ETransitionState.Create('Invalid previous state');
  end;
  CreatedAt := Field(Data, 'created_at', jtString).AsString;
  UpdatedAt := Field(Data, 'updated_at', jtString).AsString;
  if not IsUtc(CreatedAt) or not IsUtc(UpdatedAt) or (UpdatedAt < CreatedAt) then
    raise ETransitionState.Create('Invalid state timestamps');
  ValidateMetadata(TJSONObject(Field(Data, 'host', jtObject)),
    ['uuid', 'hostname', 'identification_mode'], True, 3);
  ValidateMetadata(TJSONObject(Field(Data, 'source', jtObject)),
    ['url', 'agent_version', 'install_dir', 'config_path', 'key_path',
     'certificate_path', 'db_path', 'service_state'], True, 3);
  ValidateMetadata(TJSONObject(Field(Data, 'target', jtObject)),
    ['url', 'agent_version'], True, 2);
  Backup := TJSONObject(Field(Data, 'backup', jtObject));
  if Backup.Find('service_initial_state') <> nil then
  begin
    Identifier := Field(Backup, 'service_initial_state', jtNumber).AsJSON;
    if (Identifier <> IntToStr(SERVICE_RUNNING)) and (Identifier <> IntToStr(SERVICE_STOPPED)) then
      raise ETransitionState.Create('Invalid initial backup service state');
  end
  else if (Current = tsBackupInProgress) or
    ((Current <> tsPrecheck) and (Previous = tsBackupInProgress)) then
    raise ETransitionState.Create('Missing initial backup service state');
  if Backup.Find('sha256') = nil then
  begin
    Field(Backup, 'verified', jtNull);
    if (Backup.Count <> 2 + Ord(Backup.Find('service_initial_state') <> nil)) then
      raise ETransitionState.Create('Invalid pending backup reference');
    Field(Backup, 'manifest', jtNull);
    if Current in [tsBackupVerified, tsInstalling, tsVerifying, tsCompleted, tsRollingBack, tsRolledBack] then
      raise ETransitionState.Create('Verified backup reference is required');
  end
  else if (Backup.Count <> 3 + Ord(Backup.Find('service_initial_state') <> nil)) or not Field(Backup, 'verified', jtBoolean).AsBoolean or
    (Field(Backup, 'manifest', jtString).AsString <> 'backup/manifest.json') or
    (Length(Field(Backup, 'sha256', jtString).AsString) <> 64) then
    raise ETransitionState.Create('Invalid verified backup reference');
  if (Current in [tsPrecheckFailed, tsRecoveryRequired]) or
    ((Current = tsAborted) and (Data.Strings['previous_state'] = 'BACKUP_IN_PROGRESS')) then
  begin
    Identifier := Field(Data, 'last_error', jtString).AsString;
    if (Identifier = '') or (Length(Identifier) > 512) or
       (Pos(#0, Identifier) > 0) or (Pos(#10, Identifier) > 0) or
       (Pos(#13, Identifier) > 0) then
      raise ETransitionState.Create('Invalid transition diagnostic');
  end
  else
    Field(Data, 'last_error', jtNull);
end;

constructor TTransitionStore.Create(const Root: UnicodeString);
begin
  inherited Create;
  FLock := INVALID_HANDLE_VALUE;
  FIsolated := Root <> '';
  FRoot := SecureTransitionRoot(Root, FDirectoryPins);
  try
    FLock := OpenStorageFile(FRoot + 'transition.lock', GENERIC_WRITE, 0, OPEN_ALWAYS);
    if FLock = INVALID_HANDLE_VALUE then RaiseLastOSError;
  except
    on E: EOSError do
      if E.ErrorCode = ERROR_SHARING_VIOLATION then
        raise ETransitionState.Create('Another process holds the transition lock')
      else raise;
  end;
  SecureDirectory(FRoot + 'logs');
  SecureDirectory(FRoot + 'backup');
  SecureDirectory(FRoot + 'staging');
  CheckStorageTree(FRoot + 'logs');
  CheckStorageTree(FRoot + 'backup');
  CheckStorageTree(FRoot + 'staging');
end;

function TTransitionStore.HasBackup: Boolean;
begin
  Result := DirectoryHasEntries(FRoot + 'backup');
end;

procedure TTransitionStore.RecordPrecheckFailure(const Diagnostic: string);
begin
  CommitState(tsPrecheckFailed, Diagnostic);
end;

destructor TTransitionStore.Destroy;
var
  I: Integer;
begin
  if FLock <> INVALID_HANDLE_VALUE then
    CloseHandle(FLock);
  for I := High(FDirectoryPins) downto Low(FDirectoryPins) do
    CloseHandle(FDirectoryPins[I]);
  inherited Destroy;
end;

procedure TTransitionStore.Log(const MessageText: string);
var
  Handle: THandle;
  Stream: THandleStream;
  Line: UTF8String;
begin
  Handle := OpenStorageFile(FRoot + 'logs\transition.log', FILE_APPEND_DATA,
    FILE_SHARE_READ, OPEN_ALWAYS);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    Stream := THandleStream.Create(Handle);
    try
      Line := UTF8Encode(UnicodeString(UtcNow + ' ' + MessageText + LineEnding));
      Stream.WriteBuffer(Line[1], Length(Line));
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

function TTransitionStore.TryLog(const MessageText: string): Boolean;
begin
  try
    Log(MessageText);
    Result := True;
  except
    // A journal failure must neither mask an exception nor undo a commit.
    Result := False;
  end;
end;

function TTransitionStore.Load: TJSONObject;
var
  Handle: THandle;
  ErrorCode: DWORD;
  Stream: THandleStream;
  Parser: TJSONParser;
  Data: TJSONData;
  Payload: UTF8String;
begin
  Result := nil;
  Handle := OpenStorageFile(FRoot + 'state.json', GENERIC_READ,
    FILE_SHARE_READ, OPEN_EXISTING);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    ErrorCode := GetLastError;
    if ErrorCode = ERROR_FILE_NOT_FOUND then
      Exit;
    RaiseLastOSError(ErrorCode);
  end;
  try
    Stream := THandleStream.Create(Handle);
    try
      if (Stream.Size <= 0) or (Stream.Size > MaxStateBytes) then
        raise ETransitionState.Create('Invalid state document size');
      Payload := '';
      SetLength(Payload, Stream.Size);
      Stream.ReadBuffer(Payload[1], Length(Payload));
      if Pos(#0, Payload) <> 0 then
        raise ETransitionState.Create('Invalid state JSON');
      Parser := TJSONParser.Create(Payload, [joUTF8, joStrict]);
      try
        try
          Data := Parser.Parse;
        except
          on E: EParserError do
            raise ETransitionState.Create('Invalid state JSON');
          on E: EJSON do
            raise ETransitionState.Create('Invalid state JSON');
        end;
        try
          if not (Data is TJSONObject) then
            raise ETransitionState.Create('State JSON must be an object');
          Validate(TJSONObject(Data));
          Result := TJSONObject(Data);
          Data := nil;
        finally
          Data.Free;
        end;
      finally
        Parser.Free;
      end;
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

procedure TTransitionStore.Save(Data: TJSONObject);
var
  TempName: UnicodeString;
  Payload: UTF8String;
  Handle: THandle;
  Stream: THandleStream;
begin
  Validate(Data);
  Payload := Data.FormatJSON + LineEnding;
  TempName := FRoot + 'state-' + UnicodeString(NewId) + '.tmp';
  Handle := OpenStorageFile(TempName, GENERIC_WRITE, 0, CREATE_NEW);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    try
      Stream := THandleStream.Create(Handle);
      try
        Stream.WriteBuffer(Payload[1], Length(Payload));
        if not FlushFileBuffers(Handle) then
          RaiseLastOSError;
      finally
        Stream.Free;
      end;
    finally
      CloseHandle(Handle);
    end;
    // Same-directory rename, with no cross-volume copy fallback.
    if not MoveFileExW(PWideChar(TempName), PWideChar(FRoot + 'state.json'),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
  except
    DeleteFileW(PWideChar(TempName));
    raise;
  end;
end;

function TTransitionStore.Initialize: Boolean;
var
  Data: TJSONObject;
  Stamp: string;
begin
  try
    Data := Load;
    try
      if Data <> nil then
        raise ETransitionState.Create('A transition state already exists');
      Stamp := UtcNow;
      Data := TJSONObject.Create;
      Data.Add('schema_version', SchemaVersion);
      Data.Add('transition_id', NewId);
      Data.Add('state', StateNames[tsPrecheck]);
      Data.Add('previous_state');
      Data.Add('created_at', Stamp);
      Data.Add('updated_at', Stamp);
      Data.Add('host', EmptyFields(['uuid', 'hostname', 'identification_mode']));
      Data.Add('source', EmptyFields(['url', 'agent_version', 'install_dir']));
      Data.Add('target', EmptyFields(['url', 'agent_version']));
      Data.Add('backup', EmptyFields(['verified', 'manifest']));
      Data.Add('last_error');
      Save(Data);
    finally
      Data.Free;
    end;
  except
    on E: Exception do
    begin
      TryLog('ERROR Initialize: ' + E.Message);
      raise;
    end;
  end;
  Result := TryLog('STATE PRECHECK');
end;

function TTransitionStore.ReadState: TTransitionState;
var
  Data: TJSONObject;
begin
  try
    Data := Load;
    try
      if Data = nil then
        raise ETransitionState.Create('No transition state exists');
      Result := ParseState(Data.Strings['state']);
    finally
      Data.Free;
    end;
  except
    on E: Exception do
    begin
      TryLog('ERROR Read: ' + E.Message);
      raise;
    end;
  end;
end;

procedure TTransitionStore.StageHistoricalSnapshot(const Snapshot: UTF8String);
var
  Handle: THandle;
  Stream: THandleStream;
  Path: UnicodeString;
begin
  if ReadState <> tsPrecheck then
    raise ETransitionState.Create('A pending PRECHECK state is required');
  if (Length(Snapshot) = 0) or (Length(Snapshot) > MaxStateBytes) then
    raise ETransitionState.Create('Invalid historical snapshot size');
  Path := FRoot + 'staging\historical.json';
  // Only native code writes the staging file, using the protected store.
  Handle := OpenStorageFile(Path, GENERIC_WRITE, 0, CREATE_NEW);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    try
      Stream := THandleStream.Create(Handle);
      try
        Stream.WriteBuffer(Snapshot[1], Length(Snapshot));
        if not FlushFileBuffers(Handle) then RaiseLastOSError;
      finally
        Stream.Free;
      end;
    finally
      CloseHandle(Handle);
    end;
  except
    DeleteFileW(PWideChar(Path));
    raise;
  end;
end;

procedure TTransitionStore.RequireStagedRelayImage;
var
  Image: UnicodeString;
  Size: DWORD;
begin
  SetLength(Image, 32768);
  Size := GetModuleFileNameW(0, PWideChar(Image), Length(Image));
  if (Size = 0) or (Size >= DWORD(Length(Image))) then RaiseLastOSError;
  SetLength(Image, Size);
  if not UnicodeSameText(Image, FRoot + 'staging\payload\patchs\wapttransition.exe') then
    raise ETransitionState.Create('Historical relay must run from protected staging');
end;

procedure TTransitionStore.RecordAuthenticatedPayload(const ManifestDigest: string);
var
  Data: TJSONObject;
  Locks: TPayloadLocks;
begin
  if FIsolated then raise ETransitionState.Create('Real relay is unavailable in fixture storage');
  if not IsConfirmationDigest(ManifestDigest) then
    raise ETransitionState.Create('Invalid approved manifest digest');
  RequireStagedRelayImage;
  LockVerifiedPayload(FRoot + 'staging\payload', ManifestDigest, Locks);
  try
    Initialize;
    Data := Load;
    try
      Data.Add('payload_sha256', ManifestDigest);
      Save(Data);
    finally
      Data.Free;
    end;
  finally
    ReleasePayload(Locks);
  end;
end;

procedure TTransitionStore.ProgramHistoricalRelay;
var
  Data: TJSONObject;
begin
  if FIsolated then raise ETransitionState.Create('Real relay is unavailable in fixture storage');
  Data := Load;
  try
    if (Data = nil) or (ParseState(Data.Strings['state']) <> tsPrecheck) or
      (Data.Find('payload_sha256', jtString) = nil) then
      raise ETransitionState.Create('No fully staged historical relay');
    if (Data.Find('relay_claimed') <> nil) or InstallerPending then
      raise ETransitionState.Create('Historical relay is already claimed or installation is uncertain');
    try
      ScheduleHistoricalRelay(FRoot, Data.Strings['transition_id'], Data.Strings['payload_sha256']);
    except
      on E: Exception do
      begin
        TryLog('ERROR historical relay programming: ' + E.Message);
        raise;
      end;
    end;
  finally
    Data.Free;
  end;
end;

procedure TTransitionStore.VerifyHistoricalRelay(const TransitionID: string);
var
  Data: TJSONObject;
  Locks: TPayloadLocks;
  Current: TTransitionState;
  Action: TRelayEntryAction;
begin
  if FIsolated then raise ETransitionState.Create('Real relay is unavailable in fixture storage');
  Data := Load;
  try
    if (Data = nil) or (Data.Strings['transition_id'] <> TransitionID) then
      raise ETransitionState.Create('No matching historical relay to verify');
    RequireStagedRelayImage;
    LockVerifiedPayload(FRoot + 'staging\payload', Data.Get('payload_sha256', ''), Locks);
    try
      Current := ParseState(Data.Strings['state']);
      Action := ClassifyRelayEntry(Current, Data.Find('relay_claimed') <> nil, InstallerPending);
      if Action = reaClaim then
      begin
        Data.Add('relay_claimed', True);
        Save(Data);
        TryLog('Historical relay trigger claimed');
      end;
      if (Action = reaRecovery) and (Current <> tsRecoveryRequired) then
        CommitState(tsRecoveryRequired, 'Historical relay interrupted in a phase requiring recovery');
      try
        // A consumed task remains registered but disabled while its transition is unfinished.
        RetireHistoricalRelay(FRoot, TransitionID, Action = reaCleanup);
      except
        on E: Exception do
        begin
          TryLog('ERROR historical relay task cleanup: ' + E.Message);
          raise;
        end;
      end;
      if Action = reaRecovery then
        raise ETransitionState.Create('Historical relay requires recovery; disabled task and data preserved');
      if Action = reaCleanup then TryLog('Historical relay task removed')
      else if Action = reaResume then TryLog('Historical relay already claimed; verified without taking control again')
      else TryLog('Historical relay payload verified and trigger disabled');
    finally
      ReleasePayload(Locks);
    end;
  finally
    Data.Free;
  end;
end;

procedure TTransitionStore.PrepareFixtureHandoff(const SourceDir: UnicodeString;
  const Snapshot, ManifestDigest: UTF8String);
var
  Data: TJSONObject;
begin
  if not FIsolated then raise ETransitionState.Create('Handoff is restricted to isolated fixtures');
  if not IsConfirmationDigest(ManifestDigest) then raise ETransitionState.Create('Invalid approved manifest digest');
  Initialize;
  StagePayload(SourceDir, FRoot + 'staging\payload', ManifestDigest);
  StageHistoricalSnapshot(Snapshot);
  Data := Load;
  try
    Data.Add('payload_sha256', ManifestDigest);
    Save(Data);
  finally
    Data.Free;
  end;
  TryLog('PRECHECK Isolated handoff payload staged and verified');
end;

function TTransitionStore.AcquireFixtureHandoff(Producer: THandle;
  const Database: UnicodeString; Timeout: DWORD): THandle;
var
  Data: TJSONObject;
  Ready: THandle;
begin
  if not FIsolated then raise ETransitionState.Create('Handoff is restricted to isolated fixtures');
  Data := Load;
  try
    if (Data = nil) or (ParseState(Data.Strings['state']) <> tsPrecheck) or
      (Data.Find('payload_sha256', jtString) = nil) then
      raise ETransitionState.Create('No fully staged fixture handoff');
    WaitForProducer(Producer, Timeout);
    Result := OpenStorageFile(FRoot + 'staging\fixture-admission.lock', GENERIC_WRITE, 0, OPEN_ALWAYS);
    if Result = INVALID_HANDLE_VALUE then
      raise ETransitionState.Create('Fixture task admission is busy');
    try
      CheckStagedPayload(FRoot + 'staging\payload', Data.Strings['payload_sha256']);
      VerifyBackupDatabase(Database);
      Ready := OpenStorageFile(FRoot + 'staging\fixture-handoff.ready', GENERIC_WRITE, 0, CREATE_NEW);
      if Ready = INVALID_HANDLE_VALUE then raise ETransitionState.Create('Fixture handoff already taken or cannot persist');
      try
        if not FlushFileBuffers(Ready) then RaiseLastOSError;
      finally
        CloseHandle(Ready);
      end;
      TryLog('PRECHECK Isolated handoff accepted');
    except
      CloseHandle(Result);
      raise;
    end;
  finally
    Data.Free;
  end;
end;

function TTransitionStore.RecordLocalMetadata(const Metadata: TLocalMetadata): Boolean;
var
  Data: TJSONObject;
  Stamp: string;
begin
  Data := Load;
  try
    if (Data = nil) or (ParseState(Data.Strings['state']) <> tsPrecheck) then
      raise ETransitionState.Create('A pending PRECHECK state is required');
    AddMetadata(Data, Metadata);
    Stamp := UtcNow;
    if Stamp > Data.Strings['updated_at'] then
      Data.Strings['updated_at'] := Stamp;
    Save(Data);
  finally
    Data.Free;
  end;
  Result := TryLog('PRECHECK Local checks passed');
end;

function TTransitionStore.InstallerPending: Boolean;
begin
  Result := GetFileAttributesW(PWideChar(FRoot + 'staging\installer.pending')) <> INVALID_FILE_ATTRIBUTES;
  if not Result then Result := GetLastError <> ERROR_FILE_NOT_FOUND;
end;

function TTransitionStore.Advance(Next: TTransitionState): Boolean;
var
  Data: TJSONObject;
  Digest: string;
begin
  if (Next = tsRollingBack) and InstallerPending then
    raise ETransitionState.Create('Installer outcome remains uncertain; rollback blocked');
  if Next = tsPrepared then
    raise ETransitionState.Create('PREPARED requires successful full prechecks');
  if Next = tsCompleted then
    raise ETransitionState.Create('COMPLETED requires confirmation from the target server');
  if Next = tsRolledBack then
    raise ETransitionState.Create('ROLLED_BACK requires a fully verified restoration');
  if Next in [tsBackupInProgress, tsBackupVerified] then
    raise ETransitionState.Create('Backup states require the protected backup workflow');
  if (Next = tsAborted) and (ReadState in [tsBackupInProgress, tsBackupVerified]) then
    raise ETransitionState.Create('Restore normal agent operation before recording ABORTED');
  if Next = tsInstalling then
  begin
    try
      Data := Load;
      try
        if (Data = nil) or (ParseState(Data.Strings['state']) <> tsBackupVerified) then
          raise ETransitionState.Create('Forbidden transition: installation requires a verified backup');
        Digest := VerifyBackup(FRoot + 'backup', Data.Strings['transition_id']);
        if Digest <> Data.Objects['backup'].Strings['sha256'] then
          raise ETransitionState.Create('Verified backup manifest no longer matches state');
      finally
        Data.Free;
      end;
    except
      on E: Exception do
      begin
        TryLog('ERROR Advance: ' + E.Message);
        raise;
      end;
    end;
  end;
  Result := CommitState(Next);
end;

function TTransitionStore.RunBackup(const IsolatedService: UnicodeString): Boolean;
var
  Data: TJSONObject;
  Source: TJSONObject;
  ConfigLines, Shortcuts: TStringList;
  Ini: TMemIniFile;
  Roots: TBackupPaths;
  InstallDir, ConfigPath, WorkingDir, DB, Cache, Path, Service: UnicodeString;
  TransitionID, Digest, Diagnostic, ApprovedDigest: string;
  Locks: TPayloadLocks;
  InitialServiceState: DWORD;
  HistoricalService: TWindowsHistoricalService;
  PayloadSize: QWord;
  FailureState: TTransitionState;
  Port: Integer;
  I: Integer;
  StartedJournal, FinishedJournal: Boolean;

  procedure IncludeConfigured(const Name: string);
  begin
    if Ini.ValueExists('global', Name) then
      AddBackupSource(Roots, ResolvePath(UTF8Decode(Ini.ReadString('global', Name, '')), WorkingDir));
  end;

begin
  if FIsolated then
  begin
    if Pos('PADIT_BackupTest_', IsolatedService) <> 1 then
      raise ETransitionState.Create('Isolated backup requires a dedicated test service');
    Service := IsolatedService;
  end
  else
  begin
    if IsolatedService <> '' then raise ETransitionState.Create('Unexpected isolated service override');
    Service := 'WAPTService';
  end;
  Data := Load;
  try
    if (Data = nil) or (ParseState(Data.Strings['state']) <> tsPrepared) then
      raise ETransitionState.Create('Backup requires PREPARED');
    if HasBackup then raise ETransitionBackup.Create('A previous backup exists and will be preserved');
    TransitionID := Data.Strings['transition_id'];
    ApprovedDigest := Data.Get('payload_sha256', '');
    Source := Data.Objects['source'];
    InstallDir := UTF8Decode(Field(Source, 'install_dir', jtString).AsString);
    ConfigPath := UTF8Decode(Field(Source, 'config_path', jtString).AsString);
    DB := UTF8Decode(Field(Source, 'db_path', jtString).AsString);
    WorkingDir := InstallDir;
    if not FIsolated and RegistryValue('SYSTEM\CurrentControlSet\Services\WAPTService\Parameters',
      'AppDirectory', 0, Path) and (Path <> '') then WorkingDir := ResolvePath(Path, InstallDir);
    // Historical WAPT uses dirname(config_filename) + 'cache', including custom INIs.
    Cache := IncludeTrailingPathDelimiter(ExtractFileDir(ConfigPath)) + 'cache';
    Roots := nil;
    AddBackupSource(Roots, InstallDir);
    AddBackupSource(Roots, ConfigPath);
    AddBackupSource(Roots, DB);
    AddBackupSource(Roots, UTF8Decode(Field(Source, 'key_path', jtString).AsString));
    AddBackupSource(Roots, UTF8Decode(Field(Source, 'certificate_path', jtString).AsString));
    ConfigLines := TStringList.Create;
    Ini := TMemIniFile.Create('');
    try
      ConfigLines.Text := RawByteString(ReadDocument(ConfigPath));
      Ini.SetStrings(ConfigLines);
      if not TryStrToInt(Ini.ReadString('global', 'waptservice_port', '8088'), Port) or
        (Port < 1) or (Port > 65535) then raise ETransitionBackup.Create('Invalid WAPT service port');
      IncludeConfigured('private_dir');
      IncludeConfigured('persistent_root_dir');
      IncludeConfigured('public_certs_dir');
      IncludeConfigured('log_directory');
      Path := UTF8Decode(Ini.ReadString('global', 'verify_cert', ''));
      if (Path <> '') and (Path <> '0') and (Path <> '1') and
        not UnicodeSameText(Path, 'true') and not UnicodeSameText(Path, 'false') then
        AddBackupSource(Roots, ResolvePath(Path, WorkingDir));
    finally
      Ini.Free;
      ConfigLines.Free;
    end;
  finally
    Data.Free;
  end;
  if not FIsolated then
  begin
    Shortcuts := TStringList.Create;
    try
      DiscoverWaptShortcuts(InstallDir, Shortcuts);
      for I := 0 to Shortcuts.Count - 1 do AddBackupSource(Roots, UTF8Decode(Shortcuts[I]));
    finally
      Shortcuts.Free;
    end;
    RequireScheduledWaptIdle(InstallDir);
  end;
  if not FIsolated then
    LockVerifiedPayload(FRoot + 'staging\payload', ApprovedDigest, Locks);
  try
    PayloadSize := 0;
    if not FIsolated then
      PayloadSize := FileSizeRequired(FRoot + 'staging\payload\waptagent.exe', 'Missing staged installer');
    CheckBackupSpace(FRoot + 'backup', InstallDir, Roots, Cache, PayloadSize);
    RequireRestorableServiceAccount(Service);
    HistoricalService := nil;
    if not FIsolated then HistoricalService := TWindowsHistoricalService.Create(Service, DB, Port);
    try
      if FIsolated then
      begin
        InitialServiceState := BackupServiceState(Service);
        RequireWaptIdle(Port, InitialServiceState);
      end
      else
        InitialServiceState := WaitForHistoricalIdle(HistoricalService, 15 * 60 * 1000);
      StartedJournal := CommitState(tsBackupInProgress, '', '', InitialServiceState);
      try
        if FIsolated then
        begin
          StopBackupService(Service);
          RequireWaptIdle(Port, BackupServiceState(Service));
        end
        else
          TakeControlOfHistoricalService(HistoricalService, InitialServiceState);
        CaptureBackup(FRoot + 'backup', Cache, DB, InstallDir, TransitionID, Roots,
          InitialServiceState, Service);
        if BackupServiceState(Service) <> SERVICE_STOPPED then
          raise ETransitionBackup.Create('Historical service resumed during backup');
        if FIsolated then RequireWaptIdle(Port, SERVICE_STOPPED)
        else TakeControlOfHistoricalService(HistoricalService, SERVICE_STOPPED);
        Digest := VerifyBackup(FRoot + 'backup', TransitionID);
        FinishedJournal := CommitState(tsBackupVerified, '', Digest);
      except
        on E: Exception do
        begin
          Diagnostic := 'Backup failed after entering BACKUP_IN_PROGRESS';
          if (E is ETransitionBackup) or (E is ELocalPrecheck) then Diagnostic := E.Message;
          FailureState := tsAborted;
          try
            if FIsolated then
            begin
              RestoreBackupService(Service, InitialServiceState);
              if InitialServiceState = SERVICE_RUNNING then RequireWaptIdle(Port, InitialServiceState);
            end
            else
              RestoreHistoricalService(HistoricalService, InitialServiceState);
          except
            on RestoreError: Exception do
            begin
              FailureState := tsRecoveryRequired;
              Diagnostic := Copy(Diagnostic, 1, 350) + '; service restoration failed';
              if (RestoreError is ETransitionBackup) or (RestoreError is ELocalPrecheck) then
                Diagnostic := Diagnostic + ': ' + RestoreError.Message;
            end;
          end;
          CommitState(FailureState, Diagnostic);
          raise;
        end;
      end;
    finally
      HistoricalService.Free;
    end;
  finally
    if not FIsolated then ReleasePayload(Locks);
  end;
  Result := StartedJournal and FinishedJournal;
end;

function TTransitionStore.RunFixtureCutover(const Service, Scenario: UnicodeString;
  const InstallerHash: string; Timeout: DWORD; const RestoreScope, InstalledFiles: TBackupPaths): Boolean;
var
  Data, Source: TJSONObject;
  State: TTransitionState;
  InstallerPath, InstallDir, KeyPath, CertPath, ConfigPath, DatabasePath: UnicodeString;
  Installer, Key, Cert, Marker: THandle;
  Code, InitialState: DWORD;
  PhaseJournal, BackupJournal, Ambiguous, MarkerOwned: Boolean;
  Port: Integer;
  Lines: TStringList;
  Ini: TMemIniFile;
  Arguments, FixtureDir: UnicodeString;
begin
  if not FIsolated or (Pos('PADIT_BackupTest_', Service) <> 1) then
    raise ETransitionState.Create('Cutover is limited to an isolated fixture service');
  if (Scenario <> 'nominal') and (Scenario <> 'exit') and
     (Scenario <> 'timeout') and (Scenario <> 'invalid') then
    raise ETransitionState.Create('Unknown cutover fixture scenario');
  State := ReadState;
  if (State = tsInstalling) or InstallerPending then
    raise ETransitionState.Create('Prior installer outcome is uncertain; do not retry or roll back');
  if not (State in [tsPrepared, tsBackupVerified]) then
    raise ETransitionState.Create('Cutover requires PREPARED or BACKUP_VERIFIED');
  FixtureDir := IncludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FRoot)));
  Data := Load;
  try
    Source := Data.Objects['source'];
    InstallDir := UTF8Decode(Field(Source, 'install_dir', jtString).AsString);
    ConfigPath := UTF8Decode(Field(Source, 'config_path', jtString).AsString);
    KeyPath := UTF8Decode(Field(Source, 'key_path', jtString).AsString);
    CertPath := UTF8Decode(Field(Source, 'certificate_path', jtString).AsString);
    DatabasePath := UTF8Decode(Field(Source, 'db_path', jtString).AsString);
    if not UnicodeSameText(InstallDir, FixtureDir + 'agent') or
       not UnicodeSameText(ConfigPath, InstallDir + '\wapt-get.ini') or
       not UnicodeSameText(KeyPath, InstallDir + '\private\machine.pem') or
       not UnicodeSameText(CertPath, InstallDir + '\private\machine.crt') or
       not UnicodeSameText(Copy(ExpandFileName(DatabasePath), 1, Length(FixtureDir)), FixtureDir) then
      raise ETransitionState.Create('Cutover fixture paths do not match the isolated layout');
  finally
    Data.Free;
  end;
  BackupJournal := True;
  if State = tsPrepared then BackupJournal := RunBackup(Service);
  Installer := INVALID_HANDLE_VALUE;
  Key := INVALID_HANDLE_VALUE;
  Cert := INVALID_HANDLE_VALUE;
  Ambiguous := False;
  MarkerOwned := False;
  Data := Load;
  try
    InitialState := Field(Data.Objects['backup'], 'service_initial_state', jtNumber).AsInteger;
    try
      if BackupServiceState(Service) <> SERVICE_STOPPED then
        raise ETransitionState.Create('Fixture service resumed before installer launch');
      RequireWaptIdle(0, SERVICE_STOPPED);
      InstallerPath := FRoot + 'staging\fixture-installer.exe';
      Installer := OpenStorageFile(InstallerPath, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
      if (Installer = INVALID_HANDLE_VALUE) or (FileSHA256(Installer) <> InstallerHash) then
        raise ETransitionInstall.Create('Staged fixture installer failed the final SHA256 check');
      CheckLocalPath(KeyPath);
      CheckLocalPath(CertPath);
      Key := CreateFileW(PWideChar(KeyPath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, 0);
      Cert := CreateFileW(PWideChar(CertPath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, 0);
      if (Key = INVALID_HANDLE_VALUE) or (Cert = INVALID_HANDLE_VALUE) then
        raise ETransitionInstall.Create('Cannot protect fixture identity during cutover');
      Marker := OpenStorageFile(FRoot + 'staging\installer.pending', GENERIC_WRITE, 0, CREATE_NEW);
      if Marker = INVALID_HANDLE_VALUE then
        raise ETransitionInstall.Create('Cannot create protected installer uncertainty marker');
      MarkerOwned := True;
      try
        if not FlushFileBuffers(Marker) then
          raise ETransitionInstall.Create('Cannot flush installer uncertainty marker');
      finally
        CloseHandle(Marker);
      end;
      PhaseJournal := Advance(tsInstalling);
      State := tsInstalling;
      Arguments := 'fixture-install ' + Scenario + ' "' + InstallDir + '"';
      try
        Code := RunLockedInstaller(InstallerPath, Arguments, Timeout);
        CheckSetupExit(Code);
      except
        on E: EInstallUncertain do
        begin
          Ambiguous := True;
          TryLog('ERROR INSTALLING: ' + E.Message);
          raise;
        end;
      end;
      if not DeleteFileW(PWideChar(FRoot + 'staging\installer.pending')) then
      begin
        Ambiguous := True;
        raise EInstallUncertain.Create('Cannot clear the installer uncertainty marker');
      end;
      MarkerOwned := False;
      Result := CommitState(tsVerifying) and PhaseJournal and BackupJournal;
      State := tsVerifying;
      if (BackupServiceState(Service) <> SERVICE_STOPPED) or
        (ReadDocument(InstallDir + '\padit-fixture.txt') <> 'PADIT fixture verified') then
        raise ETransitionInstall.Create('Local fixture verification failed');
    except
      on E: Exception do
      begin
        if Key <> INVALID_HANDLE_VALUE then CloseHandle(Key);
        if Cert <> INVALID_HANDLE_VALUE then CloseHandle(Cert);
        Key := INVALID_HANDLE_VALUE;
        Cert := INVALID_HANDLE_VALUE;
        if not Ambiguous then
        begin
          if MarkerOwned and not DeleteFileW(PWideChar(FRoot + 'staging\installer.pending')) then
            raise EInstallUncertain.Create('Cannot clear the installer uncertainty marker');
          if State in [tsInstalling, tsVerifying] then
          begin
            TryLog('ERROR CUTOVER: ' + E.Message);
            RunRollback(RestoreScope, InstalledFiles, Service);
          end
          else
          begin
            try
              RestoreBackupService(Service, InitialState);
              if InitialState = SERVICE_RUNNING then
              begin
                Lines := TStringList.Create;
                Ini := TMemIniFile.Create('');
                try
                  Lines.Text := RawByteString(ReadDocument(ConfigPath));
                  Ini.SetStrings(Lines);
                  if not TryStrToInt(Ini.ReadString('global', 'waptservice_port', '8088'), Port)
                    or (Port < 1) or (Port > 65535) then
                    raise ETransitionInstall.Create('Invalid fixture service port');
                  RequireWaptIdle(Port, BackupServiceState(Service));
                finally
                  Ini.Free;
                  Lines.Free;
                end;
              end;
            except
              CommitState(tsRecoveryRequired, 'Cannot restore fixture service after pre-launch failure');
              raise;
            end;
            TryLog('ERROR CUTOVER: ' + E.Message);
            CommitState(tsAborted);
          end;
        end;
        raise;
      end;
    end;
  finally
    if Key <> INVALID_HANDLE_VALUE then CloseHandle(Key);
    if Cert <> INVALID_HANDLE_VALUE then CloseHandle(Cert);
    if Installer <> INVALID_HANDLE_VALUE then CloseHandle(Installer);
    Data.Free;
  end;
end;

function TTransitionStore.RunRollback(const RestoreScope, InstalledFiles: TBackupPaths;
  const IsolatedService: UnicodeString): Boolean;
var
  Data, Source, Manifest: TJSONObject;
  Previous: TTransitionState;
  BackupRoot, InstallDir, ConfigPath, Database, Cache, Service, Edition, Path,
    FixtureRoot: UnicodeString;
  TransitionID, Digest, Diagnostic: string;
  InitialState, Status: DWORD;
  StartedJournal: Boolean;
  Port: Integer;
  Lines: TStringList;
  Ini: TMemIniFile;

  procedure ReadConfig;
  begin
    Lines.Text := RawByteString(ReadDocument(ConfigPath));
    Ini.Clear;
    Ini.SetStrings(Lines);
    if not TryStrToInt(Ini.ReadString('global', 'waptservice_port', '8088'), Port) or
      (Port < 1) or (Port > 65535) then
      raise ETransitionState.Create('Invalid local WAPT service port');
  end;

begin
  if InstallerPending then
    raise ETransitionState.Create('Installer outcome remains uncertain; rollback blocked');
  if FIsolated then
  begin
    if Pos('PADIT_BackupTest_', IsolatedService) <> 1 then
      raise ETransitionState.Create('Rollback requires a dedicated fixture service');
    Service := IsolatedService;
    FixtureRoot := IncludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(FRoot)));
    for Path in RestoreScope do
      if not UnicodeSameText(Copy(ExpandFileName(Path), 1, Length(FixtureRoot)), FixtureRoot) then
        raise ETransitionState.Create('Isolated rollback scope is outside its fixture');
  end
  else
  begin
    if IsolatedService <> '' then raise ETransitionState.Create('Unexpected fixture service override');
    Service := 'WAPTService';
  end;
  Data := Load;
  if Data = nil then raise ETransitionState.Create('No transition is available for rollback');
  try
    Previous := ParseState(Data.Strings['state']);
    if not (Previous in [tsInstalling, tsVerifying, tsRollingBack]) then
      raise ETransitionState.Create('Rollback requires INSTALLING, VERIFYING or ROLLING_BACK');
    try
      Source := Data.Objects['source'];
      InstallDir := UTF8Decode(Field(Source, 'install_dir', jtString).AsString);
      ConfigPath := UTF8Decode(Field(Source, 'config_path', jtString).AsString);
      Database := UTF8Decode(Field(Source, 'db_path', jtString).AsString);
      Cache := IncludeTrailingPathDelimiter(ExtractFileDir(ConfigPath)) + 'cache';
      TransitionID := Data.Strings['transition_id'];
      Digest := Data.Objects['backup'].Strings['sha256'];
      BackupRoot := FRoot + 'backup';
      Manifest := LoadVerifiedBackup(BackupRoot, TransitionID, Digest);
      try
        InitialState := Field(Data.Objects['backup'], 'service_initial_state', jtNumber).AsInteger;
        if Manifest.Integers['service_initial_state'] <> Integer(InitialState) then
          raise ETransitionState.Create('Initial service state differs from verified backup');
        CheckRestorePaths(Manifest, RestoreScope, ExcludeTrailingPathDelimiter(FRoot), InstallDir, Cache, InstalledFiles);
        Lines := TStringList.Create;
        Ini := TMemIniFile.Create('');
        try
          if not FIsolated then RequireScheduledWaptIdle(InstallDir);
          Status := BackupServiceState(Service, True);
          if Status = SERVICE_RUNNING then ReadConfig else Port := 8088;
          if Status = 0 then RequireWaptIdle(Port, SERVICE_STOPPED)
          else RequireWaptIdle(Port, Status);
          StartedJournal := True;
          if Previous <> tsRollingBack then StartedJournal := CommitState(tsRollingBack);
          if Status <> 0 then StopBackupService(Service);
          RequireWaptIdle(Port, SERVICE_STOPPED);
          if not FIsolated then
          begin
            RequireRollbackProcessesIdle;
            RequireScheduledWaptIdle(InstallDir);
          end;
          RestoreVerifiedFiles(BackupRoot, InstallDir, Cache, TransitionID, Digest, RestoreScope, InstalledFiles);
          if not FIsolated then
          begin
            RequireRollbackProcessesIdle;
            RequireScheduledWaptIdle(InstallDir);
          end;
          RestoreWaptServiceConfig(BackupRoot, Service, Manifest.Arrays['entries']);
          if FIsolated then RestoreWaptRegistry(BackupRoot, Manifest.Arrays['entries'], Service)
          else
          begin
            RestoreWaptRegistry(BackupRoot, Manifest.Arrays['entries']);
            RestoreWaptPath(BackupRoot, InstallDir, Manifest.Arrays['entries']);
          end;
          RestoreWaptTasks(BackupRoot, InstallDir, Service, Manifest.Arrays['entries']);
          ReadConfig;
          VerifyBackupDatabase(Database);
          if not FIsolated then
          begin
            if not RegistryValue('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WAPT_is1',
              'DisplayName', KEY_WOW64_32KEY, Edition) and
              not RegistryValue('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WAPT_is1',
              'DisplayName', KEY_WOW64_64KEY, Edition) then
              raise ETransitionState.Create('Historical uninstall registration is missing');
            if HistoricalCommunityVersion(IncludeTrailingPathDelimiter(InstallDir) + 'wapt-get.exe',
              Edition) <> Source.Strings['agent_version'] then
              raise ETransitionState.Create('Restored historical agent version differs from state');
            if NormalURL(Ini.ReadString('global', 'wapt_server', '')) <> Source.Strings['url'] then
              raise ETransitionState.Create('Restored historical server URL differs from state');
            CheckHistoricalIdentity(UTF8Decode(Field(Source, 'certificate_path', jtString).AsString),
              UTF8Decode(Field(Source, 'key_path', jtString).AsString), Data.Objects['host'].Strings['uuid']);
          end;
          RestoreBackupService(Service, InitialState);
          if InitialState = SERVICE_RUNNING then RequireWaptIdle(Port, BackupServiceState(Service));
          Result := CommitState(tsRolledBack) and StartedJournal;
        finally
          Ini.Free;
          Lines.Free;
        end;
      finally
        Manifest.Free;
      end;
    except
      on E: Exception do
      begin
        Diagnostic := 'Rollback failed while restoring or verifying historical WAPT';
        if (E is ETransitionBackup) or (E is ETransitionState) or (E is ELocalPrecheck) or
          (E is ESecurityPrecheck) then Diagnostic := Copy(E.Message, 1, 500);
        CommitState(tsRecoveryRequired, Diagnostic);
        raise;
      end;
    end;
  finally
    Data.Free;
  end;
end;

function TTransitionStore.RunFullPrecheck(const Policy: TTransitionSignerPolicy): Boolean;
var
  Metadata: TLocalMetadata;
  PackagePath: UnicodeString;
  LocalJournal, FinalJournal: Boolean;
  Data: TJSONObject;
  ApprovedDigest: string;
  EffectivePolicy: TTransitionSignerPolicy;
  Locks: TPayloadLocks;
begin
  if ReadState <> tsPrecheck then
    raise ETransitionState.Create('A pending PRECHECK state is required');
  PackagePath := FRoot + 'staging\payload';
  try
    CheckStorageTree(PackagePath);
  except
    RecordPrecheckFailure('Cannot validate protected transition payload directory');
    raise;
  end;
  try
    Data := Load;
    try
      ApprovedDigest := Data.Get('payload_sha256', '');
    finally
      Data.Free;
    end;
    EffectivePolicy := Policy;
    if not FIsolated then
    begin
      LockVerifiedPayload(PackagePath, ApprovedDigest, Locks);
      try
        EffectivePolicy := LoadTransitionSignerPolicy(PackagePath);
      except
        ReleasePayload(Locks);
        raise;
      end;
    end;
    try
      LocalJournal := RunLocalPrecheck(Self, PackagePath, Metadata);
      CheckTransitionSecurity(PackagePath, Metadata, EffectivePolicy, ApprovedDigest);
    finally
      if not FIsolated then ReleasePayload(Locks);
    end;
  except
    on E: Exception do
    begin
      if ReadState = tsPrecheck then
        if (E is ESecurityPrecheck) or (E is ELocalPrecheck) or (E is EHandoff) then
          RecordPrecheckFailure(E.Message)
        else
          RecordPrecheckFailure('Cryptographic or HTTPS precheck failed');
      raise;
    end;
  end;
  FinalJournal := CommitState(tsPrepared);
  Result := LocalJournal and FinalJournal;
end;

function TTransitionStore.ConfirmFixture(const Service: UnicodeString; const ServerURL, UUID, Version,
  ExpectedDigest, ReceivedDigest: string): Boolean;
var
  Data: TJSONObject;
  Lines: TStringList;
  Ini: TMemIniFile;
  Port: Integer;
begin
  if not FIsolated or (Pos('PADIT_BackupTest_', Service) <> 1) then raise ETransitionState.Create('Confirmation adapter is restricted to isolated fixtures');
  if InstallerPending then raise ETransitionState.Create('Installer outcome is uncertain');
  Data := Load;
  try
    if (Data = nil) or (ParseState(Data.Strings['state']) <> tsVerifying) then
      raise ETransitionState.Create('Confirmation requires VERIFYING');
    if not IsSafeServerURL(ServerURL) or (Pos('https://', ServerURL) <> 1) or
      (ServerURL <> Data.Objects['target'].Strings['url']) or
      (UUID = '') or (UUID <> Data.Objects['host'].Strings['uuid']) or
      (Pos('1.8.3.', Version) <> 1) or (Version <> Data.Objects['target'].Strings['agent_version']) or
      not IsConfirmationDigest(ExpectedDigest) or (ExpectedDigest <> ReceivedDigest) then
      raise ETransitionState.Create('Fixture confirmation does not match transition identity or fresh inventory');
    Lines := TStringList.Create;
    Ini := TMemIniFile.Create('');
    try
      Lines.Text := RawByteString(ReadDocument(UTF8Decode(Data.Objects['source'].Strings['config_path'])));
      Ini.SetStrings(Lines);
      if not TryStrToInt(Ini.ReadString('global', 'waptservice_port', '8088'), Port) or
        (Port < 1) or (Port > 65535) then raise ETransitionState.Create('Invalid fixture service port');
      RestoreBackupService(Service, SERVICE_RUNNING);
      RequireWaptIdle(Port, BackupServiceState(Service));
    finally
      Ini.Free;
      Lines.Free;
    end;
    Result := CommitState(tsCompleted, '', '', 0, ReceivedDigest);
  finally
    Data.Free;
  end;
end;

function TTransitionStore.CommitState(Next: TTransitionState; const Diagnostic, BackupDigest: string;
  InitialServiceState: DWORD; const InventoryDigest: string): Boolean;
var
  Data, Confirmation: TJSONObject;
  Current: TTransitionState;
  Stamp, EventText: string;
begin
  try
    Data := Load;
    try
      if Data = nil then
        raise ETransitionState.Create('No transition state exists');
      Current := ParseState(Data.Strings['state']);
      EventText := StateNames[Current] + ' -> ' + StateNames[Next];
      if not CanAdvance(Current, Next) then
        raise ETransitionState.Create('Forbidden transition: ' + EventText);
      Data.Strings['state'] := StateNames[Next];
      Data.Strings['previous_state'] := StateNames[Current];
      Stamp := UtcNow;
      if Stamp > Data.Strings['updated_at'] then
        Data.Strings['updated_at'] := Stamp;
      if IsFailure(Next) then
        Data.Strings['last_error'] := StateNames[Next];
      if (IsFailure(Next) or (Next = tsAborted)) and (Diagnostic <> '') then
      begin
        Data.Strings['last_error'] := Diagnostic;
        EventText := EventText + ' (' + Diagnostic + ')';
      end;
      if Next = tsBackupInProgress then
        Data.Objects['backup'].Integers['service_initial_state'] := InitialServiceState;
      if Next = tsBackupVerified then
      begin
        Data.Objects['backup'].Booleans['verified'] := True;
        Data.Objects['backup'].Strings['manifest'] := 'backup/manifest.json';
        Data.Objects['backup'].Strings['sha256'] := BackupDigest;
      end;
      if Next = tsCompleted then
      begin
        Confirmation := TJSONObject.Create;
        Data.Add('confirmation', Confirmation);
        Confirmation.Add('inventory_sha256', InventoryDigest);
        Confirmation.Add('confirmed_at', Stamp);
      end;
      Save(Data);
    finally
      Data.Free;
    end;
  except
    on E: Exception do
    begin
      TryLog('ERROR Advance: ' + E.Message);
      raise;
    end;
  end;
  if IsFailure(Next) or ((Next = tsAborted) and (Diagnostic <> '')) then
    Result := TryLog('ERROR STATE ' + EventText)
  else
    Result := TryLog('STATE ' + EventText);
end;

end.
