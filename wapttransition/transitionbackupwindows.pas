unit transitionbackupwindows;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, Windows, fpjson;

procedure RequireRestorableServiceAccount(const Name: UnicodeString);
function BackupServiceState(const Name: UnicodeString; MissingAllowed: Boolean = False): DWORD;
procedure StopBackupService(const Name: UnicodeString);
procedure RestoreBackupService(const Name: UnicodeString; InitialState: DWORD);
procedure RequireScheduledWaptIdle(const InstallDir: UnicodeString);
procedure DiscoverWaptShortcuts(const InstallDir: UnicodeString; Paths: TStrings);
function MergeWaptPath(const Current, InstallDir: UnicodeString; Saved: TJSONArray): UnicodeString;
procedure RestoreWaptPath(const BackupRoot, InstallDir: UnicodeString; Entries: TJSONArray);
procedure RestoreWaptServiceConfig(const BackupRoot, ServiceName: UnicodeString; Entries: TJSONArray);
procedure RestoreWaptRegistry(const BackupRoot: UnicodeString; Entries: TJSONArray;
  const FixtureName: UnicodeString = '');
procedure RestoreWaptTasks(const BackupRoot, InstallDir, ServiceName: UnicodeString; Entries: TJSONArray);
procedure CaptureWaptWindowsMetadata(const Root, InstallDir, ServiceName: UnicodeString; Entries: TJSONArray);

implementation

uses ActiveX, ComObj, Variants, WinDirs, transitionstorage, transitionsecurity,
  transitionbackup, jsonparser;

const
  UninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WAPT_is1';
  AppPathKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\wapt-get.exe';
  ServiceKey = 'SYSTEM\CurrentControlSet\Services\WAPTService';
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

procedure Require(Value: Boolean; const Diagnostic: string);
begin
  if not Value then raise ETransitionBackup.Create(Diagnostic);
end;

procedure RequireRestorableServiceAccount(const Name: UnicodeString);
const
  MaxConfig = 8192;
var
  Manager, Service: SC_HANDLE;
  Buffer: array of Byte;
  Config: PQueryServiceConfigW;
  Needed: DWORD;
  Account: UnicodeString;
begin
  Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  Require(Manager <> 0, 'Cannot inspect the WAPT service account');
  try
    Service := OpenServiceW(Manager, PWideChar(Name), SERVICE_QUERY_CONFIG);
    Require(Service <> 0, 'Cannot open the WAPT service configuration');
    try
      Require(not QueryServiceConfigW(Service, nil, 0, @Needed) and
        (GetLastError = ERROR_INSUFFICIENT_BUFFER) and (Needed > 0) and
        (Needed <= MaxConfig), 'Cannot determine WAPT service configuration size');
      SetLength(Buffer, Needed);
      Config := PQueryServiceConfigW(@Buffer[0]);
      Require(QueryServiceConfigW(Service, Config, Length(Buffer), @Needed),
        'Cannot query WAPT service configuration');
      Account := Config^.lpServiceStartName;
      Require(UnicodeSameText(Account, 'LocalSystem') or
        UnicodeSameText(Account, 'NT AUTHORITY\LocalService') or
        UnicodeSameText(Account, 'NT AUTHORITY\NetworkService'),
        'Custom WAPT service account cannot be restored without its credentials');
    finally
      CloseServiceHandle(Service);
    end;
  finally
    CloseServiceHandle(Manager);
  end;
end;

function BackupServiceState(const Name: UnicodeString; MissingAllowed: Boolean): DWORD;
var
  Manager, Service: SC_HANDLE;
  Status: TServiceStatus;
begin
  Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  Require(Manager <> 0, 'Cannot inspect the backup service through SCM');
  try
    Service := OpenServiceW(Manager, PWideChar(Name), SERVICE_QUERY_STATUS);
    if (Service = 0) and MissingAllowed and (GetLastError = ERROR_SERVICE_DOES_NOT_EXIST) then Exit(0);
    Require(Service <> 0, 'Backup service is unavailable');
    try
      Require(QueryServiceStatus(Service, Status), 'Cannot query backup service status');
      Result := Status.dwCurrentState;
    finally
      CloseServiceHandle(Service);
    end;
  finally
    CloseServiceHandle(Manager);
  end;
end;

procedure StopBackupService(const Name: UnicodeString);
var
  Manager, Service: SC_HANDLE;
  Status: TServiceStatus;
  Deadline: QWord;
begin
  Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  Require(Manager <> 0, 'Cannot connect to SCM to stop the backup service');
  try
    Service := OpenServiceW(Manager, PWideChar(Name), SERVICE_STOP or SERVICE_QUERY_STATUS);
    Require(Service <> 0, 'Cannot open the backup service');
    try
      Require(QueryServiceStatus(Service, Status), 'Cannot query backup service before stop');
      if Status.dwCurrentState = SERVICE_STOPPED then Exit;
      Require(Status.dwCurrentState = SERVICE_RUNNING, 'Backup service state is unstable');
      Require(ControlService(Service, SERVICE_CONTROL_STOP, @Status),
        'Backup service did not accept a controlled stop');
      Deadline := GetTickCount64 + 15000;
      repeat
        Require(QueryServiceStatus(Service, Status), 'Cannot query stopped backup service');
        if Status.dwCurrentState = SERVICE_STOPPED then Exit;
        Require(GetTickCount64 < Deadline, 'Timed out waiting for the backup service to stop');
        Sleep(100);
      until False;
    finally
      CloseServiceHandle(Service);
    end;
  finally
    CloseServiceHandle(Manager);
  end;
end;

procedure RestoreBackupService(const Name: UnicodeString; InitialState: DWORD);
var
  Manager, Service: SC_HANDLE;
  Current: DWORD;
  Deadline: QWord;
  Starting: Boolean;
