program test_transition_relay;

{$mode objfpc}{$H+}

uses SysUtils, transitionrelay;

const
  TransitionID = '{01234567-89AB-CDEF-0123-456789ABCDEF}';
  ProtectedRoot = 'C:\Fixture Storage\Transition\';
  ExpectedName = 'PADIT-Transition-01234567-89AB-CDEF-0123-456789ABCDEF';

type
  TFixtureScheduler = class(TRelayScheduler)
    Registered: Boolean;
    FailRegistration, FailRun: Boolean;
    Registrations, Runs: Integer;
    Task: TRelayTask;
    procedure RegisterNew(const NewTask: TRelayTask); override;
    procedure RunNow(const Name: UnicodeString); override;
  end;

procedure Check(Condition: Boolean; const Detail: string);
begin
  if not Condition then raise Exception.Create(Detail);
end;

procedure TFixtureScheduler.RegisterNew(const NewTask: TRelayTask);
begin
  Inc(Registrations);
  if Registered or FailRegistration then raise Exception.Create('fixture registration refused');
  Task := NewTask;
  Registered := True;
end;

procedure TFixtureScheduler.RunNow(const Name: UnicodeString);
begin
  Check(Registered and (Name = Task.Name), 'wrong task launched');
  Inc(Runs);
  if FailRun then raise Exception.Create('fixture transport failure');
end;

procedure ExpectFailure(Scheduler: TFixtureScheduler; const Expected: string);
begin
  try
    ProgramRelay(Scheduler, ProtectedRoot, TransitionID, False);
    raise Exception.Create('relay should have failed');
  except
    on E: ETransitionRelay do Check(Pos(Expected, E.Message) > 0, E.Message);
  end;
end;

procedure TestMode(AtStartup: Boolean);
var
  Scheduler: TFixtureScheduler;
begin
  Scheduler := TFixtureScheduler.Create;
  try
    ProgramRelay(Scheduler, ProtectedRoot, TransitionID, AtStartup);
    Check(Scheduler.Registered and (Scheduler.Registrations = 1), 'missing registration');
    Check(Scheduler.Task.AtStartup = AtStartup, 'wrong trigger');
    Check(Scheduler.Task.Name = ExpectedName, 'wrong task name');
    Check(Scheduler.Task.Principal = 'S-1-5-18', 'wrong task principal');
    Check(Scheduler.Task.WorkingDirectory = ProtectedRoot + 'staging\payload', 'wrong working directory');
    Check(Scheduler.Task.ImagePath = ProtectedRoot + 'staging\payload\patchs\wapttransition.exe',
      'wrong executable path');
    Check(Scheduler.Task.Arguments = '--historical-relay ' + TransitionID, 'wrong action arguments');
    Check(Scheduler.Runs = Ord(not AtStartup), 'wrong number of launch requests');
    ExpectFailure(Scheduler, 'Cannot register');
    Check(Scheduler.Runs = Ord(not AtStartup), 'duplicate launch requested');
    if AtStartup then WriteLn('PASS boot trigger and duplicate refusal')
    else WriteLn('PASS immediate trigger and duplicate refusal');
  finally
    Scheduler.Free;
  end;
end;

procedure TestErrors;
var
  Scheduler: TFixtureScheduler;
begin
  Scheduler := TFixtureScheduler.Create;
  try
    Scheduler.FailRegistration := True;
    ExpectFailure(Scheduler, 'Cannot register');
    Check(not Scheduler.Registered and (Scheduler.Runs = 0), 'launch requested after registration failure');
    Scheduler.FailRegistration := False;
    Scheduler.FailRun := True;
    ExpectFailure(Scheduler, 'outcome is uncertain');
    Check(Scheduler.Registered and (Scheduler.Runs = 1), 'uncertain launch lost registration');
    ExpectFailure(Scheduler, 'Cannot register');
    Check(Scheduler.Runs = 1, 'uncertain launch was retried');
    WriteLn('PASS registration failure and uncertain launch');
  finally
    Scheduler.Free;
  end;
end;

begin
  TestMode(False);
  TestMode(True);
  TestErrors;
  try
    ScheduleHistoricalRelay(ProtectedRoot, TransitionID, '');
    raise Exception.Create('real scheduler should be locked');
  except
    on E: ETransitionRelay do Check(Pos('Approved manifest digest is missing', E.Message) > 0, E.Message);
  end;
  WriteLn('PASS real scheduler locked');
end.
