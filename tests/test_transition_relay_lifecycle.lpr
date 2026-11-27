program test_transition_relay_lifecycle;

{$mode objfpc}{$H+}

uses Classes, SysUtils, transitionrelay, transitionstate;

const
  Id = '{01234567-89AB-CDEF-0123-456789ABCDEF}';
  OtherId = '{01234567-89AB-CDEF-0123-456789ABCDF0}';

type
  TFixtureScheduler = class(TRelayScheduler)
    Task: TRelayTask;
    Status: TRelayTaskStatus;
    Registrations, Starts, Disables, Deletes: Integer;
    FailStart, FailDelete: Boolean;
    procedure RegisterNew(const Proposed: TRelayTask); override;
    procedure RunNow(const Name: UnicodeString); override;
    function OwnedStatus(const Expected: TRelayTask): TRelayTaskStatus; override;
    procedure DisableOwned(const Expected: TRelayTask); override;
    procedure DeleteOwned(const Expected: TRelayTask); override;
  end;

procedure Check(Value: Boolean; const Diagnostic: string);
begin
  if not Value then raise Exception.Create(Diagnostic);
end;

procedure TFixtureScheduler.RegisterNew(const Proposed: TRelayTask);
begin
  Check(Status = rtsAbsent, 'Duplicate registration');
  Inc(Registrations);
  Task := Proposed;
  if Task.AtStartup then Status := rtsBoot else Status := rtsImmediate;
end;

procedure TFixtureScheduler.RunNow(const Name: UnicodeString);
begin
  Check(Name = Task.Name, 'Unexpected task name');
  Inc(Starts);
  if FailStart then raise ETransitionRelay.Create('fixture start outcome unknown');
end;

function TFixtureScheduler.OwnedStatus(const Expected: TRelayTask): TRelayTaskStatus;
begin
  if (Status <> rtsAbsent) and ((Task.Name <> Expected.Name) or
     (Task.Arguments <> Expected.Arguments) or (Task.ImagePath <> Expected.ImagePath) or
     (Task.WorkingDirectory <> Expected.WorkingDirectory) or (Task.Principal <> Expected.Principal)) then
    raise ETransitionRelay.Create('fixture task is foreign');
  Result := Status;
end;

procedure TFixtureScheduler.DisableOwned(const Expected: TRelayTask);
begin
  Check(OwnedStatus(Expected) <> rtsAbsent, 'Missing task to disable');
  Inc(Disables);
  Status := rtsDisabled;
end;

procedure TFixtureScheduler.DeleteOwned(const Expected: TRelayTask);
begin
  Check(OwnedStatus(Expected) <> rtsAbsent, 'Missing task to delete');
  Inc(Deletes);
  if FailDelete then raise ETransitionRelay.Create('fixture deletion refused');
  Status := rtsAbsent;
end;

procedure ExpectRefusal(Scheduler: TFixtureScheduler; const Root, Detail: string);
begin
  try
    EnsureRelay(Scheduler, UnicodeString(Root), Id, False);
    raise Exception.Create('Unexpected automatic launch');
  except
    on E: ETransitionRelay do Check(Pos(Detail, E.Message) > 0, E.Message);
  end;
end;

procedure TestInterruptedScheduling(const Root: UnicodeString);
var
  Scheduler: TFixtureScheduler;
begin
  Scheduler := TFixtureScheduler.Create;
  try
    // Approved state exists, but the task had not yet been registered.
    EnsureRelay(Scheduler, Root, Id, True);
    EnsureRelay(Scheduler, Root, Id, True);
    Check((Scheduler.Registrations = 1) and (Scheduler.Starts = 0), 'Boot task rearmed');
    Check(ClassifyRelayEntry(tsPrecheck, False, False) = reaClaim, 'First trigger not claimable');
    RetireRelay(Scheduler, Root, Id, False);
    RetireRelay(Scheduler, Root, Id, False);
    Check((Scheduler.Disables = 1) and (Scheduler.Deletes = 0), 'Consumed trigger left enabled or lost');
    Check(ClassifyRelayEntry(tsPrecheck, True, False) = reaResume, 'Duplicate claim allowed');
    ExpectRefusal(Scheduler, UTF8Encode(Root), 'already consumed');
    WriteLn('PASS preparation interruption, boot consumption and duplicate');
  finally
    Scheduler.Free;
  end;
  Scheduler := TFixtureScheduler.Create;
  try
    Scheduler.FailStart := True;
    ExpectRefusal(Scheduler, UTF8Encode(Root), 'uncertain');
    Scheduler.FailStart := False;
    ExpectRefusal(Scheduler, UTF8Encode(Root), 'uncertain');
    Check((Scheduler.Registrations = 1) and (Scheduler.Starts = 1), 'Uncertain start was repeated');
    WriteLn('PASS uncertain launch preserved without repeat');
  finally
    Scheduler.Free;
  end;
