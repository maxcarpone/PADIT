unit transitionrelay;

{$mode objfpc}{$H+}

interface

uses Windows, SysUtils;

type
  ETransitionRelay = class(Exception);

  TRelayTask = record
    Name, ImagePath, WorkingDirectory, Arguments, Principal: UnicodeString;
    AtStartup: Boolean;
  end;

  TRelayTaskStatus = (rtsAbsent, rtsBoot, rtsImmediate, rtsDisabled);

  TRelayScheduler = class
    procedure RegisterNew(const Task: TRelayTask); virtual; abstract;
    procedure RunNow(const Name: UnicodeString); virtual; abstract;
    function OwnedStatus(const Task: TRelayTask): TRelayTaskStatus; virtual; abstract;
    procedure DisableOwned(const Task: TRelayTask); virtual; abstract;
    procedure DeleteOwned(const Task: TRelayTask); virtual; abstract;
  end;

procedure ProgramRelay(Scheduler: TRelayScheduler; const ProtectedRoot, TransitionID: UnicodeString;
  WaptExitActive: Boolean);
procedure EnsureRelay(Scheduler: TRelayScheduler; const ProtectedRoot, TransitionID: UnicodeString;
  WaptExitActive: Boolean);
procedure RetireRelay(Scheduler: TRelayScheduler; const ProtectedRoot, TransitionID: UnicodeString;
  Remove: Boolean);
procedure RetireHistoricalRelay(const ProtectedRoot, TransitionID: UnicodeString; Remove: Boolean);
procedure ScheduleHistoricalRelay(const ProtectedRoot, TransitionID: UnicodeString;
  const ApprovedDigest: string);

implementation

uses ActiveX, ComObj, Variants, transitionprecheck, transitionhandoff,
  transitionsecurity;

const
  SystemSID = 'S-1-5-18';
  PayloadPath = 'staging\payload';
  EnginePath = 'patchs\wapttransition.exe';
  TaskCreate = 2;
  TaskLogonServiceAccount = 5;
  TaskTriggerBoot = 8;
  TaskActionExec = 0;
  TaskInstancesIgnoreNew = 2;
  TaskRunLevelHighest = 1;

type
  TWindowsRelayScheduler = class(TRelayScheduler)
  private
    Service, Folder: OleVariant;
    procedure Connect;
    function FindOwned(const Task: TRelayTask): OleVariant;
  public
    procedure RegisterNew(const Task: TRelayTask); override;
    procedure RunNow(const Name: UnicodeString); override;
    function OwnedStatus(const Task: TRelayTask): TRelayTaskStatus; override;
    procedure DisableOwned(const Task: TRelayTask); override;
    procedure DeleteOwned(const Task: TRelayTask); override;
  end;

function RelayTask(const ProtectedRoot, TransitionID: UnicodeString; AtStartup: Boolean): TRelayTask;
var
  Id: TGUID;
begin
  if not TryStringToGUID(UTF8Encode(TransitionID), Id) or (UnicodeString(GUIDToString(Id)) <> TransitionID) then
    raise ETransitionRelay.Create('Invalid relay transition identifier');
  Result.Name := 'PADIT-Transition-' + Copy(TransitionID, 2, 36);
  Result.WorkingDirectory := IncludeTrailingPathDelimiter(ProtectedRoot) + PayloadPath;
  Result.ImagePath := IncludeTrailingPathDelimiter(Result.WorkingDirectory) + EnginePath;
  Result.Arguments := '--historical-relay ' + TransitionID;
  Result.Principal := SystemSID;
  Result.AtStartup := AtStartup;
end;

procedure ProgramRelay(Scheduler: TRelayScheduler; const ProtectedRoot, TransitionID: UnicodeString;
  WaptExitActive: Boolean);
var
  Task: TRelayTask;
