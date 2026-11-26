program test_transition_state;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, transitionstate;

procedure Check(Condition: Boolean; const Description: string);
begin
  if not Condition then
    raise Exception.Create(Description);
end;

function ReadText(const Path: UnicodeString): UTF8String;
var
  Handle: THandle;
  Stream: THandleStream;
begin
  Handle := FileOpen(Path, fmOpenRead or fmShareDenyWrite);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    Stream := THandleStream.Create(Handle);
    try
      Result := '';
      SetLength(Result, Stream.Size);
      if Result <> '' then
        Stream.ReadBuffer(Result[1], Length(Result));
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
  if Handle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    Check(FileWrite(Handle, Text[1], Length(Text)) = Length(Text), 'Short test write');
  finally
    FileClose(Handle);
  end;
end;

procedure ExpectInvalid(Store: TTransitionStore; const Path: UnicodeString;
  const Text: UTF8String; const ErrorText: string);
begin
  WriteText(Path, Text);
  try
    Store.ReadState;
    raise Exception.Create('Invalid state was accepted');
  except
    on E: ETransitionState do
      Check(Pos(ErrorText, E.Message) > 0, E.Message);
  end;
  try
    Store.Advance(tsPrecheckFailed);
    raise Exception.Create('Advance accepted an invalid state');
  except
    on E: ETransitionState do
      Check(Pos(ErrorText, E.Message) > 0, E.Message);
  end;
  Check(ReadText(Path) = Text, 'Invalid state was overwritten');
end;

procedure SeedPreparedFixture(const Path: UnicodeString);
var
  Initial: UTF8String;
begin
  // Seed an already-prepared state to test later states without bypassing the API.
  Initial := ReadText(Path);
  Initial := StringReplace(Initial, '"state" : "PRECHECK"', '"state" : "PREPARED"', []);
  Initial := StringReplace(Initial, '"previous_state" : null', '"previous_state" : "PRECHECK"', []);
  WriteText(Path, Initial);
end;

procedure TestStore(const Root: UnicodeString);
var
  Store: TTransitionStore;
  Path: UnicodeString;
  BeforeWrite, FirstState, Journal: UTF8String;
  Reader: THandle;
  State: TTransitionState;
