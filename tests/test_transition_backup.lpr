program test_transition_backup;

{$mode objfpc}{$H+}

uses Classes, SysUtils, Windows, WinDirs, ActiveX, ComObj, Variants, fpjson, jsonparser, transitionstate,
  transitionbackup, transitionbackupwindows, transitionstorage, transitionrestore, transitionprecheck, transitionsecurity, transitioninstall, transitionhandoff;

var
  ServiceHandle: SERVICE_STATUS_HANDLE;
  ServiceDone: THandle;

procedure Check(Condition: Boolean; const Reason: string);
begin
  if not Condition then raise Exception.Create(Reason);
end;

procedure SetFixtureStatus(State, Accepted: DWORD);
var
  Status: TServiceStatus;
begin
  FillChar(Status, SizeOf(Status), 0);
  Status.dwServiceType := SERVICE_WIN32_OWN_PROCESS;
  Status.dwCurrentState := State;
  Status.dwControlsAccepted := Accepted;
  SetServiceStatus(ServiceHandle, @Status);
end;

function FixtureControl(Code: DWORD): BOOL; stdcall;
begin
  Result := True;
  if Code = SERVICE_CONTROL_STOP then
  begin
    SetFixtureStatus(SERVICE_STOP_PENDING, 0);
    SetEvent(ServiceDone);
  end;
end;

function ReadText(const Path: UnicodeString): UTF8String; forward;
procedure WriteText(const Path: UnicodeString; const Text: UTF8String); forward;

procedure FixtureServiceMain(Count: DWORD; Args: LPPWSTR); stdcall;
var
  Name, StopMarker: UnicodeString;
  State: TJSONObject;
begin
  Name := UnicodeString(ParamStr(2));
  StopMarker := UnicodeString(ParamStr(3));
  ServiceHandle := RegisterServiceCtrlHandlerW(PWideChar(Name), @FixtureControl);
  if ServiceHandle = 0 then Exit;
  if (StopMarker <> '') and FileExists(StopMarker) then
  begin
    SetFixtureStatus(SERVICE_STOPPED, 0);
    Exit;
  end;
  ServiceDone := CreateEventW(nil, True, False, nil);
  if ServiceDone = 0 then Exit;
  try
    SetFixtureStatus(SERVICE_RUNNING, SERVICE_ACCEPT_STOP);
    WaitForSingleObject(ServiceDone, INFINITE);
    if ParamStr(4) <> '' then
    begin
      State := TJSONObject(GetJSON(ReadText(UnicodeString(ParamStr(4)))));
      try
        Check(State.Strings['state'] = 'BACKUP_IN_PROGRESS', 'State not persisted before stop');
        Check(State.Objects['backup'].Integers['service_initial_state'] = SERVICE_RUNNING,
          'Initial service state not persisted before stop');
        WriteText(UnicodeString(ParamStr(4)) + '.observed', 'verified before stop');
      finally
        State.Free;
      end;
    end;
    if StopMarker <> '' then WriteText(StopMarker, 'reject restart');
    SetFixtureStatus(SERVICE_STOPPED, 0);
  finally
    CloseHandle(ServiceDone);
  end;
end;

procedure RunFixtureService;
var
  Table: array[0..1] of TServiceTableEntryW;
  Name: UnicodeString;
begin
  Name := UnicodeString(ParamStr(2));
  Check(Pos('PADIT_BackupTest_', Name) = 1, 'Invalid fixture service name');
  FillChar(Table, SizeOf(Table), 0);
  Table[0].lpServiceName := PWideChar(Name);
  Table[0].lpServiceProc := @FixtureServiceMain;
  Check(StartServiceCtrlDispatcherW(@Table[0]), 'Cannot dispatch fixture service');
end;

function ReadText(const Path: UnicodeString): UTF8String;
var
  Handle: THandle;
  Stream: THandleStream;
begin
  Result := '';
  Handle := FileOpen(Path, fmOpenRead or fmShareDenyWrite);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Stream := THandleStream.Create(Handle);
    try
      SetLength(Result, Stream.Size);
      if Result <> '' then Stream.ReadBuffer(Result[1], Length(Result));
    finally
      Stream.Free;
    end;
  finally
    FileClose(Handle);
  end;
end;

procedure WriteText(const Path: UnicodeString; const Text: UTF8String);
var
  Handle: THandle;
begin
  Handle := FileCreate(Path);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if Text <> '' then
      Check(FileWrite(Handle, Text[1], Length(Text)) = Length(Text), 'Cannot write fixture data');
  finally
    FileClose(Handle);
  end;
end;

procedure SeedPrepared(Store: TTransitionStore; const Root: UnicodeString);
var
  State: TJSONObject;
  Path: UnicodeString;
