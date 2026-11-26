unit transitionbackupwindows;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, Windows, fpjson;

function BackupServiceState(const Name: UnicodeString): DWORD;
procedure StopBackupService(const Name: UnicodeString);
procedure RestoreBackupService(const Name: UnicodeString; InitialState: DWORD);
procedure RequireScheduledWaptIdle(const InstallDir: UnicodeString);
procedure DiscoverWaptShortcuts(const InstallDir: UnicodeString; Paths: TStrings);
procedure CaptureWaptWindowsMetadata(const Root, InstallDir, ServiceName: UnicodeString; Entries: TJSONArray);

implementation

uses ActiveX, ComObj, Variants, WinDirs, transitionstorage, transitionsecurity,
  transitionbackup;

const
  UninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WAPT_is1';
  AppPathKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\wapt-get.exe';
  ServiceKey = 'SYSTEM\CurrentControlSet\Services\WAPTService';
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

procedure Require(Value: Boolean; const Diagnostic: string);
begin
  if not Value then raise ETransitionBackup.Create(Diagnostic);
end;

function BackupServiceState(const Name: UnicodeString): DWORD;
var
  Manager, Service: SC_HANDLE;
  Status: TServiceStatus;
begin
  Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  Require(Manager <> 0, 'Cannot inspect the backup service through SCM');
  try
    Service := OpenServiceW(Manager, PWideChar(Name), SERVICE_QUERY_STATUS);
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
      Require(Integer(Task.Definition.Principal.LogonType) <> 1,
        'A WAPT task requires a password that cannot be exported');
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
        SaveKey('SYSTEM\CurrentControlSet\Services\' + ServiceName, 'services\fixture.hiv', 0, False);
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
