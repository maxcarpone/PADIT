unit transitionprecheck;

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses SysUtils, Windows, transitionstate, transitionsecurity;

type
  ELocalPrecheck = class(Exception);

  EWaptTasksBusy = class(ELocalPrecheck);

  THistoricalService = class
    function State: DWORD; virtual; abstract;
    procedure CheckQueue(Deadline: QWord); virtual; abstract;
    procedure Stop; virtual; abstract;
    procedure RestoreRunning; virtual; abstract;
    procedure CheckProcesses; virtual; abstract;
    procedure CheckDatabase; virtual; abstract;
  end;

  TWindowsHistoricalService = class(THistoricalService)
  private
    FService, FDatabase: UnicodeString;
    FPort: Integer;
  public
    constructor Create(const Service, Database: UnicodeString; Port: Integer);
    function State: DWORD; override;
    procedure CheckQueue(Deadline: QWord); override;
    procedure Stop; override;
    procedure RestoreRunning; override;
    procedure CheckProcesses; override;
    procedure CheckDatabase; override;
  end;

function WaitForHistoricalIdle(Service: THistoricalService; Timeout: DWORD): DWORD;
procedure RestoreHistoricalService(Service: THistoricalService; InitialState: DWORD);
procedure TakeControlOfHistoricalService(Service: THistoricalService; InitialState: DWORD);

function RegistryValue(const Key, Name: UnicodeString; View: DWORD; out Value: UnicodeString): Boolean;
function ResolvePath(const Path, Base: UnicodeString): UnicodeString;
function ReadDocument(const Path: UnicodeString): UTF8String;
procedure CheckTaskStatus(const JSON: UTF8String; PreparationTask: Integer = 0);
function NormalURL(const URL: UTF8String): UTF8String;
function HistoricalCommunityVersion(const AgentPath, RegisteredEdition: UnicodeString): UTF8String;
function InspectLocalAgent(const InstallDir, ConfigPath, WorkingDir,
  PackageDir: UnicodeString; ServiceState: DWORD;
  BackupFree, InstallFree: QWord; SharedVolume: Boolean;
  const Snapshot: UTF8String; const RegisteredEdition: UnicodeString): TLocalMetadata;
// The future orchestrator must recheck the queue and process list after the
// preparation task exits, and obtain a fresh database check with no exemption.
function FileSizeRequired(const Path: UnicodeString; const Diagnostic: string): QWord;
function WaptExitIsActive: Boolean;
procedure RequireRollbackProcessesIdle;
procedure RequireWaptIdle(Port: Integer; ServiceState: DWORD);
function RunLocalPrecheck(Store: TTransitionStore; const PackageDir: UnicodeString;
  out Metadata: TLocalMetadata): Boolean;
// Successful calls return a read handle which denies both writes and deletion.
function OpenVerifiedInstaller(const PackageDir: UnicodeString; const Metadata: TLocalMetadata;
  const Policy: TTransitionSignerPolicy; out RepositoryURL: UTF8String; out Bundle: RawByteString; const ApprovedDigest: string = ''): THandle;
procedure CheckInstalledCutover(const Metadata: TLocalMetadata; const RepositoryURL: UTF8String;
  const HTTPSPath, PackageCAPath: UnicodeString; const HTTPSBundle, PackageBundle: RawByteString);
procedure CheckPayload(const PackageDir: UnicodeString; Installer: THandle;
  const Metadata: TLocalMetadata; out RepositoryURL: UTF8String; out Bundle: RawByteString; const ApprovedDigest: string = '');
procedure CheckTransitionSecurity(const PackageDir: UnicodeString;
  const Metadata: TLocalMetadata; const Policy: TTransitionSignerPolicy; const ApprovedDigest: string = '');

implementation

uses Classes, IniFiles, fpjson, jsonparser, jsonscanner,
  WinHttp, ShellApi, transitionstorage, transitionbackup, transitionhandoff, transitionbackupwindows;

const
  UninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\';
  ServiceParameters = 'SYSTEM\CurrentControlSet\Services\WAPTService\Parameters';
  MinimumMargin = QWord(1024) * 1024 * 1024;
  MaxLocalDocument = 1024 * 1024;

type
  TProcessEntry = record
    Size, Usage, ProcessId: DWORD;
    DefaultHeap: PtrUInt;
    ModuleId, Threads, ParentId: DWORD;
    Priority: LongInt;
    Flags: DWORD;
    ExeFile: array[0..MAX_PATH - 1] of WideChar;
  end;

function CreateToolhelp32Snapshot(Flags, ProcessId: DWORD): THandle;
  stdcall; external 'kernel32.dll' name 'CreateToolhelp32Snapshot';
function Process32First(Snapshot: THandle; var Entry: TProcessEntry): BOOL;
  stdcall; external 'kernel32.dll' name 'Process32FirstW';
function Process32Next(Snapshot: THandle; var Entry: TProcessEntry): BOOL;
  stdcall; external 'kernel32.dll' name 'Process32NextW';

function WinHttpSetTimeouts(Session: HINTERNET; Resolve, Connect, Send,
  Receive: Integer): BOOL; stdcall; external 'winhttp.dll' name 'WinHttpSetTimeouts';

procedure Require(Condition: Boolean; const Diagnostic: string);
begin
  if not Condition then raise ELocalPrecheck.Create(Diagnostic);
end;

function RegistryValue(const Key, Name: UnicodeString; View: DWORD;
  out Value: UnicodeString): Boolean;
var
  Handle: HKEY;
  Status: LongInt;
  Size, Kind: DWORD;
  Expanded: UnicodeString;