begin
  Check(Store.Initialize, 'Cannot initialize fixture state');
  Path := Store.RootDirectory + 'state.json';
  State := TJSONObject(GetJSON(ReadText(Path)));
  try
    State.Strings['state'] := 'PREPARED';
    State.Strings['previous_state'] := 'PRECHECK';
    State.Objects['host'].Strings['uuid'] := 'fixture-id';
    State.Objects['target'].Strings['url'] := 'https://fixture.example';
    State.Objects['target'].Strings['agent_version'] := '1.8.3.7766';
    with State.Objects['source'] do
    begin
      Strings['install_dir'] := UTF8Encode(Root + '\agent');
      if FileExists(Root + '\settings\custom.ini') then
        Strings['config_path'] := UTF8Encode(Root + '\settings\custom.ini')
      else Strings['config_path'] := UTF8Encode(Root + '\agent\wapt-get.ini');
      Strings['db_path'] := UTF8Encode(Root + '\custom-' + UnicodeString(#$6F22) + '\waptdb.sqlite');
      Strings['key_path'] := UTF8Encode(Root + '\agent\private\machine.pem');
      Strings['certificate_path'] := UTF8Encode(Root + '\agent\private\machine.crt');
    end;
    WriteText(Path, State.FormatJSON);
  finally
    State.Free;
  end;
end;

procedure TestSuccess(const Root, Service: UnicodeString);
var
  Store: TTransitionStore;
  Manifest: TJSONObject;
  Entries: TJSONArray;
  Entry: TJSONObject;
  Destination, Path, ManifestPath: UnicodeString;
  ValidManifest: UTF8String;
  I: Integer;
  DataFound, CacheFound, KeptNonCache, ServiceFound, TaskFound: Boolean;
begin
  Store := TTransitionStore.Create(Root + '\transition');
  try
    SeedPrepared(Store, Root);
    try
      Store.Advance(tsBackupVerified);
      raise Exception.Create('Direct BACKUP_VERIFIED was accepted');
    except
      on E: ETransitionState do Check(Pos('protected backup workflow', E.Message) > 0, E.Message);
    end;
    Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Service fixture was not running');
    Check(Store.RunBackup(Service), 'Backup journal failed');
    Check(BackupServiceState(Service) = SERVICE_STOPPED, 'Backup did not stop the service fixture');
    Check(Store.ReadState = tsBackupVerified, 'Backup did not reach verified state');
    ManifestPath := Store.RootDirectory + 'backup\manifest.json';
    ValidManifest := ReadText(ManifestPath);
    Manifest := TJSONObject(GetJSON(ValidManifest));
    try
      Check(Manifest.Integers['service_initial_state'] = SERVICE_RUNNING, 'Initial service state missing');
      Entries := Manifest.Arrays['entries'];
      DataFound := False;
      CacheFound := False;
      KeptNonCache := False;
      ServiceFound := False;
      TaskFound := False;
      Destination := '';
      for I := 0 to Entries.Count - 1 do
      begin
        Entry := Entries.Objects[I];
        Path := UTF8Decode(Entry.Strings['source']);
        if Pos('\custom-' + UnicodeString(#$6F22), Path) > 0 then DataFound := True;
        if Pos('\settings\cache\', Path) > 0 then CacheFound := True;
        if Pos('\agent\cache\keep.txt', Path) > 0 then KeptNonCache := True;
        if Entry.Get('artifact', '') = 'registry-hive' then ServiceFound := True;
        if Entry.Get('artifact', '') = 'task' then TaskFound := Entry.Get('sddl', '') <> '';
        if UnicodeSameText(ExtractFileName(Path), 'runtime.bin') then
        begin
          Check(Entry.Strings['sddl'] <> '', 'Source ACL missing');
          Check(Entry.QWords['written'] > 0, 'Source time missing');
          Check((Entry.Integers['attributes'] and FILE_ATTRIBUTE_HIDDEN) <> 0, 'Source attributes missing');
          Destination := Store.RootDirectory + 'backup\' + UTF8Decode(Entry.Strings['backup']);
        end;
      end;
      Check(DataFound and not CacheFound and KeptNonCache and ServiceFound and TaskFound and (Destination <> ''),
        'Protected backup inventory is incomplete');
      Check(ReadText(Destination) = 'runtime fixture', 'Backup contents are incorrect');
      CheckStorageFile(Destination);
      // Alter an existing protected fixture file without replacing its ACL.
      WriteText(Destination, 'RUNTIME FIXTURE');
      try
        Store.Advance(tsInstalling);
        raise Exception.Create('Installed from an altered backup');
      except
        on E: ETransitionBackup do Check(Pos('SHA256', E.Message) > 0, E.Message);
      end;
      Check(Store.ReadState = tsBackupVerified, 'Altered backup changed state');
      WriteText(Destination, 'runtime fixture');
      Manifest.Strings['transition_id'] := 'wrong-transition';
      WriteText(ManifestPath, Manifest.FormatJSON);
      try
        Store.Advance(tsInstalling);
        raise Exception.Create('Incoherent manifest permitted installing');
      except
        on E: ETransitionBackup do Check(Pos('does not match', E.Message) > 0, E.Message);
      end;
      WriteText(ManifestPath, ValidManifest);
      Check(Store.Advance(tsInstalling), 'Verified backup did not allow installation state');
    finally
      Manifest.Free;
    end;
  finally
    Store.Free;
  end;
end;

procedure ExpectBackupFailure(const Root, Service, Kind, Expected: UnicodeString;
  StateAfter: TTransitionState);
var
  Store: TTransitionStore;
  Handle: THandle;
  Path: UnicodeString;
begin
  Store := TTransitionStore.Create(Root + '\transition');
  Handle := INVALID_HANDLE_VALUE;
  try
    SeedPrepared(Store, Root);
    if Kind = 'preexisting' then
    begin
      Handle := OpenStorageFile(Store.RootDirectory + 'backup\keep', GENERIC_WRITE, 0, CREATE_NEW);
      Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot seed existing backup fixture');
      CloseHandle(Handle);
      Handle := INVALID_HANDLE_VALUE;
    end
    else if (Kind = 'busy') or (Kind = 'inaccessible') or (Kind = 'restore-fails') then
    begin
      if Kind = 'busy' then Path := Root + '\custom-' + UnicodeString(#$6F22) + '\waptdb.sqlite'
      else Path := Root + '\agent\zzz-inaccessible.bin';
      Handle := CreateFileW(PWideChar(Path), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
        nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
      Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot open fixture writer');
    end;
    try
      Store.RunBackup(Service);
      raise Exception.Create('Unsafe backup passed');
    except
      on E: ETransitionBackup do Check(Pos(Expected, UnicodeString(E.Message)) > 0, E.Message);
    end;
    Check(Store.ReadState = StateAfter, 'Unexpected state after backup failure');
    Check(not FileExists(Store.RootDirectory + 'backup\manifest.json'), 'Incomplete backup was finalized');
    if Kind = 'preexisting' then
      Check(FileExists(Store.RootDirectory + 'backup\keep'), 'Existing backup was overwritten');
    if (Kind = 'inaccessible') or (Kind = 'restore-fails') then
    begin
      Check(DirectoryExists(Store.RootDirectory + 'backup\agent\1'), 'Partial backup not identifiable');
      Check(FileExists(Store.RootDirectory + 'state.json.observed'), 'Stop did not observe durable service state');
      if StateAfter = tsAborted then
        Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Initial running state was not restored')
      else
        Check(BackupServiceState(Service) = SERVICE_STOPPED, 'Fixture unexpectedly restarted');
      Path := UTF8Decode(ReadText(Store.RootDirectory + 'state.json'));
      Check(Pos('last_error', Path) > 0, 'Backup diagnostic missing');
      Check((Pos('service restoration failed', Path) > 0) = (StateAfter = tsRecoveryRequired),
        'Restoration diagnostic does not match state');
    end;
  finally
    if Handle <> INVALID_HANDLE_VALUE then CloseHandle(Handle);
    Store.Free;
  end;
end;

procedure TestRestore(const Root, Service: UnicodeString; FailVerification: Boolean = False);
var
  Store: TTransitionStore;
  State, Manifest: TJSONObject;
  Scope, Added: TBackupPaths;
  BackupRoot, RuntimePath, ExtraPath, ForeignPath, CachePath, SQLitePath, AddedCA: UnicodeString;
  TransitionID, Digest: string;
  ManifestText, OriginalSQLite: UTF8String;
  Handle: THandle;
  Manager, Fixture: SC_HANDLE;
  Tasks, Folder: OleVariant;
  Values: TJSONArray;
  Item: TJSONObject;
  Registry: HKEY;
  RegistryKey, RegistryText: UnicodeString;
begin
  Store := TTransitionStore.Create(Root + '\transition');
  try
    Check(SetFileAttributesW(PWideChar(Root + '\agent\runtime.bin'),
      FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_READONLY), 'Cannot mark historical runtime read-only');
    SeedPrepared(Store, Root);
    Check(Store.RunBackup(Service), 'Fixture backup failed');
    Check(Store.Advance(tsInstalling), 'Cannot stage fixture rollback');
    State := TJSONObject(GetJSON(ReadText(Store.RootDirectory + 'state.json')));
    try
      TransitionID := State.Strings['transition_id'];
      Digest := State.Objects['backup'].Strings['sha256'];
    finally
      State.Free;
    end;
    BackupRoot := Store.RootDirectory + 'backup\';
    ManifestText := ReadText(BackupRoot + 'manifest.json');
    if FailVerification then
    begin
      Handle := OpenStorageFile(BackupRoot + 'unexpected.tmp', GENERIC_WRITE, 0, CREATE_NEW);
      Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot add simulated corrupt backup member');
      CloseHandle(Handle);
      try
        Store.RunRollback(nil, nil, Service);
        raise Exception.Create('Corrupt backup was accepted');
      except
        on E: ETransitionBackup do Check(Pos('Unlisted object', E.Message) > 0, E.Message);
      end;
      Check(Store.ReadState = tsRecoveryRequired, 'Corrupt backup did not require recovery');
      Check(BackupServiceState(Service) = SERVICE_STOPPED, 'Verification error changed the fixture service');
      Exit;
    end;
    try
      LoadVerifiedBackup(BackupRoot, TransitionID, StringOfChar('0', 64)).Free;
      raise Exception.Create('Backup with wrong committed digest accepted');
    except
      on E: ETransitionBackup do Check(Pos('no longer matches state', E.Message) > 0, E.Message);
    end;
    Manifest := LoadVerifiedBackup(BackupRoot, TransitionID, Digest);
    try
      RuntimePath := Root + '\agent\runtime.bin';
      ExtraPath := Root + '\agent\fixture-added.exe';
      ForeignPath := Root + '\agent\foreign.txt';
      CachePath := Root + '\agent\cache\download.wapt';
      SQLitePath := Root + '\custom-' + UnicodeString(#$6F22) + '\waptdb.sqlite';
      OriginalSQLite := ReadText(SQLitePath);
      AddedCA := IncludeTrailingPathDelimiter(ExtractFileDir(SQLitePath)) + 'padit-transition-packages.pem';
      WriteText(AddedCA, 'new fixture CA');
      Check(SetFileAttributesW(PWideChar(RuntimePath), FILE_ATTRIBUTE_NORMAL),
        'Cannot change fixture runtime attributes');
      WriteText(RuntimePath, 'changed');
      Check(SetFileAttributesW(PWideChar(RuntimePath), FILE_ATTRIBUTE_READONLY),
        'Cannot mark modified destination read-only');
      WriteText(ExtraPath, 'installation addition');
      WriteText(ForeignPath, 'foreign data');
      WriteText(SQLitePath, 'changed database');
      Scope := nil;
      Added := nil;
      AddBackupSource(Scope, Root + '\agent');
      AddBackupSource(Scope, ExtractFileDir(SQLitePath));
      AddBackupSource(Added, ForeignPath);
      try
        CheckRestorePaths(Manifest, Scope, Store.RootDirectory, Root + '\agent', Root + '\agent', Added);
        raise Exception.Create('Overlapping cache accepted');
      except
        on E: ETransitionBackup do Check(Pos('outside the approved scope', E.Message) > 0, E.Message);
      end;
      Added[0] := ExtraPath;
      AddBackupSource(Added, AddedCA);
      CheckRestorePaths(Manifest, Scope, Store.RootDirectory, Root + '\agent', Root + '\agent\cache', Added);
      Handle := CreateFileW(PWideChar(SQLitePath), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
        nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
      Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot lock SQLite fixture');
      try
        try
          RestoreVerifiedFiles(BackupRoot, Root + '\agent', Root + '\agent\cache',
            TransitionID, Digest, Scope, Added);
          raise Exception.Create('Locked destination accepted');
        except
          on E: ETransitionBackup do Check(Pos('destination', E.Message) > 0, E.Message);
        end;
      finally
        CloseHandle(Handle);
      end;
      CheckRestorePaths(Manifest, Scope, Store.RootDirectory, Root + '\agent', Root + '\agent\cache', Added);
      RestoreVerifiedFiles(BackupRoot, Root + '\agent', Root + '\agent\cache',
            TransitionID, Digest, Scope, Added);
      RestoreVerifiedFiles(BackupRoot, Root + '\agent', Root + '\agent\cache',
            TransitionID, Digest, Scope, Added);
      Manager := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
      Check(Manager <> 0, 'Cannot open fixture SCM');
      try
        Fixture := OpenServiceW(Manager, PWideChar(Service), SERVICE_CHANGE_CONFIG);
        Check(Fixture <> 0, 'Cannot open fixture service');
        try
          Check(ChangeServiceConfigW(Fixture, High(DWORD), SERVICE_DISABLED, High(DWORD),
            nil, nil, nil, nil, nil, nil, nil), 'Cannot modify fixture service');
        finally
          CloseServiceHandle(Fixture);
        end;
      finally
        CloseServiceHandle(Manager);
      end;
      Check(Succeeded(CoInitialize(nil)), 'Cannot connect to fixture task folder');
      try
        Tasks := CreateOleObject('Schedule.Service');
        Tasks.Connect;
        Folder := Tasks.GetFolder(WideString('\' + Service));
        Folder.DeleteTask('fixture', 0);
      finally
        VarClear(Folder);
        VarClear(Tasks);
        CoUninitialize;
      end;
      RegistryKey := 'SOFTWARE\' + Service;
      Check(RegOpenKeyExW(HKEY_LOCAL_MACHINE, PWideChar(RegistryKey), 0,
        KEY_SET_VALUE or KEY_WOW64_64KEY, Registry) = ERROR_SUCCESS, 'Cannot open synthetic registry key');
      try
        RegistryText := 'changed';
        Check(RegSetValueExW(Registry, 'Sample', 0, REG_SZ, PByte(PWideChar(RegistryText)),
          (Length(RegistryText)+1)*2) = ERROR_SUCCESS, 'Cannot modify synthetic registry key');
      finally
        RegCloseKey(Registry);
      end;
      Check(Store.Advance(tsRollingBack), 'Cannot simulate interrupted rollback');
      FreeAndNil(Store);
      Store := TTransitionStore.Create(Root + '\transition');
      Check(Store.RunRollback(Scope, Added, Service), 'Fixture rollback journal failed');
      Check(Store.ReadState = tsRolledBack, 'Rollback did not commit ROLLED_BACK');
      Check(RegistryValue(RegistryKey, 'Sample', KEY_WOW64_64KEY, RegistryText) and
        (RegistryText = 'original'), 'Historical synthetic registry value not restored');
      Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Fixture initial service state not restored');
      Values := TJSONArray.Create;
      try
        Item := TJSONObject.Create;
        Values.Add(Item);
        Item.Add('index', 1);
        Item.Add('value', UTF8Encode(Root + '\agent'));
        Check(MergeWaptPath(Root + '\agent;C:\foreign;D:\new', Root + '\agent', Values) =
          'C:\foreign;' + Root + '\agent;D:\new', 'PATH merge changed non-WAPT entries');
      finally
        Values.Free;
      end;
      Check(ReadText(RuntimePath) = 'runtime fixture', 'Historical file not restored');
      Check((GetFileAttributesW(PWideChar(RuntimePath)) and (FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_READONLY)) =
        (FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_READONLY), 'Historical file attributes not restored');
      Check(ReadText(SQLitePath) = OriginalSQLite, 'Custom Unicode SQLite file changed');
      Check(not FileExists(ExtraPath), 'Installation addition not removed');
      Check(not FileExists(AddedCA), 'Transition-only CA in custom directory not removed');
      Check(ReadText(ForeignPath) = 'foreign data', 'Foreign file changed');
      Check(ReadText(CachePath) = 'isolated fixture', 'Package cache changed');
      Check((ReadText(BackupRoot + 'manifest.json') = ManifestText) and
        (VerifyBackup(BackupRoot, TransitionID) = Digest), 'Original backup changed');
    finally
      Manifest.Free;
    end;
  finally
    Store.Free;
  end;
end;

procedure TestSetupArguments;
const
  UncertainCodes: array[0..3] of DWORD = (8, 9, 1641, TransitionRestartCode);
var
  Arg: UnicodeString;
  Code: DWORD;
begin
  Arg := TransitionSetupArguments('C:\Program Files\Agent', 'D:\Settings\custom.ini', 'D:\Trust',
    'D:\Stage\server.pem', 'D:\Stage\packages.pem', 'https://target.example', 'https://repo.example/wapt');
  Check(Pos('/TRANSITION=1', Arg) > 0, 'Missing transition switch');
  Check(Pos('/NORESTART /NOCLOSEAPPLICATIONS /RESTARTEXITCODE=3010', Arg) > 0,
    'Missing no-restart/no-close switches');
  Check(Pos('/DIR="C:\Program Files\Agent" /TRANSITION_INI="D:\Settings\custom.ini"', Arg) > 0,
    'Historical paths not preserved as distinct quoted arguments');
  Check(Pos('/verify_cert="D:\Stage\server.pem"', Arg) > 0, 'TLS trust argument missing');
  try
    TransitionSetupArguments('C:\Agent', 'C:\custom.ini', 'C:\Trust', '0', 'C:\packages.pem',
      'https://target.example', 'https://repo.example');
    raise Exception.Create('TLS validation could be disabled');
  except
    on E: ETransitionInstall do Check(Pos('local path', E.Message) > 0, E.Message);
  end;
  try
    TransitionSetupArguments('C:\Agent', 'C:\custom.ini', 'C:\Trust', 'C:\server.pem', 'C:\packages.pem',
      'https://target.example', 'http://repo.example');
    raise Exception.Create('HTTP repository accepted');
  except
    on E: ETransitionInstall do Check(Pos('HTTPS URL', E.Message) > 0, E.Message);
  end;
  CheckSetupExit(0);
  for Code := 1 to 7 do
    try
      CheckSetupExit(Code);
      raise Exception.Create('Unsuccessful setup exit accepted');
    except
      on E: EInstallUncertain do raise;
      on E: ETransitionInstall do Check(Pos(IntToStr(Code), E.Message) > 0, E.Message);
    end;
  for Code in UncertainCodes do
    try
      CheckSetupExit(Code);
      raise Exception.Create('Uncertain setup exit accepted');
    except
      on E: EInstallUncertain do Check(Pos(IntToStr(Code), E.Message) > 0, E.Message);
    end;
end;

procedure FixtureInstaller;
var
  Home, IdentityPath, Image, Command: UnicodeString;
  Handle: THandle;
  Startup: TStartupInfoW;
  Child: TProcessInformation;
begin
  Home := UnicodeString(ParamStr(3));
  Check(FileExists(Home + '\private\machine.pem'), 'Fixture identity missing');
  if ParamStr(2) = 'timeout' then
  begin
    Image := UnicodeString(ParamStr(0));
    Command := '"' + Image + '" fixture-delay';
    UniqueString(Command);
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Check(CreateProcessW(PWideChar(Image), PWideChar(Command), nil, nil, False, CREATE_NO_WINDOW,
      nil, nil, Startup, Child), 'Cannot start fictitious installer descendant');
    CloseHandle(Child.hThread);
    CloseHandle(Child.hProcess);
    Exit;
  end;
  IdentityPath := Home + '\private\machine.pem';
  Handle := CreateFileW(PWideChar(IdentityPath), GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(Handle);
    ExitCode := 31;
    Exit;
  end;
  if ParamStr(2) = 'exit' then
  begin
    WriteText(Home + '\padit-fixture.txt', 'partial installer output');
    ExitCode := 7;
  end
  else if ParamStr(2) = 'nominal' then
    WriteText(Home + '\padit-fixture.txt', 'PADIT fixture verified');
end;

procedure AlterL2Backup(const BackupRoot: UnicodeString);
var
  Handle: THandle;
begin
  Handle := OpenStorageFile(BackupRoot + '\unexpected.tmp', GENERIC_WRITE, 0, CREATE_NEW);
  Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot alter L2 fixture backup');
  CloseHandle(Handle);
end;

function FixtureFileSDDL(const Path: UnicodeString): UTF8String;
var
  Handle: THandle;
begin
  Handle := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, 0, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Result := SDDL(Handle);
  finally
    CloseHandle(Handle);
  end;
end;

procedure CheckL2LaunchACL(const BackupRoot, CertPath: UnicodeString; const Before: UTF8String);
var
  Manifest, Entry: TJSONObject;
  Entries: TJSONArray;
  I: Integer;
  Actual: UTF8String;
begin
  Actual := FixtureFileSDDL(CertPath);
  Manifest := TJSONObject(GetJSON(ReadText(BackupRoot + '\manifest.json')));
  try
    Entries := Manifest.Arrays['entries'];
    for I := 0 to Entries.Count - 1 do
    begin
      Entry := Entries.Objects[I];
      if not UnicodeSameText(UTF8Decode(Entry.Strings['source']), CertPath) then Continue;
      Check(Entry.Strings['sddl'] = Before, 'L2 certificate backup SDDL differs from original');
      Check(Actual = Before, 'L2 certificate rollback changed NTFS inheritance: ' +
        'original=' + Before + ' actual=' + Actual);
      WriteLn('PASS inherited machine.crt SDDL preserved exactly');
      Exit;
    end;
    raise Exception.Create('L2 certificate missing from backup manifest');
  finally
    Manifest.Free;
  end;
end;

procedure TestCutover(const Root, Service, CaseName: UnicodeString; Integrated: Boolean = False);
var
  Store: TTransitionStore;
  FileHandle: THandle;
  FixtureImage, Path: UnicodeString;
  Payload, OriginalKey: UTF8String;
  Hash, Before: string;
  Scenario: UnicodeString;
  Expected: TTransitionState;
  Scope, Added: TBackupPaths;
  Timeout: DWORD;
  Metadata: TLocalMetadata;
  Hook: TFixtureBackupCheckpoint;
  ServiceName: string;
  DBWriter: THandle;
  Journal, OriginalCertSDDL: UTF8String;
  Stage, P: Integer;
const
  OrderedStates: array[0..4] of string = ('PRECHECK -> PREPARED', 'PREPARED -> BACKUP_IN_PROGRESS',
    'BACKUP_IN_PROGRESS -> BACKUP_VERIFIED', 'BACKUP_VERIFIED -> INSTALLING', 'INSTALLING -> VERIFYING');
begin
  DBWriter := INVALID_HANDLE_VALUE;
  Store := TTransitionStore.Create(Root + '\transition');
  try
    DBWriter := INVALID_HANDLE_VALUE;
    Hook := nil;
    ServiceName := UTF8Encode(Service);
    if Integrated then
    begin
      Check(Store.Initialize, 'Cannot initialize the L2 fixture');
      Metadata := Default(TLocalMetadata);
      Metadata.UUID := 'fixture-id';
      Metadata.Hostname := 'fixture.example';
      Metadata.IdentificationMode := 'configured';
      Metadata.SourceURL := 'https://historical.example';
      Metadata.SourceVersion := '1.8.2.7393';
      Metadata.ServiceState := 'running';
      Metadata.TargetURL := 'https://fixture.example';
      Metadata.TargetVersion := '1.8.3.7766';
      Metadata.InstallDir := UTF8Encode(Root + '\agent');
      Metadata.ConfigPath := Metadata.InstallDir + '\wapt-get.ini';
      Metadata.KeyPath := Metadata.InstallDir + '\private\machine.pem';
      Metadata.CertificatePath := Metadata.InstallDir + '\private\machine.crt';
      Metadata.DatabasePath := UTF8Encode(Root + '\custom-' + UnicodeString(#$6F22) + '\waptdb.sqlite');
    end
    else
    begin
      SeedPrepared(Store, Root);
      if CaseName <> 'cutover-ok' then
        Check(Store.RunBackup(Service), 'Fixture backup did not complete');
    end;
    Scenario := 'nominal';
    Expected := tsVerifying;
    Before := '';
    Timeout := 10000;
    if Integrated and (CaseName = 'cutover-precheck') then
    begin
      Expected := tsPrecheckFailed;
      Before := 'precheck rejected';
    end
    else if Integrated and (CaseName = 'cutover-control') then
    begin
      Expected := tsPrepared;
      ServiceName := ServiceName + '_missing';
      Before := 'service';
    end
    else if Integrated and (CaseName = 'cutover-save') then
    begin
      Expected := tsAborted;
      Before := 'still open for writing';
      DBWriter := CreateFileW(PWideChar(UTF8Decode(Metadata.DatabasePath)), GENERIC_WRITE,
        FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
      Check(DBWriter <> INVALID_HANDLE_VALUE, 'Cannot create L2 SQLite writer');
    end
    else if CaseName = 'cutover-exit' then
    begin
      Scenario := 'exit';
      Expected := tsRolledBack;
      Before := 'exit code 7';
    end
    else if CaseName = 'cutover-verify' then
    begin
      Scenario := 'invalid';
      Expected := tsRolledBack;
    end
    else if CaseName = 'cutover-timeout' then
    begin
      Scenario := 'timeout';
      Timeout := 100;
      Expected := tsInstalling;
      Before := 'deadline exceeded';
    end
    else if CaseName = 'cutover-launch' then
    begin
      Expected := tsRolledBack;
      Before := 'Cannot create installer process';
    end
    else if CaseName = 'cutover-tamper' then
    begin
      Expected := tsAborted;
      Before := 'final SHA256';
    end
    else if CaseName = 'cutover-backup' then
    begin
      Expected := tsAborted;
      Before := 'Unlisted object';
      if Integrated then Hook := @AlterL2Backup
      else AlterL2Backup(Store.RootDirectory + 'backup');
    end;
    Scope := nil;
    Added := nil;
    AddBackupSource(Scope, Root + '\agent');
    AddBackupSource(Scope, Root + '\custom-' + UnicodeString(#$6F22));
    AddBackupSource(Added, Root + '\agent\padit-fixture.txt');
    OriginalKey := ReadText(Root + '\agent\private\machine.pem');
    if Integrated and (CaseName = 'cutover-launch') then
    begin
      OriginalCertSDDL := FixtureFileSDDL(Root + '\agent\private\machine.crt');
      Check((Pos('D:AI(', OriginalCertSDDL) > 0) and (Pos(';ID;', OriginalCertSDDL) > 0),
        'L2 launch fixture requires an automatically inherited certificate DACL');
    end;
    FixtureImage := Store.RootDirectory + 'staging\fixture-installer.exe';
    if CaseName = 'cutover-launch' then Payload := 'invalid executable'
    else Payload := ReadText(UnicodeString(ParamStr(0)));
    FileHandle := OpenStorageFile(FixtureImage, GENERIC_READ or GENERIC_WRITE, 0, CREATE_NEW);
    Check(FileHandle <> INVALID_HANDLE_VALUE, 'Cannot create staged fixture installer');
    try
      Check(FileWrite(FileHandle, Payload[1], Length(Payload)) = Length(Payload), 'Cannot stage fixture installer');
      Hash := FileSHA256(FileHandle);
      if CaseName = 'cutover-tamper' then
      begin
        Check(SetFilePointer(FileHandle, 0, nil, FILE_BEGIN) = 0, 'Cannot rewind fixture installer');
        Check(FileWrite(FileHandle, 'XX'[1], 2) = 2, 'Cannot alter fixture installer');
      end;
    finally
      CloseHandle(FileHandle);
    end;
    if Integrated then
    begin
      try
        Check(Store.RunFixtureOrchestrator(ServiceName, UTF8Encode(Scenario), Hash, Timeout, Metadata,
          Scope, Added, CaseName = 'cutover-precheck', Hook), 'L2 fixture journal failed');
        Check(Before = '', 'Unexpected L2 success');
      except
        on E: Exception do
          Check((Before <> '') and (Pos(Before, E.Message) > 0), E.Message);
      end;
      Check(Store.ReadState = Expected, 'Unexpected L2 fixture state');
      if CaseName = 'cutover-launch' then
        CheckL2LaunchACL(Store.RootDirectory + 'backup', Root + '\agent\private\machine.crt', OriginalCertSDDL);
      Journal := ReadText(Store.RootDirectory + 'logs\transition.log');
      if Expected = tsVerifying then
      begin
        for Stage := Low(OrderedStates) to High(OrderedStates) do
        begin
          P := Pos(OrderedStates[Stage], Journal);
          Check(P > 0, 'Missing or out-of-order L2 state: ' + OrderedStates[Stage]);
          Delete(Journal, 1, P + Length(OrderedStates[Stage]) - 1);
        end;
        Check(FileExists(Root + '\agent\padit-fixture.txt'), 'Installer result missing');
        try
          Store.Advance(tsCompleted);
          raise Exception.Create('L2 accepted completion without server confirmation');
        except
          on E: ETransitionState do Check(Pos('confirmation', E.Message) > 0, E.Message);
        end;
      end;
      if Expected = tsInstalling then
      begin
        Check(FileExists(Store.RootDirectory + 'staging\installer.pending'), 'Installer marker lost');
        try
          Store.RunFixtureCutover(Service, Scenario, Hash, Timeout, Scope, Added);
          raise Exception.Create('L2 retried uncertain installer');
        except
          on E: ETransitionState do Check(Pos('uncertain', E.Message) > 0, E.Message);
        end;
        Sleep(1500);
      end;
      Exit;
    end;
    if Expected = tsVerifying then Check(Store.RunFixtureCutover(Service, Scenario, Hash, Timeout, Scope, Added),
      'Fixture cutover journal failed')
    else
      try
        Store.RunFixtureCutover(Service, Scenario, Hash, Timeout, Scope, Added);
        raise Exception.Create('Failed installer was accepted');
      except
        on E: Exception do
          Check((E.Message <> 'Failed installer was accepted') and
            ((Before = '') or (Pos(Before, E.Message) > 0)), E.Message);
      end;
    Check(Store.ReadState = Expected, 'Unexpected fixture cutover state');
    Check(ReadText(Root + '\agent\private\machine.pem') = OriginalKey, 'Historical fixture identity changed');
    Path := Root + '\agent\padit-fixture.txt';
    if Expected = tsVerifying then
    begin
      Check(FileExists(Path), 'Successful installer output missing');
      try
        Store.Advance(tsCompleted);
        raise Exception.Create('Premature completion accepted');
      except
        on E: ETransitionState do Check(Pos('confirmation', E.Message) > 0, E.Message);
      end;
      try
        Store.ConfirmFixture(Service, 'https://fixture.example', 'fixture-id', '1.8.3.7766',
          StringOfChar('a', 64), StringOfChar('b', 64));
        raise Exception.Create('Stale fixture acknowledgement accepted');
      except
        on E: ETransitionState do Check(Pos('fresh inventory', E.Message) > 0, E.Message);
      end;
      Check(Store.ReadState = tsVerifying, 'Rejected acknowledgement changed state');
      if CaseName = 'cutover-confirmfail' then
      begin
        Check(Store.RunRollback(Scope, Added, Service), 'Rollback after confirmation failure failed');
        Check(Store.ReadState = tsRolledBack, 'Confirmation failure did not roll back');
        Check(not FileExists(Path), 'Confirmation rollback did not remove fixture output');
        Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Confirmation rollback did not restore the service');
        Exit;
      end;
      try
        Store.ConfirmFixture(Service + '_missing', 'https://fixture.example', 'fixture-id', '1.8.3.7766',
          StringOfChar('a', 64), StringOfChar('a', 64));
        raise Exception.Create('Confirmation succeeded without a functioning service');
      except
        on E: ETransitionBackup do Check(Pos('service', E.Message) > 0, E.Message);
      end;
      Check(Store.ReadState = tsVerifying, 'Failed service start changed confirmation state');
      Check(Store.ConfirmFixture(Service, 'https://fixture.example', 'fixture-id', '1.8.3.7766',
        StringOfChar('a', 64), StringOfChar('a', 64)), 'Cannot commit fixture confirmation');
      FreeAndNil(Store);
      Store := TTransitionStore.Create(Root + '\transition');
      Check(Store.ReadState = tsCompleted, 'Fixture confirmation did not persist');
      Check(Pos('inventory_sha256', ReadText(Store.RootDirectory + 'state.json')) > 0,
        'Persisted confirmation evidence is missing');
    end
    else if Expected = tsInstalling then
    begin
      FreeAndNil(Store);
      Store := TTransitionStore.Create(Root + '\transition');
      Check(Store.ReadState = tsInstalling, 'Interrupted state did not persist');
      try
        Store.RunFixtureCutover(Service, Scenario, Hash, Timeout, Scope, Added);
        raise Exception.Create('Uncertain installer was retried');
      except
        on E: ETransitionState do Check(Pos('uncertain', E.Message) > 0, E.Message);
      end;
      try
        Store.RunRollback(Scope, Added, Service);
        raise Exception.Create('Rollback allowed with an uncertain installer');
      except
        on E: ETransitionState do Check(Pos('rollback blocked', E.Message) > 0, E.Message);
      end;
      Sleep(1500);
    end
    else
    begin
      Check(not FileExists(Path), 'Introduced fixture file was not removed');
      Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Historical fixture service was not restored');
    end;
  finally
    if DBWriter <> INVALID_HANDLE_VALUE then CloseHandle(DBWriter);
    Store.Free;
  end;
end;

procedure TestVolumes;
const
  GiB = QWord(1024)*1024*1024;
begin
  RequireBackupCapacity(GiB, GiB, 2*GiB, 3*GiB, False);
  try
    RequireBackupCapacity(GiB, GiB, 3*GiB, 3*GiB-1, False);
    raise Exception.Create('Insufficient installation volume accepted');
  except
    on E: ETransitionBackup do
      Check(Pos('installation volume', E.Message) > 0, E.Message);
  end;
  try
    RequireBackupCapacity(GiB, GiB, 2*GiB-1, 4*GiB, False);
    raise Exception.Create('Insufficient backup volume accepted');
  except
    on E: ETransitionBackup do
      Check(Pos('backup volume', E.Message) > 0, E.Message);
  end;
  try
    RequireBackupCapacity(GiB, GiB, 3*GiB, 3*GiB, True);
    raise Exception.Create('Insufficient shared volume accepted');
  except
    on E: ETransitionBackup do
      Check(Pos('installation volume', E.Message) > 0, E.Message);
  end;
  RequireBackupCapacity(GiB, GiB, 4*GiB, 4*GiB, True);
end;

procedure TestInterrupted(const Root: UnicodeString);
var
  Store: TTransitionStore;
  State: TJSONObject;
  Handle: THandle;
begin
  Store := TTransitionStore.Create(Root + '\transition');
  try
    SeedPrepared(Store, Root);
    State := TJSONObject(GetJSON(ReadText(Store.RootDirectory + 'state.json')));
    try
      State.Strings['state'] := 'BACKUP_IN_PROGRESS';
      State.Strings['previous_state'] := 'PREPARED';
      State.Objects['backup'].Integers['service_initial_state'] := SERVICE_RUNNING;
      WriteText(Store.RootDirectory + 'state.json', State.FormatJSON);
    finally
      State.Free;
    end;
    Handle := OpenStorageFile(Store.RootDirectory + 'backup\manifest.tmp', GENERIC_WRITE, 0, CREATE_NEW);
    Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot seed interrupted backup fixture');
    CloseHandle(Handle);
  finally
    Store.Free;
  end;
  Store := TTransitionStore.Create(Root + '\transition');
  try
    Check(Store.ReadState = tsBackupInProgress, 'Interrupted backup state lost');
    Check(Store.HasBackup, 'Interrupted backup evidence lost');
    try
      Store.Advance(tsAborted);
      raise Exception.Create('Interrupted backup could abort without service restoration');
    except
      on E: ETransitionState do Check(Pos('Restore normal agent operation', E.Message) > 0, E.Message);
    end;
    try
      Store.Advance(tsBackupVerified);
      raise Exception.Create('Interrupted backup could be marked verified');
    except
      on E: ETransitionState do Check(Pos('protected backup workflow', E.Message) > 0, E.Message);
    end;
  finally
    Store.Free;
  end;
end;

function FixtureSddlToDescriptor(Text: PWideChar; Revision: DWORD;
  out Descriptor: PSECURITY_DESCRIPTOR; Size: PDWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

procedure SetFixtureFileDACL(const Path, DACL: UnicodeString);
var
  Descriptor: PSECURITY_DESCRIPTOR;
  Target: THandle;
begin
  Check(FixtureSddlToDescriptor(PWideChar(DACL), 1, Descriptor, nil), 'Invalid fixture DACL');
  try
    Target := CreateFileW(PWideChar(Path), WRITE_DAC, FILE_SHARE_READ, nil, OPEN_EXISTING, 0, 0);
    if Target = INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      Check(SetKernelObjectSecurity(Target, DACL_SECURITY_INFORMATION or DWORD($80000000), Descriptor),
        'Cannot set isolated fixture DACL');
    finally
      CloseHandle(Target);
    end;
  finally
    LocalFree(HLOCAL(Descriptor));
  end;
end;

procedure TestL4Guards;
const
  BeforeInstall: array[0..2] of TTransitionState = (tsPrecheck, tsPrepared, tsBackupVerified);
var
  State: TTransitionState;
  Store: TTransitionStore;
  ProgramData: UnicodeString;
begin
  for State in BeforeInstall do
    try
      ClassifyLocalResume(State, False, True);
      raise Exception.Create('Rollback request reached a pre-install action');
    except
      on E: ETransitionState do Check(Pos('No installation to roll back', E.Message) > 0, E.Message);
    end;
  ProgramData := GetWindowsSpecialDirUnicode(FOLDERID_ProgramData, False);
  Check(ProgramData <> '', 'Cannot resolve ProgramData');
  try
    // Use only its existing parent to prove rejection before any directory creation.
    Store := TTransitionStore.Create(ProgramData);
    Store.Free;
    raise Exception.Create('Fixture root was allowed to overlap production storage');
  except
    on E: Exception do Check(Pos('overlaps the production transition directory', E.Message) > 0, E.Message);
  end;
end;

procedure TestL3Routing;
var
  State: TTransitionState;
begin
  Check(ClassifyLocalResume(tsPrecheck, False, False) = lraPrecheck, 'PRECHECK routing');
  Check(ClassifyLocalResume(tsPrepared, False, False) = lraBackup, 'PREPARED routing');
  Check(ClassifyLocalResume(tsBackupInProgress, False, False) = lraAbandonBackup, 'Interrupted backup routing');
  Check(ClassifyLocalResume(tsBackupVerified, False, False) = lraInstall, 'BACKUP_VERIFIED routing');
  Check(ClassifyLocalResume(tsInstalling, False, False) = lraRecovery, 'Unproven installer outcome accepted');
  Check(ClassifyLocalResume(tsVerifying, False, False) = lraAwaitConfirmation, 'VERIFYING routing');
  Check(ClassifyLocalResume(tsVerifying, False, True) = lraRollback, 'Explicit restore routing');
  Check(ClassifyLocalResume(tsRollingBack, False, False) = lraRollback, 'Interrupted restore routing');
  for State := tsPrecheck to tsRollingBack do
    Check(ClassifyLocalResume(State, True, True) = lraRecovery, 'Uncertain installer allowed work');
end;

function FixtureQueryServiceProcess(Service: SC_HANDLE; InfoLevel: DWORD; Buffer: Pointer;
  BufferSize: DWORD; var Needed: DWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'QueryServiceStatusEx';

function PinFixtureServiceProcess(const Name: UnicodeString): THandle;
var
  SCM, Service: SC_HANDLE;
  Status: record
    Basic: TServiceStatus;
    PID, Flags: DWORD;
  end;
  Needed: DWORD;
  Candidate: THandle;
  Created, Ended, Kernel, UserTime: TFileTime;
  Image: UnicodeString;
begin
  Check(Pos('PADIT_BackupTest_', Name) = 1, 'Invalid fixture service name');
  SCM := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  if SCM = 0 then RaiseLastOSError;
  try
    Service := OpenServiceW(SCM, PWideChar(Name), SERVICE_QUERY_STATUS);
    if Service = 0 then RaiseLastOSError;
    try
      if not FixtureQueryServiceProcess(Service, 0, @Status, SizeOf(Status), Needed) then RaiseLastOSError;
      Check((Status.Basic.dwCurrentState = SERVICE_RUNNING) and (Status.PID <> 0),
        'Fixture service has no running process to verify');
      Candidate := OpenProcess(SYNCHRONIZE or $1000, False, Status.PID);
      if Candidate = 0 then RaiseLastOSError;
      try
        if not GetProcessTimes(Candidate, Created, Ended, Kernel, UserTime) then RaiseLastOSError;
        Image := ExpandFileName(UnicodeString(ParamStr(0)));
        Result := OpenProducer(Status.PID,
          (QWord(Created.dwHighDateTime) shl 32) or Created.dwLowDateTime, Image);
        WriteLn('Fixture SCM PID ', Status.PID, ' image ', UTF8Encode(Image));
      finally
        CloseHandle(Candidate);
      end;
    finally
      CloseServiceHandle(Service);
    end;
  finally
    CloseServiceHandle(SCM);
  end;
end;

procedure TestL3Recovery(const Root, Service: UnicodeString; const Mode: string);
var
  Store: TTransitionStore;
  State: TJSONObject;
  Scope: TBackupPaths;
  Handle, FixtureProcess: THandle;
  StoppedAt: QWord;
  CertPath, DBPath, Marker: UnicodeString;
  OriginalACL, OriginalDB, OriginalKey, Manifest: UTF8String;
begin
  Store := TTransitionStore.Create(Root + '\transition');
  Handle := INVALID_HANDLE_VALUE;
  FixtureProcess := 0;
  try
    SeedPrepared(Store, Root);
    CertPath := Root + '\agent\private\machine.crt';
    DBPath := Root + '\custom-' + UnicodeString(#$6F22) + '\waptdb.sqlite';
    OriginalDB := ReadText(DBPath);
    OriginalKey := ReadText(Root + '\agent\private\machine.pem');
    if Mode = 'l3-backup-interrupted' then
    begin
      State := TJSONObject(GetJSON(ReadText(Store.RootDirectory + 'state.json')));
      try
        State.Strings['state'] := 'BACKUP_IN_PROGRESS';
        State.Strings['previous_state'] := 'PREPARED';
        State.Objects['backup'].Integers['service_initial_state'] := SERVICE_RUNNING;
        WriteText(Store.RootDirectory + 'state.json', State.FormatJSON);
      finally
        State.Free;
      end;
      Marker := Store.RootDirectory + 'backup\manifest.tmp';
      Handle := OpenStorageFile(Marker, GENERIC_WRITE, 0, CREATE_NEW);
      Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot create interrupted backup evidence');
      CloseHandle(Handle);
      Handle := INVALID_HANDLE_VALUE;
      FixtureProcess := PinFixtureServiceProcess(Service);
      StopBackupService(Service);
      StoppedAt := GetTickCount64;
      FreeAndNil(Store);
      Store := TTransitionStore.Create(Root + '\transition');
      WaitForProducer(FixtureProcess, 5000);
      WriteLn('Fixture process exit confirmed ', GetTickCount64 - StoppedAt, ' ms after SCM stop');
      Check(Store.ResumeFixtureRecovery(Service, nil, nil, False, FixtureProcess),
        'Interrupted backup recovery journal failed');
      Check(Store.ReadState = tsAborted, 'Interrupted backup was not abandoned');
      Check(FileExists(Marker), 'Interrupted backup evidence lost');
      Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Fixture service did not restart');
      Check(ReadText(DBPath) = OriginalDB, 'Backup interruption changed SQLite');
      Exit;
    end;
    SetFixtureFileDACL(CertPath, 'D:P(A;;FA;;;SY)(A;;FA;;;BA)');
    OriginalACL := FixtureFileSDDL(CertPath);
    Check(Pos('D:P(', OriginalACL) > 0, 'Fixture certificate is not protected');
    Check(Store.RunBackup(Service), 'Fixture backup failed');
    Check(Store.Advance(tsInstalling), 'Cannot establish installation boundary');
    Manifest := ReadText(Store.RootDirectory + 'backup\manifest.json');
    Scope := nil;
    AddBackupSource(Scope, Root + '\agent');
    AddBackupSource(Scope, ExtractFileDir(DBPath));
    if Mode = 'l3-pending' then
    begin
      Marker := Store.RootDirectory + 'staging\installer.pending';
      Handle := OpenStorageFile(Marker, GENERIC_WRITE, 0, CREATE_NEW);
      Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot create pending installer marker');
      CloseHandle(Handle);
      Handle := INVALID_HANDLE_VALUE;
      try
        Store.ResumeFixtureRecovery(Service, Scope, nil, True);
        raise Exception.Create('Uncertain installer was restored or rerun');
      except
        on E: ETransitionState do Check(Pos('Local recovery required', E.Message) > 0, E.Message);
      end;
      Check(Store.ReadState = tsRecoveryRequired, 'Uncertain installer did not require recovery');
      Check(FileExists(Marker), 'Uncertain installer evidence lost');
      Check(FixtureFileSDDL(CertPath) = OriginalACL, 'Uncertain path touched certificate permissions');
    end
    else
    begin
      Check(Store.Advance(tsRollingBack), 'Cannot establish rollback boundary');
      SetFixtureFileDACL(CertPath, 'D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)');
      Check(FixtureFileSDDL(CertPath) <> OriginalACL, 'Fixture did not change the DACL');
      if Mode = 'l3-restore-fail' then
      begin
        Handle := CreateFileW(PWideChar(CertPath), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
          nil, OPEN_EXISTING, 0, 0);
        Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot lock fixture restoration target');
      end;
      FreeAndNil(Store);
      Store := TTransitionStore.Create(Root + '\transition');
      if Mode = 'l3-restore-fail' then
      begin
        try
          Store.ResumeFixtureRecovery(Service, Scope, nil);
          raise Exception.Create('Locked file was accepted');
        except
          on E: ETransitionBackup do Check(Pos('restoration destination', E.Message) > 0, E.Message);
        end;
        Check(Store.ReadState = tsRecoveryRequired, 'Failed restoration did not require recovery');
      end
      else
      begin
        Check(Store.ResumeFixtureRecovery(Service, Scope, nil), 'Interrupted rollback journal failed');
        Check(Store.ReadState = tsRolledBack, 'Interrupted rollback was not verified and committed');
        Check(FixtureFileSDDL(CertPath) = OriginalACL, 'Changed protected certificate DACL differs from manifest');
        Check(BackupServiceState(Service) = SERVICE_RUNNING, 'Historical fixture service did not restart');
        WriteLn('PASS restored changed protected machine.crt SDDL exactly');
      end;
    end;
    Check(ReadText(Store.RootDirectory + 'backup\manifest.json') = Manifest, 'Backup manifest changed');
    Check(ReadText(DBPath) = OriginalDB, 'Fixture SQLite contents changed');
    Check(ReadText(Root + '\agent\private\machine.pem') = OriginalKey, 'Fixture key changed');
  finally
    if FixtureProcess <> 0 then CloseHandle(FixtureProcess);
    if Handle <> INVALID_HANDLE_VALUE then CloseHandle(Handle);
    Store.Free;
  end;
end;

procedure MakeHugeSparse(const FileName: UnicodeString);
const
  SetSparse = $000900C4;
var
  Handle: THandle;
  HighOffset: LongInt;
  Returned: DWORD;
begin
  Handle := CreateFileW(PWideChar(FileName), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot create sparse fixture');
  try
    Check(DeviceIoControl(Handle, SetSparse, nil, 0, nil, 0, Returned, nil), 'Cannot mark fixture sparse');
    HighOffset := 1024;
    Check(SetFilePointer(Handle, 0, @HighOffset, FILE_BEGIN) = 0, 'Cannot seek sparse fixture');
    Check(SetEndOfFile(Handle), 'Cannot set sparse fixture length');
  finally
    CloseHandle(Handle);
  end;
end;

var
  Root, Service: UnicodeString;
  Mode: string;
begin
  try
    Mode := ParamStr(1);
    if Mode = 'service' then RunFixtureService
    else if Mode = 'fixture-delay' then Sleep(1200)
    else if Mode = 'fixture-install' then FixtureInstaller
    else
    begin
      Root := UnicodeString(ParamStr(2));
      Service := UnicodeString(ParamStr(3));
      if Mode = 'setup-arguments' then TestSetupArguments
      else if Mode = 'l4-guards' then TestL4Guards
      else if Mode = 'l3-routing' then TestL3Routing
      else if (Mode = 'l3-backup-interrupted') or (Mode = 'l3-pending') or
        (Mode = 'l3-rollback') or (Mode = 'l3-restore-fail') then TestL3Recovery(Root, Service, Mode)
      else if Pos('l2-', Mode) = 1 then TestCutover(Root, Service, 'cutover-' + UnicodeString(Copy(Mode,4,MaxInt)), True)
      else if Pos('cutover-', Mode) = 1 then TestCutover(Root, Service, UnicodeString(Mode))
      else if Mode = 'success' then TestSuccess(Root, Service)
      else if Mode = 'restore' then TestRestore(Root, Service)
      else if Mode = 'restore-failure' then TestRestore(Root, Service, True)
      else if Mode = 'preexisting' then
        ExpectBackupFailure(Root, Service, UnicodeString(Mode), 'previous backup exists', tsPrepared)
      else if (Mode = 'inaccessible') or (Mode = 'busy') then
        ExpectBackupFailure(Root, Service, UnicodeString(Mode), 'inaccessible or still open for writing', tsAborted)
      else if Mode = 'restore-fails' then
        ExpectBackupFailure(Root, Service, UnicodeString(Mode), 'inaccessible or still open for writing', tsRecoveryRequired)
      else if Mode = 'volumes' then
        TestVolumes
      else if Mode = 'interrupted' then TestInterrupted(Root)
      else if Mode = 'space' then
      begin
        MakeHugeSparse(Root + '\agent\huge.sparse');
        ExpectBackupFailure(Root, Service, UnicodeString(Mode), 'Insufficient disk space', tsPrepared);
      end
      else raise Exception.Create('Unknown backup test mode');
      WriteLn('PASS ', Mode);
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