begin
  Task := RelayTask(ProtectedRoot, TransitionID, WaptExitActive);
  try
    Scheduler.RegisterNew(Task);
  except
    on E: Exception do
      raise ETransitionRelay.Create('Cannot register a new historical relay: ' + E.Message);
  end;
  if not Task.AtStartup then
    try
      Scheduler.RunNow(Task.Name);
    except
      on E: Exception do
        // The request may have reached the scheduler. Keep the registration for reconciliation.
        raise ETransitionRelay.Create('Historical relay launch outcome is uncertain: ' + E.Message);
    end;
end;

procedure EnsureRelay(Scheduler: TRelayScheduler; const ProtectedRoot, TransitionID: UnicodeString;
  WaptExitActive: Boolean);
begin
  case Scheduler.OwnedStatus(RelayTask(ProtectedRoot, TransitionID, WaptExitActive)) of
    rtsAbsent: ProgramRelay(Scheduler, ProtectedRoot, TransitionID, WaptExitActive);
    rtsBoot: Exit; // A previously armed boot trigger is still pending.
    rtsImmediate: raise ETransitionRelay.Create('Existing immediate relay has an uncertain launch outcome');
    rtsDisabled: raise ETransitionRelay.Create('Historical relay trigger was already consumed');
  end;
end;

procedure RetireRelay(Scheduler: TRelayScheduler; const ProtectedRoot, TransitionID: UnicodeString;
  Remove: Boolean);
var
  Task: TRelayTask;
  Status: TRelayTaskStatus;
begin
  Task := RelayTask(ProtectedRoot, TransitionID, False);
  try
    Status := Scheduler.OwnedStatus(Task);
    if Status = rtsAbsent then Exit;
    if Remove then Scheduler.DeleteOwned(Task)
    else if Status <> rtsDisabled then Scheduler.DisableOwned(Task);
  except
    on E: Exception do raise ETransitionRelay.Create('Cannot retire the historical relay: ' + E.Message);
  end;
end;

procedure TWindowsRelayScheduler.Connect;
begin
  if not VarIsEmpty(Folder) then Exit;
  Service := CreateOleObject('Schedule.Service');
  Service.Connect;
  Folder := Service.GetFolder(WideString(''));
end;

function TWindowsRelayScheduler.FindOwned(const Task: TRelayTask): OleVariant;
var
  Definition, Actions, Action, Principal: OleVariant;
  UserId: UnicodeString;
begin
  Connect;
  try
    Result := Folder.GetTask(WideString(Task.Name));
  except
    on E: EOleSysError do
      if DWORD(E.ErrorCode) = $80070002 then Exit(Unassigned) else raise;
  end;
  Definition := Result.Definition;
  Principal := Definition.Principal;
  UserId := UnicodeString(Principal.UserId);
  Actions := Definition.Actions;
  if Integer(Actions.Count) <> 1 then
    raise ETransitionRelay.Create('Unexpected actions in existing relay task');
  Action := Actions.Item[1];
  if (Integer(Action.&Type) <> TaskActionExec) or
     (Integer(Principal.LogonType) <> TaskLogonServiceAccount) or
     not (UnicodeSameText(UserId, Task.Principal) or UnicodeSameText(UserId, 'SYSTEM') or
       UnicodeSameText(UserId, 'NT AUTHORITY\SYSTEM')) or
     not UnicodeSameText(UnicodeString(Action.Path), Task.ImagePath) or
     not UnicodeSameText(UnicodeString(Action.WorkingDirectory), Task.WorkingDirectory) or
     (UnicodeString(Action.Arguments) <> Task.Arguments) then
    raise ETransitionRelay.Create('Existing task does not belong to this transition');
end;

function TWindowsRelayScheduler.OwnedStatus(const Task: TRelayTask): TRelayTaskStatus;
var
  Registered, Triggers, Trigger: OleVariant;
