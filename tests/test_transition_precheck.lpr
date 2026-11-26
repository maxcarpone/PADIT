program test_transition_precheck;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, fpjson, transitionstate, transitionstorage, transitionprecheck;

const
  Enough = QWord(8) * 1024 * 1024 * 1024;

procedure Check(Value: Boolean; const Reason: string);
begin
  if not Value then raise Exception.Create(Reason);
end;

procedure TestPrecheck(const Root: UnicodeString);
var
  Metadata: TLocalMetadata;
  Config, Agent, PackageDir, Identity, StorePath: UnicodeString;
  Store: TTransitionStore;
  ActualState: UTF8String;
  Stream: THandleStream;
  Handle: THandle;
  Snapshot: TJSONObject;

  function Inspect(const Ini: UnicodeString; Free: QWord): TLocalMetadata;
  begin
    Result := InspectLocalAgent(Agent, Ini, Agent, PackageDir,
      'fixture.example.test', SERVICE_STOPPED, Free, Free, True, Snapshot.AsJSON,
      'WAPT Community 1.8.3');
  end;

  procedure ExpectFailure(const Ini: UnicodeString; Free: QWord; const Diagnostic: string);
  begin
    try
      Inspect(Ini, Free);
      raise Exception.Create('Precheck unexpectedly succeeded');
    except
      on E: ELocalPrecheck do Check(Pos(Diagnostic, E.Message) <> 0, E.Message);
    end;
  end;