begin
  Value := '';
  Status := RegOpenKeyExW(HKEY_LOCAL_MACHINE, PWideChar(Key), 0,
    KEY_QUERY_VALUE or View, Handle);
  if Status = ERROR_FILE_NOT_FOUND then Exit(False);
  if Status <> ERROR_SUCCESS then RaiseLastOSError(Status);
  try
    Status := RegQueryValueExW(Handle, PWideChar(Name), nil, @Kind, nil, @Size);
    if Status = ERROR_FILE_NOT_FOUND then Exit(False);
    if Status <> ERROR_SUCCESS then RaiseLastOSError(Status);
    Require((Kind in [REG_SZ, REG_EXPAND_SZ]) and (Size >= 2) and
      (Size <= 65536) and (Size mod 2 = 0), 'Invalid WAPT registry value');
    SetLength(Value, Size div 2);
    Status := RegQueryValueExW(Handle, PWideChar(Name), nil, @Kind, @Value[1], @Size);
    if Status <> ERROR_SUCCESS then RaiseLastOSError(Status);
    SetLength(Value, Size div 2 - 1);
    Require(Pos(#0, Value) = 0, 'Invalid WAPT registry string');
    if Kind = REG_EXPAND_SZ then
    begin
      Size := ExpandEnvironmentStringsW(PWideChar(Value), nil, 0);
      if Size = 0 then RaiseLastOSError;
      if Size > 32768 then raise ELocalPrecheck.Create('WAPT registry path is too long');
      SetLength(Expanded, Size);
      Require(ExpandEnvironmentStringsW(PWideChar(Value), PWideChar(Expanded), Size) = Size,
        'Cannot expand WAPT registry path');
      SetLength(Expanded, Size - 1);
      Value := Expanded;
    end;
    Result := True;
  finally
    RegCloseKey(Handle);
  end;
end;

function ServiceStatus(const Name: UnicodeString): DWORD;
var
  Manager, Service: SC_HANDLE;
  Status: TServiceStatus;
  Code: DWORD;
begin
  Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  if Manager = 0 then RaiseLastOSError;
  try
    Service := OpenServiceW(Manager, PWideChar(Name), SERVICE_QUERY_STATUS);
    if Service = 0 then
    begin
      Code := GetLastError;
      if Code = ERROR_SERVICE_DOES_NOT_EXIST then Exit(0);
      RaiseLastOSError(Code);
    end;
    try
      if not QueryServiceStatus(Service, Status) then RaiseLastOSError;
      Result := Status.dwCurrentState;
    finally
      CloseServiceHandle(Service);
    end;
  finally
    CloseServiceHandle(Manager);
  end;
end;

function ResolvePath(const Path, Base: UnicodeString): UnicodeString;
begin
  Require(Path <> '', 'Empty configured WAPT path');
  if (Length(Path) >= 3) and (Path[2] = ':') and (Path[3] in ['\', '/']) then
    Result := ExpandFileName(Path)
  else
  begin
    Require((Pos(':', Path) = 0) and not (Path[1] in ['\', '/']),
      'Unsupported configured WAPT path');
    Result := ExpandFileName(IncludeTrailingPathDelimiter(Base) + Path);
  end;
  Require(Pos(':', Copy(Result, 3, MaxInt)) = 0, 'Alternate data streams are unsupported');
end;

function FileSizeRequired(const Path: UnicodeString; const Diagnostic: string): QWord;
var
  Attributes: TWin32FileAttributeData;
begin
  Require(GetFileAttributesExW(PWideChar(Path), GetFileExInfoStandard, @Attributes) and
    ((Attributes.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or
      FILE_ATTRIBUTE_REPARSE_POINT)) = 0), Diagnostic);
  CheckLocalPath(Path);
  Result := (QWord(Attributes.nFileSizeHigh) shl 32) or Attributes.nFileSizeLow;
end;

function ParseObject(const JSON: UTF8String; const Diagnostic: string): TJSONObject;
var
  Parser: TJSONParser;
  Data: TJSONData;
begin
  Require((JSON <> '') and (Length(JSON) <= MaxLocalDocument) and
    (Pos(#0, JSON) = 0), Diagnostic);
  Parser := TJSONParser.Create(JSON, [joUTF8, joStrict]);
  try
    try
      Data := Parser.Parse;
    except
      on E: EParserError do raise ELocalPrecheck.Create(Diagnostic);
      on E: EJSON do raise ELocalPrecheck.Create(Diagnostic);
    end;
    if not (Data is TJSONObject) then
    begin
      Data.Free;
      raise ELocalPrecheck.Create(Diagnostic);
    end;
    Result := TJSONObject(Data);
  finally
    Parser.Free;
  end;
end;

procedure CheckTaskStatus(const JSON: UTF8String; PreparationTask: Integer);
var
  Data: TJSONObject;
  Running, Pending, RunningId, RunningClass: TJSONData;
begin
  Data := ParseObject(JSON, 'Invalid response from local WAPT task queue');
  try
    Running := Data.Find('running');
    Pending := Data.Find('pending', jtArray);
    Require((Running <> nil) and (Pending <> nil) and
      (Running.JSONType in [jtNull, jtObject]), 'Invalid local WAPT task status');
    if Pending.Count <> 0 then raise EWaptTasksBusy.Create('Local WAPT tasks are pending');
    if Running.JSONType = jtObject then
    begin
      RunningId := TJSONObject(Running).Find('id', jtNumber);
      RunningClass := TJSONObject(Running).Find('classname', jtString);
      if PreparationTask = 0 then raise EWaptTasksBusy.Create('A local WAPT task is running');
      Require((PreparationTask > 0) and (RunningId <> nil) and
        (RunningId.AsJSON = IntToStr(PreparationTask)) and (RunningClass <> nil) and
        (RunningClass.AsString = 'WaptPackageInstall'), 'Local WAPT tasks are running or pending');
    end
    else
      Require(PreparationTask = 0, 'WAPT preparation task is not running');
  finally
    Data.Free;
  end;
end;

procedure CheckRunningService(Port, PreparationTask: Integer; Deadline: QWord = 0);
var
  Session, Connection, Request: HINTERNET;
  Status, Size, ReadCount, Mode: DWORD;
  Buffer: array[0..4095] of AnsiChar;
  Part, Data: UTF8String;
begin
  Session := WinHttpOpen('PADIT Transition', WINHTTP_ACCESS_TYPE_NO_PROXY, nil, nil, 0);
  if Session = nil then raise ELocalPrecheck.Create('Cannot query local WAPT tasks');
  try
    Require(WinHttpSetTimeouts(Session, 2000, 2000, 2000, 2000),
      'Cannot set local WAPT task timeouts');
    Connection := WinHttpConnect(Session, '127.0.0.1', Port, 0);
    Require(Connection <> nil, 'Cannot connect to local WAPT task service');
    try
      Request := WinHttpOpenRequest(Connection, 'GET', '/tasks.json', nil, nil, nil, 0);
      Require(Request <> nil, 'Cannot open local WAPT task request');
      try
        Mode := WINHTTP_DISABLE_REDIRECTS or WINHTTP_DISABLE_AUTHENTICATION;
        Require(WinHttpSetOption(Request, WINHTTP_OPTION_DISABLE_FEATURE, @Mode, SizeOf(Mode)) and
          WinHttpSendRequest(Request, nil, 0, nil, 0, 0, 0) and
          WinHttpReceiveResponse(Request, nil), 'Cannot read local WAPT tasks');
        Size := SizeOf(Status);
        Require(WinHttpQueryHeaders(Request, WINHTTP_QUERY_STATUS_CODE or
          WINHTTP_QUERY_FLAG_NUMBER, nil, @Status, @Size, nil) and (Status = 200),
          'Local WAPT task endpoint did not return HTTP 200');
        Data := '';
        repeat
          Require((Deadline = 0) or (GetTickCount64 < Deadline), 'Local WAPT task query deadline exceeded');
          Require(WinHttpReadData(Request, @Buffer[0], SizeOf(Buffer), @ReadCount),
            'Cannot read local WAPT task response');
          Require(Length(Data) + ReadCount <= MaxLocalDocument, 'Local WAPT task response too large');
          SetString(Part, PAnsiChar(@Buffer[0]), ReadCount);
          Data := Data + Part;
        until ReadCount = 0;
        CheckTaskStatus(Data, PreparationTask);
      finally
        WinHttpCloseHandle(Request);
      end;
    finally
      WinHttpCloseHandle(Connection);
    end;
  finally
    WinHttpCloseHandle(Session);
  end;
end;

function ReadDocument(const Path: UnicodeString): UTF8String;
var
  Handle: THandle;
  ReadCount: DWORD;
  Size: QWord;
begin
  Size := FileSizeRequired(Path, 'Missing required configuration or manifest');
  Require((Size > 0) and (Size <= MaxLocalDocument), 'Invalid local document size');
  Handle := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ,
    nil, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    SetLength(Result, Size);
    Require(ReadFile(Handle, Result[1], Size, ReadCount, nil) and (ReadCount = Size),
      'Cannot read required local document');
  finally
    CloseHandle(Handle);
  end;
end;

function AgentVersion(const Path: UnicodeString; out Community: Boolean): UTF8String;
var
  Handle, Size, Length: DWORD;
  Buffer: array of Byte;
  Value: Pointer;
  Info: PVSFixedFileInfo;
  Translation: PWord;
  Query: UnicodeString;
begin
  FileSizeRequired(Path, 'Missing WAPT executable');
  Handle := 0;
  Size := GetFileVersionInfoSizeW(PWideChar(Path), Handle);
  Require(Size > 0, 'Missing WAPT executable version');
  SetLength(Buffer, Size);
  Value := nil;
  Length := 0;
  Require(GetFileVersionInfoW(PWideChar(Path), 0, Size, @Buffer[0]) and
    VerQueryValueW(@Buffer[0], '\', Value, Length) and (Length >= SizeOf(TVSFixedFileInfo)),
    'Invalid WAPT executable version');
  Info := PVSFixedFileInfo(Value);
  Result := Format('%d.%d.%d.%d', [HiWord(Info^.dwFileVersionMS),
    LoWord(Info^.dwFileVersionMS), HiWord(Info^.dwFileVersionLS),
    LoWord(Info^.dwFileVersionLS)]);
  Community := False;
  if VerQueryValueW(@Buffer[0], '\VarFileInfo\Translation', Value, Length) and
     (Length >= 2 * SizeOf(Word)) then
  begin
    Translation := PWord(Value);
    Query := '\StringFileInfo\' + UnicodeString(Format('%.4x%.4x',
      [Translation[0], Translation[1]])) + '\ProductName';
    if VerQueryValueW(@Buffer[0], PWideChar(Query), Value, Length) and (Length > 0) then
      Community := UnicodeSameText(UnicodeString(PWideChar(Value)), 'WAPT Community Edition') or
        UnicodeSameText(UnicodeString(PWideChar(Value)), 'PADIT Community Edition');
  end;
end;

function TreeSize(const Path: UnicodeString): QWord;
var
  Info: TWin32FindDataW;
  Search: THandle;
  Name, Child: UnicodeString;
  Code: DWORD;
begin
  CheckLocalPath(Path);
  Result := 0;
  Search := FindFirstFileW(PWideChar(IncludeTrailingPathDelimiter(Path) + '*'), Info);
  if Search = INVALID_HANDLE_VALUE then
  begin
    Code := GetLastError;
    if Code = ERROR_FILE_NOT_FOUND then Exit;
    RaiseLastOSError(Code);
  end;
  try
    repeat
      Name := PWideChar(@Info.cFileName[0]);
      if (Name = '.') or (Name = '..') then Continue;
      Require((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) = 0,
        'Reparse point in the data to back up');
      Child := IncludeTrailingPathDelimiter(Path) + Name;
      if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        Inc(Result, TreeSize(Child))
      else
        Inc(Result, (QWord(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow);
    until not FindNextFileW(Search, Info);
    if GetLastError <> ERROR_NO_MORE_FILES then RaiseLastOSError;
  finally
    Windows.FindClose(Search);
  end;
end;

function Below(const Path, Parent: UnicodeString): Boolean;
begin
  Result := UnicodeSameText(Path, Parent) or (Pos(UnicodeLowerCase(IncludeTrailingPathDelimiter(Parent)),
    UnicodeLowerCase(Path)) = 1);
end;

function NormalURL(const URL: UTF8String): UTF8String;
var
  I: Integer;
begin
  Require(IsSafeServerURL(URL), 'Missing or unsafe server URL');
  Result := URL;
  while Result[Length(Result)] = '/' do Delete(Result, Length(Result), 1);
  I := Pos('/', Copy(Result, Pos('://', Result) + 3, MaxInt));
  if I = 0 then Result := LowerCase(Result)
  else
  begin
    I := I + Pos('://', Result) + 2;
    Result := LowerCase(Copy(Result, 1, I - 1)) + Copy(Result, I, MaxInt);
  end;
end;

function RequiredString(Data: TJSONObject; const Name: string): UTF8String;
var
  Value: TJSONData;
begin
  Value := Data.Find(Name, jtString);
  Require((Value <> nil) and (Value.AsString <> ''), 'Invalid historical snapshot field: ' + Name);
  Result := Value.AsString;
end;

function OptionalString(Data: TJSONObject; const Name: string): UTF8String;
var
  Value: TJSONData;
begin
  Value := Data.Find(Name);
  Require(Value <> nil, 'Missing historical snapshot field: ' + Name);
  if Value.JSONType = jtNull then Exit('');
  Result := RequiredString(Data, Name);
end;

function OptionalIdentifier(Data: TJSONObject; const Name: string): Integer;
var
  Value: TJSONData;
begin
  Value := Data.Find(Name);
  Require(Value <> nil, 'Missing historical snapshot field: ' + Name);
  if Value.JSONType = jtNull then Exit(0);
  Require((Value.JSONType = jtNumber) and TryStrToInt(Value.AsJSON, Result) and
    (Result > 0) and (IntToStr(Result) = Value.AsJSON), 'Invalid historical snapshot identifier: ' + Name);
end;

procedure CheckCommandLineAgent(PreparationPID: Integer; ForRollback: Boolean = False; AfterStop: Boolean = False); forward;

function HistoricalCommunityVersion(const AgentPath, RegisteredEdition: UnicodeString): UTF8String;
var
  Community: Boolean;
begin
  Result := AgentVersion(AgentPath, Community);
  Require(Community and
    ((RegisteredEdition = 'WAPTAgent Community ' + UnicodeString(Result)) or
     (Pos('WAPT Community ', RegisteredEdition) = 1) or
     (Pos('PADIT Community ', RegisteredEdition) = 1) or
     (Pos('PADITAgent Community ', RegisteredEdition) = 1) or
     (Pos('PADITSetup Community ', RegisteredEdition) = 1)) and
    ((Pos('1.8.2.', Result) = 1) or (Pos('1.8.3.', Result) = 1)),
    'Unsupported historical WAPT edition or version');
end;

function InspectLocalAgent(const InstallDir, ConfigPath, WorkingDir,
  PackageDir: UnicodeString; ServiceState: DWORD;
  BackupFree, InstallFree: QWord; SharedVolume: Boolean;
  const Snapshot: UTF8String; const RegisteredEdition: UnicodeString): TLocalMetadata;
const
  PayloadFiles: array[0..4] of UnicodeString = ('waptagent.exe', 'waptagent.sha256',
    'patchs\waptdeploy.exe', 'certificates\https.pem', 'certificates\packages.pem');
var
  Ini: TMemIniFile;
  Config: TStringList;
  Manifest, Historical: TJSONObject;
  Source, Target, TargetVersion, RecordedUUID, ModeValue, FakeHostname: UTF8String;
  PrivateDir, PersistentDir, DbPath, KeyPath, CertPath, Child, Package: UnicodeString;
  UnusedCommunity: Boolean;
  BackupSize, InstallSize, PayloadSize: QWord;
  Port, PreparationTask, PreparationPID: Integer;
  C: AnsiChar;

  function ConfiguredPath(const Key: string; const DefaultPath: UnicodeString): UnicodeString;
  begin
    if Ini.ValueExists('global', Key) then
      Result := ResolvePath(UTF8Decode(Ini.ReadString('global', Key, '')), WorkingDir)
    else
      Result := IncludeTrailingPathDelimiter(InstallDir) + DefaultPath;
  end;

begin
  Require(ServiceState in [SERVICE_RUNNING, SERVICE_STOPPED], 'WAPT service is missing or not stable');
  Require(not FileExists(IncludeTrailingPathDelimiter(InstallDir) + 'conf\waptserver.ini') and
    not DirectoryExists(IncludeTrailingPathDelimiter(InstallDir) + 'waptserver'),
    'A local WAPT Server installation was detected');
  Result.SourceVersion := HistoricalCommunityVersion(IncludeTrailingPathDelimiter(InstallDir) +
    'wapt-get.exe', RegisteredEdition);
  Package := IncludeTrailingPathDelimiter(PackageDir);
  Manifest := ParseObject(ReadDocument(Package + 'transition.json'), 'Invalid transition manifest');
  try
    Require((Manifest.Find('schema_version', jtNumber) <> nil) and
      (Manifest.Find('schema_version').AsJSON = '1'), 'Unsupported transition manifest schema');
    Source := NormalURL(Manifest.Get('source_server_url', ''));
    Target := NormalURL(Manifest.Get('target_server_url', ''));
    Require((Source <> Target) and (Pos('https://', Target) = 1),
      'Target server must be a different HTTPS endpoint');
    PayloadSize := 0;
    for Child in PayloadFiles do
    begin
      InstallSize := FileSizeRequired(Package + Child, 'Missing transition payload file');
      Require(InstallSize > 0, 'Empty transition payload file');
      Inc(PayloadSize, InstallSize);
    end;
    TargetVersion := AgentVersion(Package + 'waptagent.exe', UnusedCommunity);
    Require((Pos('1.8.3.', TargetVersion) = 1) and
      (TargetVersion = Manifest.Get('agent_version', '')), 'Invalid PADIT target version');
  finally
    Manifest.Free;
  end;

  Config := TStringList.Create;
  Ini := TMemIniFile.Create('');
  try
    Config.Text := RawByteString(ReadDocument(ConfigPath));
    Ini.SetStrings(Config);
    Require(Ini.SectionExists('global'), 'Missing [global] in WAPT configuration');
    Result.SourceURL := NormalURL(Ini.ReadString('global', 'wapt_server', ''));
    Require(Result.SourceURL = Source, 'Current WAPT server differs from source_server_url');
    PrivateDir := ConfiguredPath('private_dir', 'private');
    PersistentDir := ConfiguredPath('persistent_root_dir', 'private\persistent');
    DbPath := ConfiguredPath('dbpath', 'db\waptdb.sqlite');
    Result.UUID := UTF8String(Ini.ReadString('global', 'uuid', ''));
    ModeValue := LowerCase(Ini.ReadString('global', 'use_fqdn_as_uuid', '0'));
    FakeHostname := Ini.ReadString('global', 'fake_hostname', '');
    if Ini.ValueExists('global', 'fake_hostname') then
    begin
      Require(FakeHostname <> '', 'Invalid configured WAPT test hostname');
      ModeValue := '1';
    end;
    Require((ModeValue = '0') or (ModeValue = '1') or (ModeValue = 'true') or
      (ModeValue = 'false') or (ModeValue = 'yes') or (ModeValue = 'no') or
      (ModeValue = 'on') or (ModeValue = 'off'), 'Invalid WAPT identification mode');
    Require(TryStrToInt(Ini.ReadString('global', 'waptservice_port', '8088'), Port),
      'Invalid WAPT service port');
    Require((Port > 0) and (Port <= 65535), 'Invalid WAPT service port');
  finally
    Ini.Free;
    Config.Free;
  end;
  FileSizeRequired(DbPath, 'Missing WAPT SQLite database');
  Historical := ParseObject(Snapshot, 'Invalid historical WAPT snapshot');
  try
    Require((Historical.Count = 9) and
      (Historical.Find('schema_version', jtNumber) <> nil) and
      (Historical.Find('schema_version').AsJSON = '1'), 'Unsupported historical snapshot format');
    Require(UnicodeSameText(UTF8Decode(RequiredString(Historical, 'config_path')), ConfigPath) and
      UnicodeSameText(UTF8Decode(RequiredString(Historical, 'database_path')), DbPath),
      'Historical snapshot does not match this installation');
    // WAPT may derive its FQDN through DNS instead of the Windows primary suffix.
    Result.Hostname := RequiredString(Historical, 'hostname');
    Require((FakeHostname = '') or (FakeHostname = Result.Hostname),
      'Snapshot disagrees with the configured WAPT test hostname');
    RecordedUUID := OptionalString(Historical, 'registered_uuid');
    ModeValue := LowerCase(ModeValue);
    Result.IdentificationMode := RequiredString(Historical, 'identification_mode');
    if Result.UUID <> '' then
      Require((Result.IdentificationMode = 'configured') and
        (RequiredString(Historical, 'uuid') = Result.UUID),
        'Snapshot disagrees with the configured UUID')
    else if (ModeValue = '1') or (ModeValue = 'true') or (ModeValue = 'yes') or (ModeValue = 'on') then
      Require((Result.IdentificationMode = 'fqdn') and
        (RequiredString(Historical, 'uuid') = Result.Hostname), 'Snapshot disagrees with the FQDN')
    else
      Require((Result.IdentificationMode = 'hardware') or
        ((Result.IdentificationMode = 'stored') and (RecordedUUID <> '')),
        'Unexpected historical identification mode');
    Result.UUID := RequiredString(Historical, 'uuid');
    Require((RecordedUUID = '') or (RecordedUUID = Result.UUID),
      'Recorded and effective WAPT UUIDs differ');
    PreparationPID := OptionalIdentifier(Historical, 'preparation_pid');
    PreparationTask := OptionalIdentifier(Historical, 'preparation_task_id');
    Require((PreparationTask = 0) or (PreparationPID > 0), 'Unbound WAPT preparation task');
  finally
    Historical.Free;
  end;
  CheckCommandLineAgent(PreparationPID);
  Require((Result.UUID <> '') and (Length(Result.UUID) <= 255) and
    (Result.UUID <> '.') and (Result.UUID <> '..'), 'Missing or invalid existing WAPT UUID');
  for C in Result.UUID do
    Require(C in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '{', '}'], 'Unsafe WAPT UUID');
  KeyPath := IncludeTrailingPathDelimiter(PrivateDir) + UTF8Decode(Result.UUID) + '.pem';
  CertPath := IncludeTrailingPathDelimiter(PrivateDir) + UTF8Decode(Result.UUID) + '.crt';
  Require(FileSizeRequired(KeyPath, 'Missing machine private key') > 0, 'Empty machine private key');
  Require(FileSizeRequired(CertPath, 'Missing machine certificate') > 0, 'Empty machine certificate');
  BackupSize := TreeSize(InstallDir);
  if not Below(PrivateDir, InstallDir) then Inc(BackupSize, TreeSize(PrivateDir));
  if DirectoryExists(PersistentDir) and not Below(PersistentDir, InstallDir) and
    not Below(PersistentDir, PrivateDir) then Inc(BackupSize, TreeSize(PersistentDir));
  if not Below(DbPath, InstallDir) and not Below(DbPath, PrivateDir) and
    not Below(DbPath, PersistentDir) then
    Inc(BackupSize, FileSizeRequired(DbPath, 'Missing WAPT SQLite database'));
  if not Below(ConfigPath, InstallDir) and not Below(ConfigPath, PrivateDir) and
    not Below(ConfigPath, PersistentDir) then
    Inc(BackupSize, FileSizeRequired(ConfigPath, 'Missing WAPT configuration'));
  InstallSize := BackupSize + PayloadSize + MinimumMargin;
  if SharedVolume then
    Require(BackupFree >= BackupSize + InstallSize, 'Insufficient disk space for backup and installation')
  else
  begin
    Require(BackupFree >= BackupSize + MinimumMargin, 'Insufficient disk space on backup volume');
    Require(InstallFree >= InstallSize, 'Insufficient disk space on installation volume');
  end;
  if ServiceState = SERVICE_RUNNING then
  begin
    CheckRunningService(Port, PreparationTask);
    Result.ServiceState := 'running';
  end
  else
  begin
    Require(PreparationTask = 0, 'WAPT preparation task supplied for a stopped service');
    Result.ServiceState := 'stopped';
  end;
  Result.InstallDir := UTF8Encode(InstallDir);
  Result.ConfigPath := UTF8Encode(ConfigPath);
  Result.KeyPath := UTF8Encode(KeyPath);
  Result.CertificatePath := UTF8Encode(CertPath);
  Result.DatabasePath := UTF8Encode(DbPath);
  Result.TargetURL := Target;
  Result.TargetVersion := TargetVersion;
end;

procedure CheckCommandLineAgent(PreparationPID: Integer; ForRollback, AfterStop: Boolean);
var
  Snapshot: THandle;
  Entry: TProcessEntry;
  Name: UnicodeString;
begin
  Snapshot := CreateToolhelp32Snapshot($00000002, 0);
  if Snapshot = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Entry.Size := SizeOf(Entry);
    if not Process32First(Snapshot, Entry) then RaiseLastOSError;
    repeat
      Name := UnicodeLowerCase(UnicodeString(PWideChar(@Entry.ExeFile[0])));
      Require((Entry.ProcessId = DWORD(PreparationPID)) or (Name <> 'wapt-get.exe'),
        'A WAPT command-line process is running');
      if AfterStop then
        Require((Name <> 'waptpython.exe') and (Name <> 'waptservice.exe') and (Name <> 'waptexit.exe'),
          'A historical WAPT process remains active after service shutdown');
      if ForRollback then
        Require((Name <> 'waptpython.exe') and (Name <> 'wapttray.exe') and
          (Name <> 'waptself.exe') and (Name <> 'waptmessage.exe') and (Name <> 'waptconsole.exe'),
          'A PADIT or WAPT process remains active after service shutdown');
    until not Process32Next(Snapshot, Entry);
    if GetLastError <> ERROR_NO_MORE_FILES then RaiseLastOSError;
  finally
    CloseHandle(Snapshot);
  end;
end;

function WaptExitIsActive: Boolean;
var
  Snapshot: THandle;
  Entry: TProcessEntry;
begin
  Snapshot := CreateToolhelp32Snapshot($00000002, 0);
  if Snapshot = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Entry.Size := SizeOf(Entry);
    if not Process32First(Snapshot, Entry) then RaiseLastOSError;
    repeat
      if UnicodeSameText(UnicodeString(PWideChar(@Entry.ExeFile[0])), 'waptexit.exe') then
        Exit(True);
    until not Process32Next(Snapshot, Entry);
    if GetLastError <> ERROR_NO_MORE_FILES then RaiseLastOSError;
    Result := False;
  finally
    CloseHandle(Snapshot);
  end;
end;

procedure RequireRollbackProcessesIdle;
begin
  CheckCommandLineAgent(0, True);
end;

procedure RequireWaptIdle(Port: Integer; ServiceState: DWORD);
begin
  Require(ServiceState in [SERVICE_RUNNING, SERVICE_STOPPED], 'WAPT service is missing or not stable');
  CheckCommandLineAgent(0);
  if ServiceState = SERVICE_RUNNING then
    CheckRunningService(Port, 0);
end;

function WaitForHistoricalIdle(Service: THistoricalService; Timeout: DWORD): DWORD;
var
  Deadline, Now: QWord;
begin
  Require((Timeout > 0) and (Timeout <> INFINITE), 'Historical WAPT wait must be bounded');
  Deadline := GetTickCount64 + Timeout;
  repeat
    Require(GetTickCount64 < Deadline, 'Timed out waiting for historical WAPT tasks');
    Result := Service.State;
    Require(Result in [SERVICE_RUNNING, SERVICE_STOPPED], 'Historical WAPT service is not stable');
    if Result = SERVICE_STOPPED then Exit;
    try
      Service.CheckQueue(Deadline);
      Require(GetTickCount64 < Deadline, 'Timed out waiting for historical WAPT tasks');
      Exit;
    except
      on E: EWaptTasksBusy do
      begin
        Now := GetTickCount64;
        if Now < Deadline then
          if Deadline - Now > 250 then Sleep(250) else Sleep(DWORD(Deadline - Now));
      end;
    end;
  until False;
end;

procedure TakeControlOfHistoricalService(Service: THistoricalService; InitialState: DWORD);
var
  Deadline: QWord;
begin
  Require(InitialState in [SERVICE_RUNNING, SERVICE_STOPPED], 'Historical WAPT service is not stable');
  Require(Service.State = InitialState, 'Historical WAPT service changed before takeover');
  if InitialState = SERVICE_RUNNING then
  begin
    Deadline := GetTickCount64 + 6000;
    Service.CheckQueue(Deadline);
    Require(GetTickCount64 < Deadline, 'Historical WAPT task recheck deadline exceeded');
    Service.Stop;
  end;
  Require(Service.State = SERVICE_STOPPED, 'Historical WAPT service did not stop');
  Service.CheckProcesses;
  Service.CheckDatabase;
  Require(Service.State = SERVICE_STOPPED, 'Historical WAPT service resumed during takeover');
end;

constructor TWindowsHistoricalService.Create(const Service, Database: UnicodeString; Port: Integer);
begin
  inherited Create;
  FService := Service;
  FDatabase := Database;
  FPort := Port;
end;

function TWindowsHistoricalService.State: DWORD;
begin
  Result := BackupServiceState(FService);
end;

procedure TWindowsHistoricalService.CheckQueue(Deadline: QWord);
begin
  CheckRunningService(FPort, 0, Deadline);
  CheckCommandLineAgent(0);
end;

procedure TWindowsHistoricalService.Stop;
begin
  StopBackupService(FService);
end;

procedure RestoreHistoricalService(Service: THistoricalService; InitialState: DWORD);
begin
  if (InitialState = SERVICE_RUNNING) and (Service.State <> SERVICE_RUNNING) then
    Service.RestoreRunning;
  // Never stop a newly started service here, which might have admitted foreign tasks.
  Require(Service.State = InitialState, 'Historical WAPT service state was not restored');
end;

procedure TWindowsHistoricalService.RestoreRunning;
begin
  RestoreBackupService(FService, SERVICE_RUNNING);
end;

procedure TWindowsHistoricalService.CheckProcesses;
begin
  CheckCommandLineAgent(0, False, True);
end;

procedure TWindowsHistoricalService.CheckDatabase;
begin
  VerifyBackupDatabase(FDatabase);
end;

function RunLocalPrecheck(Store: TTransitionStore; const PackageDir: UnicodeString;
  out Metadata: TLocalMetadata): Boolean;
var
  InstallDir, ConfigPath, WorkingDir, Temp, Args, BackupVolume, InstallVolume: UnicodeString;
  Arguments: PPWideChar;
  RegisteredEdition, RegistryKey, SnapshotPath: UnicodeString;
  Count, I: Integer;
  Buffer: array[0..MAX_PATH] of WideChar;
  BackupFree, InstallFree, Total, Free: Int64;

  Service: DWORD;
begin
  Require(Store.ReadState = tsPrecheck, 'A pending PRECHECK state is required');
  try
    Require(not Store.HasBackup, 'A previous backup exists; it will be preserved');

    Require((ServiceStatus('waptserver') = 0) and
      not RegistryValue(UninstallKey + 'WAPT Server_is1', 'InstallLocation', KEY_WOW64_32KEY, Temp) and
      not RegistryValue(UninstallKey + 'WAPT Server_is1', 'InstallLocation', KEY_WOW64_64KEY, Temp),
      'A local WAPT Server installation was detected');
    Service := ServiceStatus('waptservice');
    Require(Service <> 0, 'The local WAPTService is not registered');
    RegistryKey := UninstallKey + 'WAPT_is1';
    if RegistryValue(RegistryKey, 'InstallLocation', KEY_WOW64_32KEY, InstallDir) then
      Require(RegistryValue(RegistryKey, 'DisplayName', KEY_WOW64_32KEY, RegisteredEdition),
        'WAPT edition is not registered')
    else
      Require(RegistryValue(RegistryKey, 'InstallLocation', KEY_WOW64_64KEY, InstallDir) and
        RegistryValue(RegistryKey, 'DisplayName', KEY_WOW64_64KEY, RegisteredEdition),
        'WAPT installation or edition is not registered');
    Require(Length(InstallDir) >= 3, 'Invalid registered WAPT installation path');
    InstallDir := ExcludeTrailingPathDelimiter(ResolvePath(InstallDir, ''));
    CheckLocalPath(InstallDir);
    Require(RegistryValue(ServiceParameters, 'Application', 0, Temp) and
      UnicodeSameText(ResolvePath(Temp, InstallDir),
        IncludeTrailingPathDelimiter(InstallDir) + 'waptpython.exe'),
      'WAPT service application does not match the registered installation');
    if not RegistryValue(ServiceParameters, 'AppDirectory', 0, WorkingDir) or (WorkingDir = '') then
      WorkingDir := InstallDir;
    WorkingDir := ResolvePath(WorkingDir, InstallDir);
    ConfigPath := IncludeTrailingPathDelimiter(InstallDir) + 'wapt-get.ini';
    if RegistryValue(ServiceParameters, 'AppParameters', 0, Args) and (Args <> '') then
    begin
      Args := 'waptpython.exe ' + Args;
      Arguments := CommandLineToArgvW(PWideChar(Args), @Count);
      if Arguments = nil then RaiseLastOSError;
      try
        I := 1;
        while I < Count do
        begin
          Temp := Arguments[I];
          if (Temp = '-c') or (Temp = '--config') then
          begin
            Inc(I);
            Require(I < Count, 'Missing WAPT service configuration argument');
            ConfigPath := ResolvePath(Arguments[I], WorkingDir);
          end
          else if Pos('--config=', Temp) = 1 then
            ConfigPath := ResolvePath(Copy(Temp, 10, MaxInt), WorkingDir)
          else if (Pos('-c', Temp) = 1) and (System.Length(Temp) > 2) then
            ConfigPath := ResolvePath(Copy(Temp, 3, MaxInt), WorkingDir);
          Inc(I);
        end;
      finally
        LocalFree(HLOCAL(Arguments));
      end;
    end;

    Temp := Store.RootDirectory;
    if not GetVolumePathNameW(PWideChar(Temp), @Buffer[0], System.Length(Buffer)) then RaiseLastOSError;
    BackupVolume := PWideChar(@Buffer[0]);
    if not GetVolumePathNameW(PWideChar(InstallDir), @Buffer[0], System.Length(Buffer)) then RaiseLastOSError;
    InstallVolume := PWideChar(@Buffer[0]);
    if not GetDiskFreeSpaceExW(PWideChar(Temp), BackupFree, Total, @Free) or
       not GetDiskFreeSpaceExW(PWideChar(InstallDir), InstallFree, Total, @Free) then RaiseLastOSError;
    Require(not Below(PackageDir, InstallDir), 'Transition payload must be outside the historical installation');
    SnapshotPath := Store.RootDirectory + 'staging\historical.json';
    CheckStorageFile(SnapshotPath);
    Metadata := InspectLocalAgent(InstallDir, ConfigPath, WorkingDir, PackageDir,
      Service, BackupFree, InstallFree, UnicodeSameText(BackupVolume, InstallVolume),
      ReadDocument(SnapshotPath), RegisteredEdition);
  except
    on E: Exception do
    begin
      if E is ELocalPrecheck then
        Store.RecordPrecheckFailure(E.Message)
      else
        Store.RecordPrecheckFailure('Cannot safely inspect the local WAPT installation');
      raise;
    end;
  end;
  Result := Store.RecordLocalMetadata(Metadata);
end;

procedure CheckInstalledCutover(const Metadata: TLocalMetadata; const RepositoryURL: UTF8String;
  const HTTPSPath, PackageCAPath: UnicodeString; const HTTPSBundle, PackageBundle: RawByteString);
var
  Config: TStringList;
  Ini: TMemIniFile;
  Community: Boolean;
  Forced: UTF8String;
begin
  Require(ServiceStatus('WAPTService') = SERVICE_STOPPED, 'WAPTService must remain stopped before local verification');
  RequireRollbackProcessesIdle;
  Require(AgentVersion(IncludeTrailingPathDelimiter(UTF8Decode(Metadata.InstallDir)) + 'wapt-get.exe',
    Community) = Metadata.TargetVersion, 'Unexpected installed PADIT version');
  Config := TStringList.Create;
  Ini := TMemIniFile.Create('');
  try
    Config.Text := RawByteString(ReadDocument(UTF8Decode(Metadata.ConfigPath)));
    Ini.SetStrings(Config);
    Require((NormalURL(Ini.ReadString('global', 'wapt_server', '')) = Metadata.TargetURL) and
      (NormalURL(Ini.ReadString('global', 'repo_url', '')) = RepositoryURL), 'Installed endpoints differ from target');
    Require(UnicodeSameText(UTF8Decode(Ini.ReadString('global', 'verify_cert', '')), HTTPSPath) and
      (ReadDocument(HTTPSPath) = HTTPSBundle) and (ReadDocument(PackageCAPath) = PackageBundle),
      'Installed CA configuration differs from verified transition trust');
    Forced := Ini.ReadString('global', 'uuid', '');
    if Metadata.IdentificationMode = 'configured' then
      Require(UnicodeSameText(UTF8Decode(Forced), UTF8Decode(Metadata.UUID)), 'Installed forced UUID was changed');
  finally
    Ini.Free;
    Config.Free;
  end;
  VerifyBackupDatabase(UTF8Decode(Metadata.DatabasePath));
  CheckHistoricalIdentity(UTF8Decode(Metadata.CertificatePath), UTF8Decode(Metadata.KeyPath), Metadata.UUID);
end;

procedure CheckPayload(const PackageDir: UnicodeString; Installer: THandle;
  const Metadata: TLocalMetadata; out RepositoryURL: UTF8String; out Bundle: RawByteString; const ApprovedDigest: string);
var
  PackagePath: UnicodeString;
  Manifest: TJSONObject;
  Deployable: TJSONData;
  UnusedCommunity: Boolean;
begin
  PackagePath := IncludeTrailingPathDelimiter(PackageDir);
  Manifest := ParseObject(ReadDocument(PackagePath + 'transition.json'), 'Invalid transition manifest');
  try
    Deployable := Manifest.Find('deployable', jtBoolean);
    Require((Manifest.Find('schema_version', jtNumber) <> nil) and (Deployable <> nil) and
      not Deployable.AsBoolean, 'Unsupported or deployable transition manifest');
    if (ApprovedDigest <> '') or (Manifest.Find('schema_version').AsJSON = '2') then CheckStagedPayload(PackagePath, ApprovedDigest)
    else Require((Manifest.Count = 9) and (Manifest.Find('schema_version').AsJSON = '1'),
      'Unsupported transition manifest version');
    Require((NormalURL(RequiredString(Manifest, 'source_server_url')) = Metadata.SourceURL) and
      (NormalURL(RequiredString(Manifest, 'target_server_url')) = Metadata.TargetURL) and
      (Pos('https://', Metadata.TargetURL) = 1), 'Transition endpoints changed after local checks');
    RepositoryURL := NormalURL(RequiredString(Manifest, 'target_repo_url'));
    Require(Pos('https://', RepositoryURL) = 1, 'Transition repository must use HTTPS');
    Require((RequiredString(Manifest, 'https_certificate') = 'certificates/https.pem') and
      (RequiredString(Manifest, 'package_certificate') = 'certificates/packages.pem'),
      'Invalid certificate references in transition manifest');
    Require((RequiredString(Manifest, 'agent_version') = Metadata.TargetVersion) and
      (Pos('1.8.3.', Metadata.TargetVersion) = 1) and
      (AgentVersion(PackagePath + 'waptagent.exe', UnusedCommunity) = Metadata.TargetVersion),
      'Installer PE version does not match the transition manifest');
    CheckInstallerHash(Installer, RequiredString(Manifest, 'agent_sha256'),
      ReadDocument(PackagePath + 'waptagent.sha256'));
    Bundle := ReadDocument(PackagePath + 'certificates\https.pem');
  finally
    Manifest.Free;
  end;
end;

function OpenVerifiedInstaller(const PackageDir: UnicodeString; const Metadata: TLocalMetadata;
  const Policy: TTransitionSignerPolicy; out RepositoryURL: UTF8String; out Bundle: RawByteString; const ApprovedDigest: string): THandle;
var
  InstallerPath: UnicodeString;
begin
  InstallerPath := IncludeTrailingPathDelimiter(PackageDir) + 'waptagent.exe';
  Result := OpenStorageFile(InstallerPath, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
  Require(Result <> INVALID_HANDLE_VALUE, 'Cannot lock the staged installer for verification');
  try
    CheckPayload(PackageDir, Result, Metadata, RepositoryURL, Bundle, ApprovedDigest);
    CheckAuthenticode(InstallerPath, Result, Policy.InstallerSignerSHA256);
  except
    CloseHandle(Result);
    raise;
  end;
end;

procedure CheckTransitionSecurity(const PackageDir: UnicodeString;
  const Metadata: TLocalMetadata; const Policy: TTransitionSignerPolicy; const ApprovedDigest: string);
var
  EnginePath: UnicodeString;
  Installer, Engine: THandle;
  PathSize: DWORD;
  RepositoryURL: UTF8String;
  Bundle: RawByteString;
begin
  try
    Installer := OpenVerifiedInstaller(PackageDir, Metadata, Policy, RepositoryURL, Bundle, ApprovedDigest);
  except
    on E: ESecurityPrecheck do raise ESecurityPrecheck.Create('Installer: ' + E.Message);
  end;
  CloseHandle(Installer);

  SetLength(EnginePath, 32768);
  PathSize := GetModuleFileNameW(0, PWideChar(EnginePath), Length(EnginePath));
  Require((PathSize > 0) and (PathSize < DWORD(Length(EnginePath))), 'Cannot locate transition executable');
  SetLength(EnginePath, PathSize);
  Engine := CreateFileW(PWideChar(EnginePath), GENERIC_READ, FILE_SHARE_READ,
    nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  Require(Engine <> INVALID_HANDLE_VALUE, 'Cannot lock transition executable for verification');
  try
    try
      CheckAuthenticode(EnginePath, Engine, Policy.EngineSignerSHA256);
    except
      on E: ESecurityPrecheck do raise ESecurityPrecheck.Create('Transition executable: ' + E.Message);
    end;
  finally
    CloseHandle(Engine);
  end;

  CheckHistoricalIdentity(UTF8Decode(Metadata.CertificatePath), UTF8Decode(Metadata.KeyPath),
    Metadata.UUID);
  try
    CheckHttps(Metadata.TargetURL + '/ping', Bundle);
  except
    on E: ESecurityPrecheck do raise ESecurityPrecheck.Create('Target server /ping: ' + E.Message);
  end;
  try
    CheckHttps(RepositoryURL + '/Packages', Bundle);
  except
    on E: ESecurityPrecheck do raise ESecurityPrecheck.Create('Target repository /Packages: ' + E.Message);
  end;
end;

end.