end;

procedure TestRecovery;
begin
  Check(ClassifyRelayEntry(tsPrepared, True, False) = reaResume, 'Safe prepared resume denied');
  Check(ClassifyRelayEntry(tsBackupVerified, True, False) = reaResume, 'Verified backup resume denied');
  Check(ClassifyRelayEntry(tsBackupInProgress, True, False) = reaResume, 'Interrupted backup was not routed to local resume');
  Check(ClassifyRelayEntry(tsInstalling, True, True) = reaRecovery, 'Interrupted installation admitted');
  Check(ClassifyRelayEntry(tsRollingBack, True, False) = reaResume, 'Interrupted restore was not routed to local resume');
  Check(ClassifyRelayEntry(tsBackupVerified, True, True) = reaRecovery, 'Unknown installer result admitted');
  try
    ClassifyRelayEntry(tsPrepared, False, False);
    raise Exception.Create('Advanced state without claim accepted');
  except
    on E: ETransitionState do Check(Pos('claim is missing', E.Message) > 0, E.Message);
  end;
  try
    ClassifyRelayEntry(tsCompleted, True, True);
    raise Exception.Create('Terminal state with pending installer cleaned');
  except
    on E: ETransitionState do Check(Pos('Terminal state conflicts', E.Message) > 0, E.Message);
  end;
  WriteLn('PASS resumable states, inconsistent state and recovery routing');
end;

procedure TestCleanup(const Root: UnicodeString);
var
  Scheduler: TFixtureScheduler;
  Data: TStringList;
  Name: string;
begin
  Name := UTF8Encode(Root + '\recovery-fixture.txt');
  Data := TStringList.Create;
  Scheduler := TFixtureScheduler.Create;
  try
    Data.Text := 'preserve recovery data';
    Data.SaveToFile(Name);
    EnsureRelay(Scheduler, Root, Id, True);
    Check(ClassifyRelayEntry(tsAborted, True, False) = reaCleanup, 'Terminal cleanup denied');
    try
      RetireRelay(Scheduler, Root, OtherId, True);
      raise Exception.Create('Another transition task was removed');
    except
      on E: ETransitionRelay do Check(Pos('foreign', E.Message) > 0, E.Message);
    end;
    Scheduler.FailDelete := True;
    try
      RetireRelay(Scheduler, Root, Id, True);
      raise Exception.Create('Cleanup failure was hidden');
    except
      on E: ETransitionRelay do Check(Pos('deletion refused', E.Message) > 0, E.Message);
    end;
    Check(Scheduler.Status = rtsBoot, 'Failed cleanup lost task');
    Scheduler.FailDelete := False;
    RetireRelay(Scheduler, Root, Id, True);
    RetireRelay(Scheduler, Root, Id, True);
    Check((Scheduler.Status = rtsAbsent) and (Scheduler.Deletes = 2), 'Cleanup is not idempotent');
    Data.LoadFromFile(Name);
    Check(Data[0] = 'preserve recovery data', 'Recovery data changed');
    WriteLn('PASS owned cleanup, deletion failure, retry and recovery data retention');
  finally
    Scheduler.Free;
    Data.Free;
    SysUtils.DeleteFile(Name);
  end;
end;

var
  Root: UnicodeString;
begin
  Root := ExtractFileDir(UnicodeString(ParamStr(0)));
  TestInterruptedScheduling(Root);
  TestRecovery;
  TestCleanup(Root);
end.