begin
  Agent := Root + '\agent';
  PackageDir := Root + '\payload';
  Config := Root + '\custom ' + UnicodeString(#$6F22) + '.ini';
  Identity := Root + '\identity ' + UnicodeString(#$6F22) + '\fixture-id.crt';
  Snapshot := TJSONObject.Create;
  try
    Snapshot.Add('schema_version', 1);
    Snapshot.Add('config_path', UTF8Encode(Config));
    Snapshot.Add('database_path', UTF8Encode(Root + '\data ' + UnicodeString(#$6F22) + '\custom.sqlite'));
    Snapshot.Add('hostname', 'fixture.example.test');
    Snapshot.Add('uuid', 'fixture-id');
    Snapshot.Add('registered_uuid', 'fixture-id');
    Snapshot.Add('identification_mode', 'configured');
    Snapshot.Add('preparation_pid');
    Snapshot.Add('preparation_task_id');
    Metadata := Inspect(Config, Enough);
    Check(Metadata.UUID = 'fixture-id', 'Wrong configured UUID');
    Check(Metadata.ConfigPath = UTF8Encode(Config), 'Wrong Unicode configuration path');
    Check(Metadata.CertificatePath = UTF8Encode(Identity), 'Wrong Unicode identity path');
    Check(Metadata.DatabasePath = UTF8Encode(Root + '\data ' + UnicodeString(#$6F22) +
      '\custom.sqlite'), 'Wrong Unicode database path');
    Check(Metadata.SourceVersion = Metadata.TargetVersion, 'Same-version migration was not tested');
    Snapshot.Strings['config_path'] := UTF8Encode(Root + '\stored.ini');
    Snapshot.Strings['identification_mode'] := 'stored';
    Metadata := Inspect(Root + '\stored.ini', Enough);
    Check((Metadata.IdentificationMode = 'stored') and (Metadata.UUID = 'fixture-id'),
      'Existing UUID was not recovered from SQLite');
    Snapshot.Strings['config_path'] := UTF8Encode(Config);
    Snapshot.Strings['identification_mode'] := 'configured';
    Snapshot.Strings['registered_uuid'] := 'other-id';
    ExpectFailure(Config, Enough, 'Recorded and effective WAPT UUIDs differ');
    Snapshot.Strings['registered_uuid'] := 'fixture-id';
    try
      InspectLocalAgent(Agent, Config, Agent, PackageDir, 'fixture.example.test',
        SERVICE_STOPPED, Enough, Enough, True, Snapshot.AsJSON, 'WAPT Enterprise 1.8.3');
      raise Exception.Create('Conflicting edition was accepted');
    except
      on E: ELocalPrecheck do Check(Pos('Unsupported historical WAPT', E.Message) > 0, E.Message);
    end;
    ExpectFailure(Root + '\absent.ini', Enough, 'Missing required');
    ExpectFailure(Root + '\invalid.ini', Enough, 'Missing [global]');
    ExpectFailure(Root + '\wrong-source.ini', Enough, 'differs from source_server_url');
    ExpectFailure(Config, 1, 'Insufficient disk space');
    Check(MoveFileW(PWideChar(Identity), PWideChar(Identity + '.absent')), 'Cannot move fixture certificate');
    try
      ExpectFailure(Config, Enough, 'Missing machine certificate');
    finally
      Check(MoveFileW(PWideChar(Identity + '.absent'), PWideChar(Identity)), 'Cannot restore fixture certificate');
    end;
    Agent := Root + '\agent-182';
    Metadata := Inspect(Config, Enough);
    Check(Pos('1.8.2.', Metadata.SourceVersion) = 1, 'WAPT 1.8.2 fixture was not tested');
    Agent := Root + '\agent-unsupported';
    ExpectFailure(Config, Enough, 'Unsupported historical WAPT');
    CheckTaskStatus('{"running":null,"pending":[]}');
    CheckTaskStatus('{"running":{"id":17,"classname":"WaptPackageInstall"},"pending":[]}', 17);
    try
      CheckTaskStatus('{"running":{"id":17,"classname":"WaptPackageInstall"},"pending":[]}', 18);
      raise Exception.Create('Unexpected running task was accepted');
    except
      on E: ELocalPrecheck do Check(Pos('running or pending', E.Message) <> 0, E.Message);
    end;
    try
      CheckTaskStatus('{"running":{"id":17,"classname":"WaptPackageInstall"},"pending":[]}');
      raise Exception.Create('Final activity recheck exempted a running task');
    except
      on E: ELocalPrecheck do Check(Pos('running or pending', E.Message) <> 0, E.Message);
    end;
    try
      CheckTaskStatus('{"running":null,"pending":[{}]}');
      raise Exception.Create('Pending task accepted');
    except
      on E: ELocalPrecheck do Check(Pos('running or pending', E.Message) <> 0, E.Message);
    end;
    StorePath := Root + '\secure';
    Store := TTransitionStore.Create(StorePath);
    try
      Check(Store.Initialize, 'Initial journal failed');
      Store.StageHistoricalSnapshot(Snapshot.AsJSON);
      Check(FileExists(Store.RootDirectory + 'staging\historical.json'), 'Snapshot was not staged');
      Check(Store.RecordLocalMetadata(Metadata), 'Local precheck journal failed');
      Check(Store.ReadState = tsPrecheck, 'Local checks advanced the global precheck state');
    finally
      Store.Free;
    end;
    Handle := FileOpen(StorePath + '\state.json', fmOpenRead or fmShareDenyNone);
    Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot reopen persistent state');
    try
      Stream := THandleStream.Create(Handle);
      try
        SetLength(ActualState, Stream.Size);
        Stream.ReadBuffer(ActualState[1], Length(ActualState));
      finally
        Stream.Free;
      end;
    finally
      FileClose(Handle);
    end;
    Check((Pos('"db_path"', ActualState) > 0) and (Pos('fixture-id', ActualState) > 0)
      and (Pos('PRIVATE-FIXTURE-ONLY', ActualState) = 0), 'Persistent metadata is incomplete or exposed a key');
  finally
    Snapshot.Free;
  end;
end;

procedure TestStorage(const Root: UnicodeString);
var
  Store: TTransitionStore;
  Handle: THandle;
  Marker: UnicodeString;
  Metadata: TLocalMetadata;

  procedure ExpectUnsafe(const Path, Diagnostic: UnicodeString);
  begin
    try
      Store := TTransitionStore.Create(Path);
      Store.Free;
      raise Exception.Create('Unsafe storage was opened');
    except
      on E: Exception do Check(Pos(Diagnostic, UnicodeString(E.Message)) > 0, E.Message);
    end;
  end;

begin
  ExpectUnsafe(Root + '\insecure', 'Unsafe transition');
  ExpectUnsafe(Root + '\junction', 'Reparse point');
  Store := TTransitionStore.Create(Root + '\with-backup');
  try
    Check(Store.Initialize, 'Initial journal failed');
    Check(not MoveFileW(PWideChar(Root), PWideChar(Root + '-replacement')),
      'A live store allowed its parent to be renamed');
    Marker := Store.RootDirectory + 'backup\manifest.json';
    Handle := OpenStorageFile(Marker, GENERIC_WRITE, 0, CREATE_NEW);
    Check(Handle <> INVALID_HANDLE_VALUE, 'Cannot create backup fixture');
    CloseHandle(Handle);
    try
      RunLocalPrecheck(Store, Root + '\payload', Metadata);
      raise Exception.Create('Existing backup did not block precheck');
    except
      on E: ELocalPrecheck do Check(Pos('backup exists', E.Message) > 0, E.Message);
    end;
    Check(FileExists(Marker) and (Store.ReadState = tsPrecheckFailed),
      'Backup was lost or failed precheck was not recorded');
  finally
    Store.Free;
  end;
end;

begin
  try
    Check(ParamCount = 1, 'Expected the isolated fixture directory');
    TestPrecheck(UnicodeString(ParamStr(1)));
    WriteLn('PASS local prechecks');
    TestStorage(UnicodeString(ParamStr(1)));
    WriteLn('PASS protected storage');
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
