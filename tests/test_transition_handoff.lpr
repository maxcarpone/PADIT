program test_transition_handoff;

{$mode objfpc}{$H+}

uses Windows, SysUtils, transitionstate, transitionstorage, transitionhandoff;

procedure Check(Value: Boolean; const Detail: string);
begin
  if not Value then raise Exception.Create(Detail);
end;

procedure ExerciseRelay(const Root, DB: UnicodeString);
var
  Store: TTransitionStore;
  Startup: TStartupInfoW;
  Process: TProcessInformation;
  Created, Ended, Kernel, UserTime: TFileTime;
  Producer, Admission, Writer: THandle;
  Image, Command, Lock: UnicodeString;
  Stamp: QWord;
begin
  Store := TTransitionStore.Create(Root);
  try
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Image := ExpandFileName(UnicodeString(ParamStr(0)));
    Command := '"' + Image + '" producer';
    UniqueString(Command);
    Check(CreateProcessW(PWideChar(Image), PWideChar(Command), nil, nil, False,
      CREATE_SUSPENDED or CREATE_NO_WINDOW, nil, nil, Startup, Process), 'Cannot create fixture producer');
    try
      Check(GetProcessTimes(Process.hProcess, Created, Ended, Kernel, UserTime), 'Cannot identify fixture producer');
      Stamp := (QWord(Created.dwHighDateTime) shl 32) or Created.dwLowDateTime;
      try
        CloseHandle(OpenProducer(Process.dwProcessId, Stamp + 1, Image));
        raise Exception.Create('Reused producer PID accepted');
      except
        on E: EHandoff do Check(Pos('identity', E.Message) > 0, E.Message);
      end;
      try
        CloseHandle(OpenProducer($FFFFFFFE, Stamp, Image));
        raise Exception.Create('Missing producer PID accepted');
      except
        on E: EHandoff do Check(Pos('Cannot open', E.Message) > 0, E.Message);
      end;
      Producer := OpenProducer(Process.dwProcessId, Stamp, Image);
      try
        try
          CloseHandle(Store.AcquireFixtureHandoff(Producer, DB, 25));
          raise Exception.Create('Active producer accepted');
        except
          on E: EHandoff do Check(Pos('deadline', E.Message) > 0, E.Message);
        end;
        Check(ResumeThread(Process.hThread) <> High(DWORD), 'Cannot release fixture producer');
        WaitForProducer(Producer, 5000);
        Writer := CreateFileW(PWideChar(DB), GENERIC_WRITE, FILE_SHARE_READ,
          nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        Check(Writer <> INVALID_HANDLE_VALUE, 'Cannot simulate a concurrent SQLite writer');
        try
          try
            CloseHandle(Store.AcquireFixtureHandoff(Producer, DB, 100));
            raise Exception.Create('SQLite writer accepted');
          except
            on E: Exception do Check(Pos('still open for writing', E.Message) > 0, E.Message);
          end;
        finally
          CloseHandle(Writer);
        end;
        Lock := Store.RootDirectory + 'staging\fixture-admission.lock';
        Admission := OpenStorageFile(Lock, GENERIC_WRITE, 0, OPEN_ALWAYS);
        Check(Admission <> INVALID_HANDLE_VALUE, 'Cannot simulate a foreign WAPT task');
        try
          try
            CloseHandle(Store.AcquireFixtureHandoff(Producer, DB, 100));
            raise Exception.Create('Foreign task admitted');
          except
            on E: ETransitionState do Check(Pos('admission', E.Message) > 0, E.Message);
          end;
        finally
          CloseHandle(Admission);
        end;
        Admission := Store.AcquireFixtureHandoff(Producer, DB, 100);
        try
          Check(OpenStorageFile(Lock, GENERIC_WRITE, 0, OPEN_ALWAYS) = INVALID_HANDLE_VALUE,
            'Concurrent task entered after takeover');
        finally
          CloseHandle(Admission);
        end;
        try
          CloseHandle(Store.AcquireFixtureHandoff(Producer, DB, 100));
          raise Exception.Create('Double relay accepted');
        except
          on E: ETransitionState do Check(Pos('already taken', E.Message) > 0, E.Message);
        end;
        Check(Store.ReadState = tsPrecheck, 'Fixture handoff advanced transition state');
      finally
        CloseHandle(Producer);
      end;
    finally
      if WaitForSingleObject(Process.hProcess, 0) = WAIT_TIMEOUT then
        TerminateProcess(Process.hProcess, 1);
      CloseHandle(Process.hThread);
      CloseHandle(Process.hProcess);
    end;
  finally
    Store.Free;
  end;
end;

var
  Store: TTransitionStore;
  Snapshot: UTF8String;
begin
  try
    if ParamStr(1) = 'producer' then Exit;
    if ParamStr(1) = 'prepare' then
    begin
      ReadLn(Snapshot);
      Store := TTransitionStore.Create(UnicodeString(ParamStr(2)));
      try
        Store.PrepareFixtureHandoff(UnicodeString(ParamStr(3)), Snapshot, ParamStr(4));
      finally
        Store.Free;
      end;
    end
    else if ParamStr(1) = 'relay' then
      ExerciseRelay(UnicodeString(ParamStr(2)), UnicodeString(ParamStr(3)))
    else raise Exception.Create('Invalid fixture command');
    WriteLn('PASS ', ParamStr(1));
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      ExitCode := 1;
    end;
  end;
end.