begin
  Registered := FindOwned(Task);
  if VarIsEmpty(Registered) then Exit(rtsAbsent);
  if not Boolean(Registered.Enabled) then Exit(rtsDisabled);
  Triggers := Registered.Definition.Triggers;
  if Integer(Triggers.Count) = 0 then Exit(rtsImmediate);
  if Integer(Triggers.Count) = 1 then
  begin
    Trigger := Triggers.Item[1];
    if (Integer(Trigger.&Type) = TaskTriggerBoot) and Boolean(Trigger.Enabled) then Exit(rtsBoot);
  end;
  raise ETransitionRelay.Create('Existing relay has an unexpected trigger');
end;

procedure TWindowsRelayScheduler.DisableOwned(const Task: TRelayTask);
var
  Registered: OleVariant;
begin
  Registered := FindOwned(Task);
  if not VarIsEmpty(Registered) then Registered.Enabled := False;
end;

procedure TWindowsRelayScheduler.DeleteOwned(const Task: TRelayTask);
begin
  if not VarIsEmpty(FindOwned(Task)) then Folder.DeleteTask(WideString(Task.Name), 0);
end;

procedure RetireHistoricalRelay(const ProtectedRoot, TransitionID: UnicodeString; Remove: Boolean);
var
  Scheduler: TWindowsRelayScheduler;
begin
  OleCheck(CoInitialize(nil));
  try
    Scheduler := TWindowsRelayScheduler.Create;
    try
      RetireRelay(Scheduler, ProtectedRoot, TransitionID, Remove);
    finally
      Scheduler.Free;
    end;
  finally
    CoUninitialize;
  end;
end;

procedure TWindowsRelayScheduler.RegisterNew(const Task: TRelayTask);
var
  Definition, Settings, Principal, Action, Trigger, Registered: OleVariant;
begin
  Connect;
  Definition := Service.NewTask(0);
  Principal := Definition.Principal;
  Principal.UserId := WideString(Task.Principal);
  Principal.LogonType := TaskLogonServiceAccount;
  Principal.RunLevel := TaskRunLevelHighest;
  Settings := Definition.Settings;
  Settings.MultipleInstances := TaskInstancesIgnoreNew;
  Settings.DisallowStartIfOnBatteries := False;
  Settings.StopIfGoingOnBatteries := False;
  Settings.ExecutionTimeLimit := WideString('PT0S');
  if Task.AtStartup then
  begin
    Trigger := Definition.Triggers.Create(TaskTriggerBoot);
    Trigger.Enabled := True;
    Settings.AllowDemandStart := False;
  end;
  // Without a trigger, immediate mode runs only on the explicit Run request.
  Action := Definition.Actions.Create(TaskActionExec);
  Action.Path := WideString(Task.ImagePath);
  Action.WorkingDirectory := WideString(Task.WorkingDirectory);
  Action.Arguments := WideString(Task.Arguments);
  Registered := Folder.RegisterTaskDefinition(WideString(Task.Name), Definition, TaskCreate,
    WideString(Task.Principal), Unassigned, TaskLogonServiceAccount, Unassigned);
end;

procedure TWindowsRelayScheduler.RunNow(const Name: UnicodeString);
var
  Registered, Running: OleVariant;
begin
  Registered := Folder.GetTask(WideString(Name));
  Running := Registered.Run(Unassigned);
end;

procedure ScheduleHistoricalRelay(const ProtectedRoot, TransitionID: UnicodeString;
  const ApprovedDigest: string);
var
  Locks: TPayloadLocks;
  Payload: UnicodeString;
  Scheduler: TWindowsRelayScheduler;
begin
  if ApprovedDigest = '' then
    raise ETransitionRelay.Create('Approved manifest digest is missing');
  Payload := IncludeTrailingPathDelimiter(ProtectedRoot) + PayloadPath;
  LockVerifiedPayload(Payload, ApprovedDigest, Locks);
  try
    OleCheck(CoInitialize(nil));
    try
      Scheduler := TWindowsRelayScheduler.Create;
      try
        EnsureRelay(Scheduler, ProtectedRoot, TransitionID, WaptExitIsActive);
      finally
        Scheduler.Free;
      end;
    finally
      CoUninitialize;
    end;
  finally
    ReleasePayload(Locks);
  end;
end;

end.
