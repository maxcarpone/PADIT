unit transitionstate;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, fpjson, transitionstorage;

type
  TTransitionState = (tsPrecheck, tsPrecheckFailed, tsPrepared,
    tsBackupInProgress, tsBackupVerified, tsInstalling, tsVerifying,
    tsCompleted, tsRollingBack, tsRolledBack, tsRecoveryRequired, tsAborted);

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
    FDirectoryPins: TDirectoryPins;
    procedure Log(const MessageText: string);
    function TryLog(const MessageText: string): Boolean;
    function Load: TJSONObject;
    procedure Save(Data: TJSONObject);
  public
    constructor Create(const Root: UnicodeString = '');
    destructor Destroy; override;
    // On return, state.json is committed. False reports a journal write failure only.
    function Initialize: Boolean;
    function ReadState: TTransitionState;
    // Same result as Initialize. Before recording ABORTED, the orchestrator must
    // restore normal operation of the historical agent if necessary.
    function Advance(Next: TTransitionState): Boolean;
    // Persist local results without advancing. Only the future orchestrator may
    // enter PREPARED after all local, network and cryptographic checks pass.
    function RecordLocalMetadata(const Metadata: TLocalMetadata): Boolean;
    procedure StageHistoricalSnapshot(const Snapshot: UTF8String);
    function HasBackup: Boolean;
    procedure RecordPrecheckFailure(const Diagnostic: string);
    property RootDirectory: UnicodeString read FRoot;
  end;

function CanAdvance(Current, Next: TTransitionState): Boolean;

function IsSafeServerURL(const Value: string): Boolean;

implementation

uses
  Classes, DateUtils, URIParser, jsonparser, jsonscanner;

const
  SchemaVersion = 1;
  MaxStateBytes = 65536;
  MOVEFILE_WRITE_THROUGH = $00000008; // Win32 flag absent from FPC 3.2.2.
  StateNames: array[TTransitionState] of string = (
    'PRECHECK', 'PRECHECK_FAILED', 'PREPARED', 'BACKUP_IN_PROGRESS',
    'BACKUP_VERIFIED', 'INSTALLING', 'VERIFYING', 'COMPLETED',
    'ROLLING_BACK', 'ROLLED_BACK', 'RECOVERY_REQUIRED', 'ABORTED');
  Successors: array[TTransitionState] of set of TTransitionState = (
    [tsPrecheckFailed, tsPrepared],                         // PRECHECK
    [],                                                     // PRECHECK_FAILED
    [tsBackupInProgress, tsAborted],                        // PREPARED
    [tsBackupVerified, tsRecoveryRequired, tsAborted],      // BACKUP_IN_PROGRESS
    [tsInstalling, tsAborted],                              // BACKUP_VERIFIED
    [tsVerifying, tsRollingBack, tsRecoveryRequired],       // INSTALLING
    [tsCompleted, tsRollingBack, tsRecoveryRequired],       // VERIFYING
    [],                                                     // COMPLETED
    [tsRolledBack, tsRecoveryRequired],                     // ROLLING_BACK
    [],                                                     // ROLLED_BACK
    [],                                                     // RECOVERY_REQUIRED
    []);                                                    // ABORTED

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

procedure Validate(Data: TJSONObject);
var
  Current, Previous: TTransitionState;
  CreatedAt, UpdatedAt, Identifier: string;
  Id: TGUID;
begin
  if Field(Data, 'schema_version', jtNumber).AsJSON <> IntToStr(SchemaVersion) then
    raise ETransitionState.Create('Unsupported state schema version');
  if Data.Count <> 11 then
    raise ETransitionState.Create('Unexpected fields in state document');
  Identifier := Field(Data, 'transition_id', jtString).AsString;
  if not TryStringToGUID(Identifier, Id) or (GUIDToString(Id) <> Identifier) then
    raise ETransitionState.Create('Invalid transition identifier');
  Current := ParseState(Field(Data, 'state', jtString).AsString);
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
  ValidateMetadata(TJSONObject(Field(Data, 'backup', jtObject)),
    ['verified', 'manifest'], False, 2);
  if IsFailure(Current) then
  begin
    if Field(Data, 'last_error', jtString).AsString <> StateNames[Current] then
      raise ETransitionState.Create('Invalid last_error');
  end
  else
    Field(Data, 'last_error', jtNull);
end;

constructor TTransitionStore.Create(const Root: UnicodeString);
begin
  inherited Create;
  FLock := INVALID_HANDLE_VALUE;
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
  Advance(tsPrecheckFailed);
  TryLog('ERROR PRECHECK: ' + Diagnostic);
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

function TTransitionStore.Advance(Next: TTransitionState): Boolean;
var
  Data: TJSONObject;
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
  if IsFailure(Next) then
    Result := TryLog('ERROR STATE ' + EventText)
  else
    Result := TryLog('STATE ' + EventText);
end;

end.
