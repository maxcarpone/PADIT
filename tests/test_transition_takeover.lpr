program test_transition_takeover;

{$mode objfpc}{$H+}

uses SysUtils, Windows, transitionprecheck, transitionbackup;

const
  Idle = '{"running":null,"pending":[]}';
  Active = '{"running":{"id":7},"pending":[]}';
  Pending = '{"running":null,"pending":[{"id":8}]}';

type
  TFixture = class(THistoricalService)
    Current: DWORD;
    Queue: array of string;
    Polls, Stops, Restarts, ProcessChecks, DatabaseChecks: Integer;
    StopFails, ProcessPresent, DatabaseBusy: Boolean;
    constructor Create;
    function State: DWORD; override;
    procedure CheckQueue(Deadline: QWord); override;
    procedure Stop; override;
    procedure RestoreRunning; override;
    procedure CheckProcesses; override;
    procedure CheckDatabase; override;
  end;

procedure Check(Condition: Boolean; const Detail: string);
begin
  if not Condition then raise Exception.Create(Detail);
end;

constructor TFixture.Create;
begin
  inherited;
  Current := SERVICE_RUNNING;
  Queue := [Idle];
end;

function TFixture.State: DWORD;
begin
  Result := Current;
end;

procedure TFixture.CheckQueue(Deadline: QWord);
var
  Index: Integer;
begin
  Check(GetTickCount64 < Deadline, 'query begun after deadline');
  Index := Polls;
  Inc(Polls);
  if Index > High(Queue) then Index := High(Queue);
  if Queue[Index] = '' then raise ELocalPrecheck.Create('fixture API unreachable');
  CheckTaskStatus(Queue[Index]);
end;

procedure TFixture.Stop;
begin
  Inc(Stops);
  if StopFails then raise ELocalPrecheck.Create('fixture SCM stop failed');
  Current := SERVICE_STOPPED;
end;

procedure TFixture.RestoreRunning;
begin
  Inc(Restarts);
  Current := SERVICE_RUNNING;
end;

procedure TFixture.CheckProcesses;
begin
  Inc(ProcessChecks);
  if ProcessPresent then raise ELocalPrecheck.Create('fixture historical process still running');
end;

procedure TFixture.CheckDatabase;
begin
  Inc(DatabaseChecks);
  if DatabaseBusy then raise ELocalPrecheck.Create('fixture SQLite writer still active');
end;

procedure Test(const Name, Failure: string; Events: array of string; Initial: DWORD;
  StopFails, ProcessPresent, DatabaseBusy: Boolean; ExpectedStops, ExpectedRestarts: Integer;
  Timeout: DWORD = 3000);
var
  Fixture: TFixture;
  OriginalState: DWORD;
  I: Integer;
begin
  Fixture := TFixture.Create;
  try
    Fixture.Current := Initial;
    SetLength(Fixture.Queue, Length(Events));
    for I := 0 to High(Events) do Fixture.Queue[I] := Events[I];
    Fixture.StopFails := StopFails;
    Fixture.ProcessPresent := ProcessPresent;
    Fixture.DatabaseBusy := DatabaseBusy;
    try
      OriginalState := WaitForHistoricalIdle(Fixture, Timeout);
      try
        TakeControlOfHistoricalService(Fixture, OriginalState);
      except
        RestoreHistoricalService(Fixture, OriginalState);
        raise;
      end;
      Check(Failure = '', 'fixture should have failed');
      Check((Fixture.ProcessChecks = 1) and (Fixture.DatabaseChecks = 1), 'quiescence check skipped');
    except
      on E: ELocalPrecheck do
      begin
        Check((Failure <> '') and (Pos(Failure, E.Message) > 0), E.Message);
        Check(Fixture.Current = Initial, 'initial state was not preserved');
      end;
    end;
    Check(Fixture.Stops = ExpectedStops, 'unexpected SCM stop count');
    Check(Fixture.Restarts = ExpectedRestarts, 'unexpected service restart count');
    if Initial = SERVICE_STOPPED then Check(Fixture.Polls = 0, 'queried a stopped service');
    WriteLn('PASS ', Name);
  finally
    Fixture.Free;
  end;
end;

procedure TestDatabaseWriter;
const
  Header: AnsiString = 'SQLite format 3'#0#16#0#1#1;
var
  Path: UnicodeString;
  Writer: THandle;
  Bytes: DWORD;
begin
  Path := IncludeTrailingPathDelimiter(ExtractFileDir(UnicodeString(ParamStr(0)))) + 'writer.sqlite';
  Writer := CreateFileW(PWideChar(Path), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if Writer = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    try
      Check(WriteFile(Writer, Header[1], Length(Header), Bytes, nil) and
        (Bytes = Length(Header)), 'cannot write fixture SQLite header');
      try
        VerifyBackupDatabase(Path);
        raise Exception.Create('SQLite writer was not rejected');
      except
        on E: ETransitionBackup do
          Check(Pos('still open for writing', E.Message) > 0, E.Message);
      end;
    finally
      CloseHandle(Writer);
    end;
    VerifyBackupDatabase(Path);
    WriteLn('PASS isolated file writer exclusion');
  finally
    Windows.DeleteFileW(PWideChar(Path));
  end;
end;

begin
  TestDatabaseWriter;
  Test('idle running service', '', [Idle], SERVICE_RUNNING, False, False, False, 1, 0);
  Test('active then idle', '', [Active, Idle], SERVICE_RUNNING, False, False, False, 1, 0);
  Test('pending then idle', '', [Pending, Idle], SERVICE_RUNNING, False, False, False, 1, 0);
  Test('new pending task before stop', 'pending', [Idle, Pending], SERVICE_RUNNING, False, False, False, 0, 0);
  Test('timeout with active task', 'Timed out', [Active], SERVICE_RUNNING, False, False, False, 0, 0, 100);
  Test('timeout with pending task', 'Timed out', [Pending], SERVICE_RUNNING, False, False, False, 0, 0, 100);
  Test('unreachable API', 'unreachable', [''], SERVICE_RUNNING, False, False, False, 0, 0);
  Test('already stopped service', '', [], SERVICE_STOPPED, False, False, False, 0, 0);
  Test('failed SCM stop', 'SCM stop failed', [Idle], SERVICE_RUNNING, True, False, False, 1, 0);
  Test('remaining process and service restoration', 'process still running', [Idle], SERVICE_RUNNING,
    False, True, False, 1, 1);
  Test('SQLite writer and service restoration', 'writer still active', [Idle], SERVICE_RUNNING,
    False, False, True, 1, 1);
end.
