unit transitionstate;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, fpjson;

type
  TTransitionState = (tsPrecheck, tsPrecheckFailed, tsPrepared,
    tsBackupInProgress, tsBackupVerified, tsInstalling, tsVerifying,
    tsCompleted, tsRollingBack, tsRolledBack, tsRecoveryRequired, tsAborted);

  ETransitionState = class(Exception);

  TTransitionStore = class
  private
    FRoot: UnicodeString;
    FLock: THandle;
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
  end;

function CanAdvance(Current, Next: TTransitionState): Boolean;

implementation

uses
  Classes, DateUtils, WinDirs, jsonparser, jsonscanner;

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

procedure ValidateReservedFields(Data: TJSONObject; const Names: array of string);
var
  Name: string;
begin
  if Data.Count <> Length(Names) then
    raise ETransitionState.Create('Unexpected fields in state metadata');
  // This lot has no inventory, credential input or backup manifest producer.
  for Name in Names do
    Field(Data, Name, jtNull);
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
  ValidateReservedFields(TJSONObject(Field(Data, 'host', jtObject)),
    ['uuid', 'hostname', 'identification_mode']);
  ValidateReservedFields(TJSONObject(Field(Data, 'source', jtObject)),
    ['url', 'agent_version', 'install_dir']);
  ValidateReservedFields(TJSONObject(Field(Data, 'target', jtObject)),
    ['url', 'agent_version']);
  ValidateReservedFields(TJSONObject(Field(Data, 'backup', jtObject)),
    ['verified', 'manifest']);
  if IsFailure(Current) then
  begin
    if Field(Data, 'last_error', jtString).AsString <> StateNames[Current] then
      raise ETransitionState.Create('Invalid last_error');
  end
  else
    Field(Data, 'last_error', jtNull);
end;

constructor TTransitionStore.Create(const Root: UnicodeString);
var
  AppData: UnicodeString;
  ErrorCode: DWORD;
begin
  inherited Create;
  FLock := INVALID_HANDLE_VALUE;
  if Root = '' then
  begin
    AppData := GetWindowsSpecialDirUnicode(FOLDERID_ProgramData, False);
    if AppData = '' then
      raise ETransitionState.Create('Could not resolve ProgramData');
    FRoot := IncludeTrailingPathDelimiter(AppData) + 'PADIT\Transition\';
  end
  else
    FRoot := IncludeTrailingPathDelimiter(ExpandFileName(Root));
  if not ForceDirectories(FRoot) then
    raise ETransitionState.Create('Could not create the transition directory');
  // Keep the file in place. The kernel releases this exclusive handle on exit.
  FLock := CreateFileW(PWideChar(FRoot + 'transition.lock'), GENERIC_WRITE, 0,
    nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FLock = INVALID_HANDLE_VALUE then
  begin
    ErrorCode := GetLastError;
    if ErrorCode = ERROR_SHARING_VIOLATION then
      raise ETransitionState.Create('Another process holds the transition lock');
    RaiseLastOSError(ErrorCode);
  end;
  if not ForceDirectories(FRoot + 'logs') then
    raise ETransitionState.Create('Could not create the log directory');
  if not ForceDirectories(FRoot + 'backup') or
     not ForceDirectories(FRoot + 'staging') then
  begin
    TryLog('ERROR Could not create the backup or staging directory');
    raise ETransitionState.Create('Could not create the backup or staging directory');
  end;
end;

destructor TTransitionStore.Destroy;
begin
  if FLock <> INVALID_HANDLE_VALUE then
    CloseHandle(FLock);
  inherited Destroy;
end;

procedure TTransitionStore.Log(const MessageText: string);
var
  Handle: THandle;
  Stream: THandleStream;
  Line: UTF8String;
begin
  Handle := CreateFileW(PWideChar(FRoot + 'logs\transition.log'), FILE_APPEND_DATA,
    FILE_SHARE_READ, nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
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
  Handle := CreateFileW(PWideChar(FRoot + 'state.json'), GENERIC_READ,
    FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
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
  Handle := CreateFileW(PWideChar(TempName), GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
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