begin
  Path := Root + '\state.json';
  Store := TTransitionStore.Create(Root);
  try
    Check(not FileExists(Path), 'Opening the store created a transition');
    Store.Initialize;
    Check(Store.ReadState = tsPrecheck, 'Wrong initial state');
    Check(DirectoryExists(Root + '\backup') and DirectoryExists(Root + '\staging'),
      'Missing storage directories');
    FirstState := ReadText(Path);
    Check(Pos('"previous_state" : null', FirstState) > 0, 'Missing initial previous_state');
    for State := Low(TTransitionState) to High(TTransitionState) do
      Check(CanAdvance(State, tsInstalling) = (State = tsBackupVerified),
        'Installation is not gated by backup verification');
    try
      Store.Advance(tsInstalling);
      raise Exception.Create('Forbidden jump accepted');
    except
      on E: ETransitionState do
        Check(Pos('Forbidden transition', E.Message) > 0, E.Message);
    end;
    Check(ReadText(Path) = FirstState, 'Forbidden jump changed state');
    try
      Store.Advance(tsPrepared);
      raise Exception.Create('PREPARED bypass accepted');
    except
      on E: ETransitionState do
        Check(Pos('requires successful full prechecks', E.Message) > 0, E.Message);
    end;
    Check(ReadText(Path) = FirstState, 'Rejected PREPARED bypass changed state');

    ExpectInvalid(Store, Path, '{broken', 'Invalid state JSON');
    ExpectInvalid(Store, Path, FirstState + 'false', 'Invalid state JSON');
    ExpectInvalid(Store, Path, FirstState + #0 + 'false', 'Invalid state JSON');
    ExpectInvalid(Store, Path, '{"schema_version":1,' + Copy(FirstState, 2, MaxInt),
      'Invalid state JSON');
    ExpectInvalid(Store, Path, StringReplace(FirstState, '"schema_version" : 1',
      '"schema_version" : 2', []), 'Unsupported state schema version');
    ExpectInvalid(Store, Path, StringReplace(FirstState, '"PRECHECK"',
      '"UNKNOWN"', []), 'Unknown transition state');
    ExpectInvalid(Store, Path, StringReplace(FirstState, '"PRECHECK"',
      '"INSTALLING"', []), 'Missing or invalid field: previous_state');
    WriteText(Path, FirstState);

    Reader := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ,
      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if Reader = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    try
      try
        Store.Advance(tsPrecheckFailed);
        raise Exception.Create('Replacement succeeded despite denied delete access');
      except
        on E: EOSError do
          Check(E.ErrorCode in [ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION], E.Message);
      end;
      BeforeWrite := ReadText(Path);
      Check(BeforeWrite = FirstState, 'Failed replacement changed the state file');
    finally
      CloseHandle(Reader);
    end;
    SeedPreparedFixture(Path);
    Store.Advance(tsBackupInProgress);
    Store.Advance(tsBackupVerified);
    Store.Advance(tsInstalling);
    Store.Advance(tsVerifying);
    Store.Advance(tsRollingBack);
    Store.Advance(tsRolledBack);
    Check(Store.ReadState = tsRolledBack, 'Rollback state missing');
    try
      Store.Initialize;
      raise Exception.Create('Terminal state was reinitialized');
    except
      on E: ETransitionState do
        Check(Pos('already exists', E.Message) > 0, E.Message);
    end;
    Check(not CanAdvance(tsRolledBack, tsPrecheck), 'Terminal state can restart');
    Journal := ReadText(Root + '\logs\transition.log');
    Check(Pos('Z STATE PRECHECK', Journal) > 0, 'Missing UTC journal entry');
    Check(Pos('ERROR Advance: Forbidden transition', Journal) > 0, 'Missing error journal');
    Check(Pos('ROLLING_BACK -> ROLLED_BACK', Journal) > 0, 'Missing rollback journal');
  finally
    Store.Free;
  end;
end;

procedure TestAborted(const Root: UnicodeString);
var
  Store: TTransitionStore;
  State, BeforeAbort: TTransitionState;
  Path: UnicodeString;
begin
  for State := Low(TTransitionState) to High(TTransitionState) do
  begin
    Check(CanAdvance(State, tsAborted) =
      (State in [tsPrepared, tsBackupInProgress, tsBackupVerified]),
      'Unexpected predecessor for ABORTED');
    Check(not CanAdvance(tsAborted, State), 'ABORTED has an outgoing transition');
  end;
  for BeforeAbort := tsPrepared to tsBackupVerified do
  begin
    Path := Root + '-abort-' + UnicodeString(IntToStr(Ord(BeforeAbort)));
    Store := TTransitionStore.Create(Path);
    try
      Check(Store.Initialize, 'Initial journal write failed');
      SeedPreparedFixture(Path + '\state.json');
      if BeforeAbort >= tsBackupInProgress then
        Check(Store.Advance(tsBackupInProgress), 'BACKUP_IN_PROGRESS journal write failed');
      if BeforeAbort = tsBackupVerified then
        Check(Store.Advance(tsBackupVerified), 'BACKUP_VERIFIED journal write failed');
      Check(Store.Advance(tsAborted), 'ABORTED journal write failed');
    finally
      Store.Free;
    end;
    Store := TTransitionStore.Create(Path);
    try
      Check(Store.ReadState = tsAborted, 'ABORTED was not persisted');
    finally
      Store.Free;
    end;
  end;
end;

procedure TestJournalFailure(const Root: UnicodeString);
var
  Store: TTransitionStore;
  Handle: THandle;
begin
  Store := TTransitionStore.Create(Root);
  try
    Handle := CreateFileW(PWideChar(Root + '\logs\transition.log'), GENERIC_READ,
      FILE_SHARE_READ, nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if Handle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    try
      Check(not Store.Initialize, 'Initialize did not report journal failure');
      Check(Store.ReadState = tsPrecheck, 'Initialize did not commit PRECHECK');
      SeedPreparedFixture(Root + '\state.json');
      Check(not Store.Advance(tsAborted), 'Advance did not report journal failure');
      Check(Store.ReadState = tsAborted, 'Advance did not commit ABORTED');
    finally
      CloseHandle(Handle);
    end;
    Check(Store.ReadState = tsAborted, 'State changed after unlocking the journal');
  finally
    Store.Free;
  end;
end;

var
  Root: UnicodeString;
  Store: TTransitionStore;
  Command: string;
begin
  try
    Check(ParamCount = 2, 'Usage: test_transition_state check|review|hold|busy|resume TEMP_ROOT');
    Command := ParamStr(1);
    Root := IncludeTrailingPathDelimiter(UnicodeString(ParamStr(2))) +
      UnicodeString(#$6F22) + '-transition';
    if Command = 'review' then
    begin
      TestAborted(Root);
      TestJournalFailure(Root + '-journal');
    end
    else if Command = 'check' then
      TestStore(Root)
    else if Command = 'busy' then
    begin
      try
        Store := TTransitionStore.Create(Root);
        Store.Free;
        raise Exception.Create('Concurrent process acquired the lock');
      except
        on E: ETransitionState do
          Check(Pos('holds the transition lock', E.Message) > 0, E.Message);
      end;
    end
    else
    begin
      Store := TTransitionStore.Create(Root);
      try
        if Command = 'hold' then
        begin
          Store.Initialize;
          Store.RecordPrecheckFailure('fixture diagnostic');
          WriteLn('READY');
          Flush(Output);
          Sleep(INFINITE);
        end
        else if Command = 'resume' then
          Check(Store.ReadState = tsPrecheckFailed, 'State lost after process termination')
        else
          raise Exception.Create('Unknown test command');
      finally
        Store.Free;
      end;
    end;
    WriteLn('PASS ', Command);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      ExitCode := 1;
    end;
  end;
end.
