program test_transition_hook;

{$mode objfpc}{$H+}

uses Windows, SysUtils, Classes, transitionstate, transitionhandoff, transitionrelay;

type
  TFixtureScheduler = class(TRelayScheduler)
    Root: string;
    Fail: Boolean;
    procedure Mark(const Name, Value: string);
    procedure RegisterNew(const Task: TRelayTask); override;
    procedure RunNow(const Name: UnicodeString); override;
    function OwnedStatus(const Task: TRelayTask): TRelayTaskStatus; override;
    procedure DisableOwned(const Task: TRelayTask); override;
    procedure DeleteOwned(const Task: TRelayTask); override;
  end;

procedure TFixtureScheduler.Mark(const Name, Value: string);
var
  Stream: TStringStream;
begin
  Stream := TStringStream.Create(Value);
  try
    Stream.SaveToFile(Root + '\' + Name);
  finally
    Stream.Free;
  end;
end;

procedure TFixtureScheduler.RegisterNew(const Task: TRelayTask);
begin
  if Fail then raise Exception.Create('fixture scheduling failure');
  if Task.AtStartup then Mark('fixture-schedule', 'boot')
  else Mark('fixture-schedule', 'immediate');
end;

procedure TFixtureScheduler.RunNow(const Name: UnicodeString);
begin
  Mark('fixture-run-request', UTF8Encode(Name));
end;

function TFixtureScheduler.OwnedStatus(const Task: TRelayTask): TRelayTaskStatus;
var
  Stream: TStringStream;
begin
  if not FileExists(Root + '\fixture-schedule') then Exit(rtsAbsent);
  Stream := TStringStream.Create('');
  try
    Stream.LoadFromFile(Root + '\fixture-schedule');
    case Stream.DataString of
      'boot': Result := rtsBoot;
      'immediate': Result := rtsImmediate;
      'disabled': Result := rtsDisabled;
    else
      raise Exception.Create('Invalid fixture schedule');
    end;
  finally
    Stream.Free;
  end;
end;

procedure TFixtureScheduler.DisableOwned(const Task: TRelayTask);
begin
  Mark('fixture-schedule', 'disabled');
end;

procedure TFixtureScheduler.DeleteOwned(const Task: TRelayTask);
begin
  if not DeleteFile(Root + '\fixture-schedule') then RaiseLastOSError;
end;

var
  Store: TTransitionStore;
  Scheduler: TFixtureScheduler;
  Snapshot: UTF8String;
  Mode: string;
begin
  try
    if (ParamCount < 2) or (ParamStr(2) = '') then raise Exception.Create('Fixture root required');
    Mode := ParamStr(1);
    Store := TTransitionStore.Create(UnicodeString(ParamStr(2)));
    try
      if Mode = 'stage' then
      begin
        StagePayload(UnicodeString(ParamStr(3)), Store.RootDirectory + 'staging\payload', ParamStr(4));
        WriteLn(UTF8Encode(Store.RootDirectory + 'staging\payload'));
      end
      else if Mode = 'record' then
      begin
        ReadLn(Snapshot);
        Store.RecordFixturePayload(Snapshot, ParamStr(3));
      end
      else if (Mode = 'program') or (Mode = '--historical-relay') then
      begin
        Scheduler := TFixtureScheduler.Create;
        try
          Scheduler.Root := ParamStr(2);
          if Mode = 'program' then
          begin
            Scheduler.Fail := ParamStr(3) = 'fail';
            WriteLn(Store.ProgramHistoricalRelay(Scheduler, ParamStr(3) = 'boot'));
          end
          else
          begin
            if Store.VerifyHistoricalRelay(ParamStr(3), Scheduler) <> reaClaim then
              raise Exception.Create('Fixture relay was already claimed or requires recovery');
            if Store.ReadState <> tsPrecheck then raise Exception.Create('Fixture crossed PRECHECK');
            WriteLn('READY FOR LOCAL ORCHESTRATOR');
          end;
        finally
          Scheduler.Free;
        end;
      end
      else
        raise Exception.Create('Invalid fixture command');
    finally
      Store.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      ExitCode := 1;
    end;
  end;
end.