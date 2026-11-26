program test_transition_backup;

{$mode objfpc}{$H+}

uses Classes, SysUtils, Windows, fpjson, jsonparser, transitionstate,
  transitionbackup, transitionbackupwindows, transitionstorage;

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
    else
    begin
      Root := UnicodeString(ParamStr(2));
      Service := UnicodeString(ParamStr(3));
      if Mode = 'success' then TestSuccess(Root, Service)
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