begin
  Deadline := GetTickCount64 + 15000;
  Starting := False;
  repeat
    Current := BackupServiceState(Name);
    if Current = InitialState then Exit;
    case Current of
      SERVICE_RUNNING: StopBackupService(Name);
      SERVICE_STOPPED:
        begin
          Require(not Starting, 'Backup service failed to stay started');
          Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
          Require(Manager <> 0, 'Cannot connect to SCM to restart the backup service');
          try
            Service := OpenServiceW(Manager, PWideChar(Name), SERVICE_START);
            Require(Service <> 0, 'Cannot open the backup service for restart');
            try
              Require(StartServiceW(Service, 0, nil), 'Cannot restart the backup service');
            finally
              CloseServiceHandle(Service);
            end;
          finally
            CloseServiceHandle(Manager);
          end;
          Starting := True;
        end;
      SERVICE_START_PENDING, SERVICE_STOP_PENDING: ;
      else raise ETransitionBackup.Create('Backup service state is uncertain after backup failure');
    end;
    Require(GetTickCount64 < Deadline, 'Timed out restoring the backup service state');
    Sleep(100);
  until False;
end;

function IsWaptExecutable(const FileName, InstallDir: UnicodeString): Boolean;
var
  Normal: UnicodeString;
begin
  Result := False;
  if (Length(FileName) < 3) or (FileName[2] <> ':') or (FileName[3] <> '\') then Exit;
  Normal := ExpandFileName(FileName);
  Result := UnicodeSameText(IncludeTrailingPathDelimiter(InstallDir),
    Copy(Normal, 1, Length(IncludeTrailingPathDelimiter(InstallDir)))) and
    UnicodeSameText(ExtractFileExt(Normal), '.exe');
end;

procedure AddArtifact(const Root, Relative: UnicodeString; const Source, Kind: UTF8String;
  Entries: TJSONArray);
var
  Handle: THandle;
  Info: TByHandleFileInformation;
  Entry: TJSONObject;
begin
  Handle := OpenStorageFile(Root + Relative, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
  Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot verify protected Windows backup snapshot');
  try
    Require(GetFileInformationByHandle(Handle, Info), 'Cannot inspect Windows backup snapshot');
    Entry := TJSONObject.Create;
    Entries.Add(Entry);
    Entry.Add('source', Source);
    Entry.Add('backup', UTF8Encode(Relative));
    Entry.Add('artifact', Kind);
    Entry.Add('directory', False);
    Entry.Add('size', (QWord(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow);
    Entry.Add('sha256', FileSHA256(Handle));
  finally
    CloseHandle(Handle);
  end;
end;

procedure SaveArtifact(const Root, Relative: UnicodeString; const Source, Kind: UTF8String;
  const Data: RawByteString; Entries: TJSONArray);
var
  Handle: THandle;
  Stream: THandleStream;
begin
  Handle := OpenStorageFile(Root + Relative, GENERIC_WRITE, 0, CREATE_NEW);
  Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot create protected Windows backup snapshot');
  try
    Stream := THandleStream.Create(Handle);
    try
      if Data <> '' then Stream.WriteBuffer(Data[1], Length(Data));
      Require(FlushFileBuffers(Handle), 'Cannot flush Windows backup snapshot');
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Handle);
  end;
  AddArtifact(Root, Relative, Source, Kind, Entries);
end;

procedure CollectTasks(const InstallDir, Root, FolderPath: UnicodeString; Entries: TJSONArray);
var
  Scheduler: OleVariant;
  Number: Integer;

  procedure Scan(const Folder: OleVariant);
  var
    Tasks, Task, Actions, Action, Children: OleVariant;
    I, J, Count: Integer;
    Name, Command, XML: UnicodeString;
    EncodedXML: RawByteString;
    Owned: Boolean;
  begin
    Tasks := Folder.GetTasks(1); // include hidden tasks
    Count := Tasks.Count;
    for I := 1 to Count do
    begin
      Task := Tasks.Item[I];
      Actions := Task.Definition.Actions;
      Name := UnicodeString(Task.Path);
      Owned := False;
      for J := 1 to Integer(Actions.Count) do
      begin
        Action := Actions.Item[J];
        if Integer(Action.&Type) <> 0 then Continue; // TASK_ACTION_EXEC
        Command := UnicodeString(Action.Path);
        Owned := IsWaptExecutable(Command, InstallDir) or
          (UnicodeSameText(FolderPath, '\') and UnicodeSameText(Name, '\waptservicerestart') and
           UnicodeSameText(ExtractFileName(Command), 'cmd.exe') and
           UnicodeSameText(UnicodeString(Action.Arguments),
             '/C net stop waptservice & net start waptservice'));
        if Owned then Break;
      end;
      if not Owned then Continue;
      Require(not (Integer(Task.State) in [2, 4]), 'A WAPT scheduled task is queued or running');
      Require(Integer(Task.Definition.Principal.LogonType) in [3, 4, 5],
        'A WAPT task uses an account logon mode that cannot be restored');
      if Entries <> nil then
      begin
        Inc(Number);
        XML := UnicodeString(#$FEFF) + UnicodeString(Task.Xml);
        SetString(EncodedXML, PAnsiChar(PWideChar(XML)), Length(XML) * 2);
        SaveArtifact(Root, 'tasks\' + UnicodeString(IntToStr(Number)) + '.xml',
          UTF8Encode(Name), 'task', EncodedXML, Entries);
        Entries.Objects[Entries.Count - 1].Add('sddl',
          UTF8Encode(UnicodeString(Task.GetSecurityDescriptor(7))));
      end;
    end;
    Children := Folder.GetFolders(0);
    for I := 1 to Integer(Children.Count) do Scan(Children.Item[I]);
  end;

begin
  Require(Succeeded(CoInitialize(nil)), 'Cannot initialize Task Scheduler COM');
  try
    try
      Number := 0;
      Scheduler := CreateOleObject('Schedule.Service');
      Scheduler.Connect;
      Scan(Scheduler.GetFolder(WideString(FolderPath)));
    except
      on E: ETransitionBackup do raise;
      on E: Exception do raise ETransitionBackup.Create('Cannot inspect or export WAPT scheduled tasks');
    end;
  finally
    VarClear(Scheduler);
    CoUninitialize;
  end;
end;

procedure RequireScheduledWaptIdle(const InstallDir: UnicodeString);
begin
  CollectTasks(InstallDir, '', '\', nil);
end;

procedure DiscoverWaptShortcuts(const InstallDir: UnicodeString; Paths: TStrings);
var
  Shell: OleVariant;

  procedure Scan(const Folder: UnicodeString);
  var
    Search: THandle;
    Info: TWin32FindDataW;
    Name, Path: UnicodeString;
    Shortcut: OleVariant;
    Code: DWORD;
  begin
    if Folder = '' then Exit;
    CheckLocalPath(Folder);
    Search := FindFirstFileW(PWideChar(IncludeTrailingPathDelimiter(Folder) + '*'), Info);
    if Search = INVALID_HANDLE_VALUE then
    begin
      Code := GetLastError;
      if Code = ERROR_FILE_NOT_FOUND then Exit;
      raise ETransitionBackup.Create('Cannot inspect WAPT shortcut locations');
    end;
    try
      repeat
        Name := PWideChar(@Info.cFileName[0]);
        if (Name = '.') or (Name = '..') or
           ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then Continue;
        Path := IncludeTrailingPathDelimiter(Folder) + Name;
        if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then Scan(Path)
        else if UnicodeSameText(ExtractFileExt(Name), '.lnk') then
        begin
          Shortcut := Shell.CreateShortcut(WideString(Path));
          if IsWaptExecutable(UnicodeString(Shortcut.TargetPath), InstallDir) then
            Paths.Add(UTF8Encode(Path));
        end;
      until not FindNextFileW(Search, Info);
      Require(GetLastError = ERROR_NO_MORE_FILES, 'Cannot enumerate WAPT shortcut locations');
    finally
      Windows.FindClose(Search);
    end;
  end;

begin
  Require(Succeeded(CoInitialize(nil)), 'Cannot initialize shortcut discovery COM');
  try
    try
      Shell := CreateOleObject('WScript.Shell');
      Scan(GetWindowsSpecialDirUnicode(CSIDL_COMMON_STARTUP, False));
      Scan(GetWindowsSpecialDirUnicode(CSIDL_COMMON_PROGRAMS, False));
    except
      on E: ETransitionBackup do raise;
      on E: Exception do raise ETransitionBackup.Create('Cannot inspect WAPT shortcuts');
    end;
  finally
    VarClear(Shell);
    CoUninitialize;
  end;
end;

function IsWaptPathPart(const Part, InstallDir: UnicodeString): Boolean;
var
  Expanded: array[0..32767] of WideChar;
  Size: DWORD;
begin
  Size := ExpandEnvironmentStringsW(PWideChar(Part), @Expanded[0], Length(Expanded));
  Require((Size > 0) and (Size <= Length(Expanded)), 'Cannot expand PATH entry');
  Result := UnicodeSameText(ExcludeTrailingPathDelimiter(UnicodeString(PWideChar(@Expanded[0]))), InstallDir);
end;

function MergeWaptPath(const Current, InstallDir: UnicodeString; Saved: TJSONArray): UnicodeString;
var
  Parts: TStringList;
  Part: UnicodeString;
  I, Start, Position: Integer;
begin
  Parts := TStringList.Create;
  try
    Start := 1;
    for I := 1 to Length(Current) + 1 do
      if (I > Length(Current)) or (Current[I] = ';') then
      begin
        Part := Copy(Current, Start, I-Start);
        if not IsWaptPathPart(Part, InstallDir) then Parts.Add(UTF8Encode(Part));
        Start := I + 1;
      end;
    for I := 0 to Saved.Count - 1 do
    begin
      Part := UTF8Decode(Saved.Objects[I].Strings['value']);
      Position := Saved.Objects[I].Integers['index'];
      Require((Position >= 0) and (Pos(';', Part) = 0) and (Pos(#0, Part) = 0) and
        IsWaptPathPart(Part, InstallDir), 'Invalid WAPT PATH backup part');
      if Position > Parts.Count then Position := Parts.Count;
      Parts.Insert(Position, UTF8Encode(Part));
    end;
    Result := '';
    for I := 0 to Parts.Count - 1 do
    begin
      if I > 0 then Result := Result + ';';
      Result := Result + UTF8Decode(Parts[I]);
    end;
  finally
    Parts.Free;
  end;
end;

procedure RestoreWaptPath(const BackupRoot, InstallDir: UnicodeString; Entries: TJSONArray);
var
  Entry: TJSONObject;
  Saved: TJSONData;
  Handle: THandle;
  Stream: THandleStream;
  Registry: HKEY;
  Current, Restored, Verified: UnicodeString;
  Kind, Size, VerifiedKind: DWORD;
  I: Integer;
begin
  for I := 0 to Entries.Count - 1 do
  begin
    Entry := Entries.Objects[I];
    if Entry.Get('artifact', '') <> 'path-entries' then Continue;
    Require((Entry.Strings['backup'] = 'registry\wapt-path.json') and
      (Entry.Strings['source'] = 'HKLM\' + UTF8Encode(EnvironmentKey) + '\Path'),
      'PATH backup scope mismatch');
    Handle := OpenStorageFile(IncludeTrailingPathDelimiter(BackupRoot) + 'registry\wapt-path.json',
      GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
    Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot open WAPT PATH backup');
    try
      Stream := THandleStream.Create(Handle);
      try
        Require((Stream.Size <= 65536) and (FileSHA256(Handle) = Entry.Strings['sha256']),
          'WAPT PATH backup has changed');
        Stream.Position := 0;
        Saved := GetJSON(Stream);
      finally
        Stream.Free;
      end;
    finally
      CloseHandle(Handle);
    end;
    try
      Require(Saved is TJSONArray, 'Invalid WAPT PATH backup');
      Require(RegOpenKeyExW(HKEY_LOCAL_MACHINE, EnvironmentKey, 0, KEY_QUERY_VALUE or KEY_SET_VALUE,
        Registry) = ERROR_SUCCESS, 'Cannot open system PATH for restore');
      try
        Require((RegQueryValueExW(Registry, 'Path', nil, @Kind, nil, @Size) = ERROR_SUCCESS) and
          (Kind in [REG_SZ, REG_EXPAND_SZ]) and (Size >= 2) and (Size <= 65536) and
          (Size mod 2 = 0), 'Invalid current system PATH');
        SetLength(Current, Size div 2);
        Require((RegQueryValueExW(Registry, 'Path', nil, @Kind, @Current[1], @Size) = ERROR_SUCCESS) and
          (Current[Size div 2] = #0), 'Cannot read current system PATH');
        SetLength(Current, Size div 2 - 1);
        Require(Pos(#0, Current) = 0, 'Current system PATH contains an embedded terminator');
        Restored := MergeWaptPath(Current, InstallDir, TJSONArray(Saved));
        if Restored <> Current then
        begin
          Require(RegSetValueExW(Registry, 'Path', 0, Kind, PByte(PWideChar(Restored)),
            (Length(Restored)+1)*2) = ERROR_SUCCESS, 'Cannot merge WAPT entries into system PATH');
          SetLength(Verified, Length(Restored) + 1);
          Size := Length(Verified)*2;
          Require((RegQueryValueExW(Registry, 'Path', nil, @VerifiedKind, PByte(@Verified[1]), @Size) =
            ERROR_SUCCESS) and (VerifiedKind = Kind) and (Size = Length(Verified)*2) and
            (Verified = Restored + #0), 'Restored system PATH differs from the scoped merge');
        end;
      finally
        RegCloseKey(Registry);
      end;
    finally
      Saved.Free;
    end;
    Exit;
  end;
end;

function LoadServiceHive(FileName: PWideChar; out Hive: HKEY; Access, Options, Reserved: DWORD): LongInt; stdcall;
  external 'advapi32.dll' name 'RegLoadAppKeyW';
function CopyRegistryTree(Source: HKEY; SubKey: PWideChar; Target: HKEY): LongInt; stdcall;
  external 'advapi32.dll' name 'RegCopyTreeW';
function EmptyRegistryTree(Key: HKEY; SubKey: PWideChar): LongInt; stdcall;
  external 'advapi32.dll' name 'RegDeleteTreeW';

procedure DeleteHiveWorkingCopy(const Path: UnicodeString);
begin
  if Path = '' then Exit;
  DeleteFileW(PWideChar(Path));
  DeleteFileW(PWideChar(Path + '.LOG1'));
  DeleteFileW(PWideChar(Path + '.LOG2'));
end;

function NewHiveWorkingCopy(const BackupRoot: UnicodeString; Source: THandle): UnicodeString;
var
  ID: TGUID;
  Destination: THandle;
  Input, Output: THandleStream;
begin
  Require(CreateGUID(ID) = 0, 'Cannot name protected hive working copy');
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(BackupRoot))) +
    'staging\restore-' + UnicodeString(GUIDToString(ID)) + '.hiv';
  Destination := OpenStorageFile(Result, GENERIC_WRITE, 0, CREATE_NEW);
  Require(Destination <> INVALID_HANDLE_VALUE, 'Cannot create protected hive working copy');
  try
    try
      Input := THandleStream.Create(Source);
      try
        Input.Position := 0;
        Output := THandleStream.Create(Destination);
        try
          Output.CopyFrom(Input, 0);
        finally
          Output.Free;
        end;
      finally
        Input.Free;
      end;
      Require(FlushFileBuffers(Destination), 'Cannot flush protected hive working copy');
    finally
      CloseHandle(Destination);
    end;
  except
    DeleteHiveWorkingCopy(Result);
    raise;
  end;
end;

procedure VerifyRegistryTree(Expected, Actual: HKEY); forward;

procedure RestoreWaptServiceConfig(const BackupRoot, ServiceName: UnicodeString; Entries: TJSONArray);
var
  Entry: TJSONObject;
  Path, WorkingCopy, Relative, Image, Account, Display, Group, Dependencies, Value: UnicodeString;
  Hive, Parameters, TargetKey: HKEY;
  FileHandle: THandle;
  Manager, Service: SC_HANDLE;
  ServiceType, StartMode, ErrorMode, Size, Kind: DWORD;
  Config: PQueryServiceConfigW;
  Buffer: array of Byte;
  I: Integer;

  function Number(const Name: UnicodeString): DWORD;
  var
    Kind, Size: DWORD;
  begin
    Size := SizeOf(Result);
    Require((RegQueryValueExW(Hive, PWideChar(Name), nil, @Kind, @Result, @Size) = ERROR_SUCCESS) and
      (Kind = REG_DWORD) and (Size = SizeOf(Result)), 'Missing backed-up service setting');
  end;

  function Text(const Name: UnicodeString; Optional: Boolean; Multi: Boolean = False): UnicodeString;
  var
    Code: LongInt;
    Size, Kind: DWORD;
  begin
    Code := RegQueryValueExW(Hive, PWideChar(Name), nil, @Kind, nil, @Size);
    if Optional and (Code = ERROR_FILE_NOT_FOUND) then Exit('');
    Require((Code = ERROR_SUCCESS) and (Size >= 2) and (Size <= 16384) and (Size mod 2 = 0) and
      ((not Multi and (Kind in [REG_SZ, REG_EXPAND_SZ])) or (Multi and (Kind = REG_MULTI_SZ))),
      'Invalid backed-up service setting');
    SetLength(Result, Size div 2);
    Require((RegQueryValueExW(Hive, PWideChar(Name), nil, @Kind, @Result[1], @Size) = ERROR_SUCCESS) and
      (Result[Size div 2] = #0), 'Cannot read backed-up service setting');
    SetLength(Result, Size div 2 - 1);
    if not Multi then Require(Pos(#0, Result) = 0, 'Invalid service setting terminator');
  end;

begin
  if UnicodeSameText(ServiceName, 'WAPTService') then Relative := 'services\waptservice.hiv'
  else
  begin
    Require(Pos('PADIT_BackupTest_', ServiceName) = 1, 'Invalid isolated service name');
    Relative := 'services\fixture.hiv';
  end;
  Entry := nil;
  for I := 0 to Entries.Count-1 do
    if Entries.Objects[I].Get('backup', '') = UTF8Encode(Relative) then Entry := Entries.Objects[I];
  Require((Entry <> nil) and (Entry.Get('artifact', '') = 'registry-hive') and
    UnicodeSameText(UTF8Decode(Entry.Strings['source']), 'HKLM\SYSTEM\CurrentControlSet\Services\' + ServiceName),
    'Service hive is missing or outside restore scope');
  Path := IncludeTrailingPathDelimiter(BackupRoot) + Relative;
  FileHandle := OpenStorageFile(Path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
  Require(FileHandle <> INVALID_HANDLE_VALUE, 'Cannot open verified service hive');
  try
    Require(FileSHA256(FileHandle) = Entry.Strings['sha256'], 'Service hive changed before restore');
    WorkingCopy := NewHiveWorkingCopy(BackupRoot, FileHandle);
    Require(LoadServiceHive(PWideChar(WorkingCopy), Hive, KEY_READ, 1, 0) = ERROR_SUCCESS,
      'Cannot load protected service hive working copy');
    try
      ServiceType := Number('Type');
      StartMode := Number('Start');
      ErrorMode := Number('ErrorControl');
      Image := Text('ImagePath', False);
      Account := Text('ObjectName', False);
      Display := Text('DisplayName', True);
      Group := Text('Group', True);
      Dependencies := Text('DependOnService', True, True);
      Require(Text('DependOnGroup', True, True) = '', 'Backed-up service has unsupported group dependencies');
      Require((ServiceType = SERVICE_WIN32_OWN_PROCESS) and (StartMode in
        [SERVICE_AUTO_START, SERVICE_DEMAND_START, SERVICE_DISABLED]) and (Image <> '') and
        (UnicodeSameText(Account, 'LocalSystem') or UnicodeSameText(Account, 'NT AUTHORITY\LocalService') or
         UnicodeSameText(Account, 'NT AUTHORITY\NetworkService')), 'Unsupported backed-up WAPT service configuration');
      Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT or SC_MANAGER_CREATE_SERVICE);
      Require(Manager <> 0, 'Cannot connect to SCM for service restore');
      try
        Service := OpenServiceW(Manager, PWideChar(ServiceName), SERVICE_CHANGE_CONFIG or SERVICE_QUERY_CONFIG);
        if (Service = 0) and (GetLastError = ERROR_SERVICE_DOES_NOT_EXIST) then
          Service := CreateServiceW(Manager, PWideChar(ServiceName), PWideChar(Display),
            SERVICE_CHANGE_CONFIG or SERVICE_QUERY_CONFIG, ServiceType, StartMode, ErrorMode,
            PWideChar(Image), PWideChar(Group), nil, PWideChar(Dependencies), PWideChar(Account), nil);
        Require(Service <> 0, 'Cannot open or recreate historical WAPT service');
        try
          Require(BackupServiceState(ServiceName) = SERVICE_STOPPED, 'Service must be stopped before SCM restore');
          Require(ChangeServiceConfigW(Service, ServiceType, StartMode, ErrorMode, PWideChar(Image),
            PWideChar(Group), nil, PWideChar(Dependencies), PWideChar(Account), nil, PWideChar(Display)),
            'Cannot restore historical configuration through SCM');
          Require(not QueryServiceConfigW(Service, nil, 0, @Size) and
            (GetLastError = ERROR_INSUFFICIENT_BUFFER) and (Size > 0) and (Size <= 8192),
            'Cannot determine restored service configuration size');
          SetLength(Buffer, Size);
          Config := PQueryServiceConfigW(@Buffer[0]);
          Require(QueryServiceConfigW(Service, Config, Length(Buffer), @Size) and
            (Config^.dwServiceType = ServiceType) and (Config^.dwStartType = StartMode) and
            (Config^.dwErrorControl = ErrorMode) and
            (UnicodeString(Config^.lpBinaryPathName) = Image) and
            UnicodeSameText(UnicodeString(Config^.lpServiceStartName), Account),
            'Restored SCM configuration differs from the backup');
        finally
          CloseServiceHandle(Service);
        end;
      finally
        CloseServiceHandle(Manager);
      end;
      if RegOpenKeyExW(Hive, 'Parameters', 0, KEY_READ, Parameters) = ERROR_SUCCESS then
      try
        Value := 'SYSTEM\CurrentControlSet\Services\' + ServiceName + '\Parameters';
        Require(RegCreateKeyExW(HKEY_LOCAL_MACHINE, PWideChar(Value), 0, nil, 0,
          KEY_ALL_ACCESS, nil, TargetKey, nil) = ERROR_SUCCESS, 'Cannot open WAPT service parameters');
        try
          Require(EmptyRegistryTree(TargetKey, nil) = ERROR_SUCCESS, 'Cannot clear obsolete WAPT service parameters');
          Require(CopyRegistryTree(Parameters, nil, TargetKey) = ERROR_SUCCESS, 'Cannot restore WAPT service parameters');
          VerifyRegistryTree(Parameters, TargetKey);
        finally
          RegCloseKey(TargetKey);
        end;
      finally
        RegCloseKey(Parameters);
      end;
    finally
      RegCloseKey(Hive);
    end;
  finally
    CloseHandle(FileHandle);
    DeleteHiveWorkingCopy(WorkingCopy);
  end;
end;

procedure VerifyRegistryTree(Expected, Actual: HKEY);
var
  Index, NameCount, Size, Got, Kind, ActualKind: DWORD;
  Code: LongInt;
  Name: array[0..16383] of WideChar;
  ExpectedData, ActualData: array of Byte;
  ExpectedChild, ActualChild: HKEY;
begin
  Index := 0;
  repeat
    NameCount := Length(Name);
    Code := RegEnumValueW(Expected, Index, @Name[0], NameCount, nil, @Kind, nil, @Size);
    if Code = ERROR_NO_MORE_ITEMS then Break;
    Require((Code = ERROR_SUCCESS) and (Size <= 16*1024*1024), 'Cannot inspect saved WAPT registry value');
    SetLength(ExpectedData, Size);
    SetLength(ActualData, Size);
    Got := Size;
    Require(RegQueryValueExW(Expected, @Name[0], nil, @Kind, PByte(ExpectedData), @Got) = ERROR_SUCCESS,
      'Cannot read saved WAPT registry value');
    Got := Size;
    Require((RegQueryValueExW(Actual, @Name[0], nil, @ActualKind, PByte(ActualData), @Got) = ERROR_SUCCESS)
      and (ActualKind = Kind) and (Got = Size) and
      ((Size = 0) or CompareMem(PByte(ExpectedData), PByte(ActualData), Size)),
      'Restored WAPT registry value differs from backup');
    Inc(Index);
  until False;
  NameCount := Length(Name);
  Require(RegEnumValueW(Actual, Index, @Name[0], NameCount, nil, nil, nil, nil) = ERROR_NO_MORE_ITEMS,
    'Restored WAPT registry contains unexpected values');
  Index := 0;
  repeat
    NameCount := Length(Name);
    Code := RegEnumKeyExW(Expected, Index, @Name[0], @NameCount, nil, nil, nil, nil);
    if Code = ERROR_NO_MORE_ITEMS then Break;
    Require(Code = ERROR_SUCCESS, 'Cannot inspect saved WAPT subkey');
    Require(RegOpenKeyExW(Expected, @Name[0], 0, KEY_READ, ExpectedChild) = ERROR_SUCCESS,
      'Cannot open saved WAPT subkey');
    try
      Require(RegOpenKeyExW(Actual, @Name[0], 0, KEY_READ, ActualChild) = ERROR_SUCCESS,
        'Restored WAPT subkey is missing');
      try
        VerifyRegistryTree(ExpectedChild, ActualChild);
      finally
        RegCloseKey(ActualChild);
      end;
    finally
      RegCloseKey(ExpectedChild);
    end;
    Inc(Index);
  until False;
  NameCount := Length(Name);
  Require(RegEnumKeyExW(Actual, Index, @Name[0], @NameCount, nil, nil, nil, nil) = ERROR_NO_MORE_ITEMS,
    'Restored WAPT registry contains unexpected subkeys');
end;

procedure RestoreWaptRegistry(const BackupRoot: UnicodeString; Entries: TJSONArray;
  const FixtureName: UnicodeString);
const
  Names: array[0..3] of UnicodeString = ('registry\uninstall32.hiv', 'registry\uninstall64.hiv',
    'registry\app-path32.hiv', 'registry\app-path64.hiv');
  Keys: array[0..3] of UnicodeString = (UninstallKey, UninstallKey, AppPathKey, AppPathKey);
  Views: array[0..3] of DWORD = (KEY_WOW64_32KEY, KEY_WOW64_64KEY,
    KEY_WOW64_32KEY, KEY_WOW64_64KEY);
var
  HiveFile: THandle;
  Registry, ExpectedHive: HKEY;
  Entry: TJSONObject;
  Relative, Path, Key, WorkingCopy: UnicodeString;
  View: DWORD;
  I, J: Integer;
begin
  Require((FixtureName = '') or (Pos('PADIT_BackupTest_', FixtureName) = 1),
    'Invalid registry fixture name');
  for I := 0 to Entries.Count - 1 do
  begin
    Entry := Entries.Objects[I];
    if Entry.Get('artifact', '') <> 'registry-hive' then Continue;
    Relative := UTF8Decode(Entry.Strings['backup']);
    Key := '';
    View := 0;
    if FixtureName <> '' then
    begin
      if Relative = 'registry\fixture.hiv' then
      begin
        Key := 'SOFTWARE\' + FixtureName;
        View := KEY_WOW64_64KEY;
      end;
    end
    else
      for J := Low(Names) to High(Names) do
        if Relative = Names[J] then
        begin
          Key := Keys[J];
          View := Views[J];
          Break;
        end;
    if Key <> '' then
    begin
      J := 64;
      if View = KEY_WOW64_32KEY then J := 32;
      Require(Entry.Strings['source'] = 'HKLM\' + UTF8Encode(Key) +
        ' [' + IntToStr(J) + ']', 'Registry backup scope mismatch');
      Path := IncludeTrailingPathDelimiter(BackupRoot) + Relative;
      HiveFile := OpenStorageFile(Path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
      Require(HiveFile <> INVALID_HANDLE_VALUE, 'Cannot open registry backup');
      try
        Require(FileSHA256(HiveFile) = Entry.Strings['sha256'], 'Registry backup changed');
        WorkingCopy := NewHiveWorkingCopy(BackupRoot, HiveFile);
        Require(LoadServiceHive(PWideChar(WorkingCopy), ExpectedHive, KEY_READ, 1, 0) = ERROR_SUCCESS,
          'Cannot load protected registry working copy');
        try
          Require(RegCreateKeyExW(HKEY_LOCAL_MACHINE, PWideChar(Key), 0, nil, 0,
            KEY_ALL_ACCESS or View, nil, Registry, nil) = ERROR_SUCCESS,
            'Cannot open the permitted WAPT registry key for restore');
          try
            // Replace only the contents of this explicitly identified WAPT key.
            Require(EmptyRegistryTree(Registry, nil) = ERROR_SUCCESS, 'Cannot clear obsolete WAPT registry data');
            Require(CopyRegistryTree(ExpectedHive, nil, Registry) = ERROR_SUCCESS,
              'Cannot restore the permitted WAPT registry key');
            VerifyRegistryTree(ExpectedHive, Registry);
          finally
            RegCloseKey(Registry);
          end;
        finally
          RegCloseKey(ExpectedHive);
        end;
      finally
        CloseHandle(HiveFile);
        DeleteHiveWorkingCopy(WorkingCopy);
        WorkingCopy := '';
      end;
    end;
  end;
end;

function SameTaskSecurity(const Saved, Actual: UnicodeString): Boolean;
var
  Left, Right: TStringList;
  SavedHeader, ActualHeader: UnicodeString;

  function NormalizeAllowList(const Sddl: UnicodeString; Entries: TStrings;
    out Header: UnicodeString): Boolean;
  var
    Dacl, First, Finish: SizeInt;
    Flags, Ace: UnicodeString;
  begin
    Result := False;
    Dacl := Pos('D:', Sddl);
    First := Pos('(', Sddl);
    if (Dacl = 0) or (First <= Dacl) then Exit;
    Flags := Copy(Sddl, Dacl + 2, First - Dacl - 2);
    Header := Copy(Sddl, 1, Dacl + 1) +
      UnicodeString(StringReplace(UTF8Encode(Flags), 'AI', '', [rfReplaceAll]));
    while First <= Length(Sddl) do
    begin
      Finish := First;
      while (Finish <= Length(Sddl)) and (Sddl[Finish] <> ')') do Inc(Finish);
      if Finish > Length(Sddl) then Exit;
      Ace := Copy(Sddl, First, Finish - First + 1);
      if Copy(Ace, 1, 3) <> '(A;' then Exit;
      Entries.Add(UTF8Encode(Ace));
      First := Finish + 1;
    end;
    Result := True;
  end;

begin
  if Saved = Actual then Exit(True);
  Left := TStringList.Create;
  Right := TStringList.Create;
  try
    Left.CaseSensitive := True;
    Right.CaseSensitive := True;
    Left.Duplicates := dupAccept;
    Right.Duplicates := dupAccept;
    Left.Sorted := True;
    Right.Sorted := True;
    // Windows canonicalizes the order of allow ACEs and adds the auto-inherited marker.
    Result := NormalizeAllowList(Saved, Left, SavedHeader) and
      NormalizeAllowList(Actual, Right, ActualHeader) and (SavedHeader = ActualHeader) and
      (Left.Text = Right.Text);
  finally
    Right.Free;
    Left.Free;
  end;
end;

function TaskXMLWithoutDescriptor(const XML: UnicodeString): UnicodeString;
const
  StartTag = '<SecurityDescriptor>';
  EndTag = '</SecurityDescriptor>';
var
  Start, Finish, RegistrationEnd: SizeInt;
begin
  Result := XML;
  Start := Pos(StartTag, Result);
  if Start = 0 then Exit;
  Finish := Pos(EndTag, Result);
  RegistrationEnd := Pos('</RegistrationInfo>', Result);
  Require((Pos('<RegistrationInfo>', Result) < Start) and (Start < Finish) and
    (Finish < RegistrationEnd), 'Invalid registration security descriptor in task XML');
  // Task Scheduler serializes this descriptor separately. Verify the effective ACL through COM.
  Finish := Finish + Length(EndTag);
  while (Start > 1) and (Result[Start-1] in [' ', #9]) do Dec(Start);
  while (Finish <= Length(Result)) and (Result[Finish] in [' ', #9]) do Inc(Finish);
  if (Finish <= Length(Result)) and (Result[Finish] = #13) then Inc(Finish);
  if (Finish <= Length(Result)) and (Result[Finish] = #10) then Inc(Finish);
  Delete(Result, Start, Finish - Start);
end;

procedure RestoreWaptTasks(const BackupRoot, InstallDir, ServiceName: UnicodeString; Entries: TJSONArray);
var
  Scheduler, Definition, Folder, Task, Action, Account: OleVariant;
  Entry: TJSONObject;
  Handle: THandle;
  Stream: THandleStream;
  Path, FolderPath, Name, XML, Sddl, Command: UnicodeString;
  I, J, LogonType: Integer;
  Owned: Boolean;
begin
  Require(Succeeded(CoInitialize(nil)), 'Cannot initialize task restoration');
  try
    Scheduler := CreateOleObject('Schedule.Service');
    Scheduler.Connect;
    for I := 0 to Entries.Count - 1 do
    begin
      Entry := Entries.Objects[I];
      if Entry.Get('artifact', '') <> 'task' then Continue;
      Path := UTF8Decode(Entry.Strings['source']);
      J := LastDelimiter('\', Path);
      FolderPath := Copy(Path, 1, J-1);
      if FolderPath = '' then FolderPath := '\';
      Name := Copy(Path, J+1, MaxInt);
      Require((J > 0) and (Path[1] = '\') and (Name <> '') and
        (Pos(#0, Path) = 0) and (Pos('..', Path) = 0), 'Invalid backed-up scheduled task path');
      if not UnicodeSameText(ServiceName, 'WAPTService') then
        Require((Pos('PADIT_BackupTest_', ServiceName) = 1) and UnicodeSameText(FolderPath, '\' + ServiceName),
          'Scheduled task is outside the isolated fixture folder');
      Handle := OpenStorageFile(IncludeTrailingPathDelimiter(BackupRoot) +
        UTF8Decode(Entry.Strings['backup']), GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
      Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot open backed-up task');
      try
        Stream := THandleStream.Create(Handle);
        try
          Require((Stream.Size > 2) and (Stream.Size <= 1024*1024) and (Stream.Size mod 2 = 0) and
            (FileSHA256(Handle) = Entry.Strings['sha256']), 'Backed-up task data is invalid');
          Stream.Position := 0;
          SetLength(XML, Stream.Size div 2);
          Stream.ReadBuffer(XML[1], Length(XML)*2);
        finally
          Stream.Free;
        end;
      finally
        CloseHandle(Handle);
      end;
      Require(XML[1] = WideChar($FEFF), 'Backed-up task encoding is invalid');
      Delete(XML, 1, 1);
      Definition := Scheduler.NewTask(0);
      Definition.XmlText := WideString(XML);
      LogonType := Definition.Principal.LogonType;
      Require(LogonType in [3, 4, 5], 'A backed-up task uses an unsupported account logon mode');
      if LogonType = 4 then Account := Definition.Principal.GroupId
      else Account := Definition.Principal.UserId;
      Owned := False;
      for J := 1 to Integer(Definition.Actions.Count) do
      begin
        Action := Definition.Actions.Item[J];
        if Integer(Action.&Type) <> 0 then Continue;
        Command := UnicodeString(Action.Path);
        Owned := Owned or IsWaptExecutable(Command, InstallDir) or
          (UnicodeSameText(ServiceName, 'WAPTService') and UnicodeSameText(Path, '\waptservicerestart') and
           UnicodeSameText(ExtractFileName(Command), 'cmd.exe') and
           UnicodeSameText(UnicodeString(Action.Arguments), '/C net stop waptservice & net start waptservice'));
      end;
      Require(Owned, 'Backed-up task does not belong to WAPT');
      Sddl := UTF8Decode(Entry.Strings['sddl']);
      Require(Sddl <> '', 'Missing backed-up task security descriptor');
      Folder := Scheduler.GetFolder(WideString(FolderPath));
      // CREATE_OR_UPDATE, no registration triggers, no automatic principal ACE.
      Task := Folder.RegisterTaskDefinition(WideString(Name), Definition, 6 or 32 or 16,
        Account, Null, LogonType, WideString(Sddl));
      if not SameTaskSecurity(Sddl, UnicodeString(Task.GetSecurityDescriptor(7))) then
        Task.SetSecurityDescriptor(WideString(Sddl), 16);
      Require(TaskXMLWithoutDescriptor(UnicodeString(Task.Xml)) = TaskXMLWithoutDescriptor(XML),
        'Restored scheduled task XML differs from backup');
      Require(SameTaskSecurity(Sddl, UnicodeString(Task.GetSecurityDescriptor(7))),
        'Restored scheduled task ACL differs from backup');
    end;
  finally
    VarClear(Action);
    VarClear(Task);
    VarClear(Folder);
    VarClear(Definition);
    VarClear(Scheduler);
    CoUninitialize;
  end;
end;

procedure CaptureWaptWindowsMetadata(const Root, InstallDir, ServiceName: UnicodeString; Entries: TJSONArray);
var
  Token: THandle;
  Requested, Original: TTokenPrivileges;
  Returned: DWORD;

  procedure SaveKey(const Key, Relative: UnicodeString; View: DWORD; Optional: Boolean);
  var
    Registry: HKEY;
    Code: LongInt;
    Description: UTF8String;
    Security: TSecurityAttributes;
  begin
    Code := RegOpenKeyExW(HKEY_LOCAL_MACHINE, PWideChar(Key), 0, KEY_READ or View, Registry);
    if Optional and (Code = ERROR_FILE_NOT_FOUND) then Exit;
    Require(Code = ERROR_SUCCESS, 'Cannot read a WAPT registry key for backup');
    try
      Security.nLength := SizeOf(Security);
      Security.bInheritHandle := False;
      Security.lpSecurityDescriptor := SecurityDescriptor(False);
      try
        Require(RegSaveKeyW(Registry, PWideChar(Root + Relative), @Security) = ERROR_SUCCESS,
          'Cannot export a WAPT registry key');
      finally
        LocalFree(HLOCAL(Security.lpSecurityDescriptor));
      end;
    finally
      RegCloseKey(Registry);
    end;
    Description := 'HKLM\' + UTF8Encode(Key);
    if View = KEY_WOW64_32KEY then Description := Description + ' [32]'
    else if View = KEY_WOW64_64KEY then Description := Description + ' [64]';
    AddArtifact(Root, Relative, Description, 'registry-hive', Entries);
  end;

  procedure SaveWaptPath;
  var
    Registry: HKEY;
    Size, Kind: DWORD;
    Code: LongInt;
    Value, Part, Expanded: UnicodeString;
    Start, I, Index: Integer;
    Items: TJSONArray;
    Entry: TJSONObject;
    Buffer: array[0..32767] of WideChar;
  begin
    Require(RegOpenKeyExW(HKEY_LOCAL_MACHINE, EnvironmentKey, 0, KEY_QUERY_VALUE, Registry) =
      ERROR_SUCCESS, 'Cannot read system PATH for WAPT backup');
    try
      Code := RegQueryValueExW(Registry, 'Path', nil, @Kind, nil, @Size);
      if Code = ERROR_FILE_NOT_FOUND then Exit;
      Require((Code = ERROR_SUCCESS) and (Kind in [REG_SZ, REG_EXPAND_SZ]) and (Size >= 2) and
        (Size <= 65536) and (Size mod 2 = 0), 'Invalid system PATH registry value');
      SetLength(Value, Size div 2);
      Require(RegQueryValueExW(Registry, 'Path', nil, @Kind, @Value[1], @Size) = ERROR_SUCCESS,
        'Cannot read system PATH registry value');
      SetLength(Value, Size div 2 - 1);
    finally
      RegCloseKey(Registry);
    end;
    Items := TJSONArray.Create;
    try
      Start := 1;
      Index := 0;
      for I := 1 to Length(Value) + 1 do
        if (I > Length(Value)) or (Value[I] = ';') then
        begin
          Part := Copy(Value, Start, I - Start);
          Size := ExpandEnvironmentStringsW(PWideChar(Part), @Buffer[0], Length(Buffer));
          Require((Size > 0) and (Size <= Length(Buffer)), 'Cannot expand system PATH entry');
          Expanded := PWideChar(@Buffer[0]);
          if UnicodeSameText(ExcludeTrailingPathDelimiter(Expanded), InstallDir) then
          begin
            Entry := TJSONObject.Create;
            Items.Add(Entry);
            Entry.Add('index', Index);
            Entry.Add('value', UTF8Encode(Part));
          end;
          Inc(Index);
          Start := I + 1;
        end;
      // A later restore can merge this delta without replacing unrelated PATH entries.
      SaveArtifact(Root, 'registry\wapt-path.json', 'HKLM\' + UTF8Encode(EnvironmentKey) +
        '\Path', 'path-entries', Items.AsJSON, Entries);
    finally
      Items.Free;
    end;
  end;

begin
  Require(OpenProcessToken(GetCurrentProcess, TOKEN_ADJUST_PRIVILEGES or TOKEN_QUERY, @Token),
    'Cannot open backup privilege token');
  try
    FillChar(Requested, SizeOf(Requested), 0);
    Requested.PrivilegeCount := 1;
    Requested.Privileges[0].Attributes := SE_PRIVILEGE_ENABLED;
    Require(LookupPrivilegeValueW(nil, 'SeBackupPrivilege', @Requested.Privileges[0].Luid),
      'Cannot locate backup privilege');
    SetLastError(ERROR_SUCCESS);
    Require(AdjustTokenPrivileges(Token, False, @Requested, SizeOf(Original), @Original, @Returned) and
      (GetLastError = ERROR_SUCCESS), 'Backup privilege is not available');
    try
      if UnicodeSameText(ServiceName, 'WAPTService') then
      begin
        SaveKey(UninstallKey, 'registry\uninstall32.hiv', KEY_WOW64_32KEY, True);
        SaveKey(UninstallKey, 'registry\uninstall64.hiv', KEY_WOW64_64KEY, True);
        SaveKey(AppPathKey, 'registry\app-path32.hiv', KEY_WOW64_32KEY, True);
        SaveKey(AppPathKey, 'registry\app-path64.hiv', KEY_WOW64_64KEY, True);
        SaveKey(ServiceKey, 'services\waptservice.hiv', 0, False);
      end
      else
      begin
        SaveKey('SYSTEM\CurrentControlSet\Services\' + ServiceName, 'services\fixture.hiv', 0, False);
        SaveKey('SOFTWARE\' + ServiceName, 'registry\fixture.hiv', KEY_WOW64_64KEY, True);
      end;
    finally
      AdjustTokenPrivileges(Token, False, @Original, 0, nil, nil);
    end;
  finally
    CloseHandle(Token);
  end;
  if UnicodeSameText(ServiceName, 'WAPTService') then
  begin
    SaveWaptPath;
    CollectTasks(InstallDir, Root, '\', Entries);
  end
  else
    CollectTasks(InstallDir, Root, '\' + ServiceName, Entries);
end;

end.
