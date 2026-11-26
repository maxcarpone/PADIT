unit transitioninstall;

{$mode objfpc}{$H+}

interface

uses Windows, SysUtils;

type
  ETransitionInstall = class(Exception);
  EInstallUncertain = class(ETransitionInstall);

const
  TransitionRestartCode = 3010;

function TransitionSetupArguments(const InstallDir, ConfigPath, PackagesDir, HTTPSCA, PackageCA,
  ServerURL, RepositoryURL: UnicodeString): UnicodeString;
procedure CheckSetupExit(Code: DWORD);

// Keep the verified installer handle open with writes and deletion denied.
function RunLockedInstaller(const Path, Arguments: UnicodeString; Timeout: DWORD): DWORD;

implementation

uses URIParser;

const
  JobBasicAccounting = 1;

type
  TJobAccounting = record
    UserTime, KernelTime, PeriodUserTime, PeriodKernelTime: Int64;
    PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses: DWORD;
  end;

function NewJob(Attributes: Pointer; Name: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'CreateJobObjectW';
function AssignJob(Job, Process: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'AssignProcessToJobObject';
function QueryJob(Job: THandle; InfoClass: Integer; Info: Pointer; Size: DWORD;
  Returned: PDWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryInformationJobObject';

function TransitionSetupArguments(const InstallDir, ConfigPath, PackagesDir, HTTPSCA, PackageCA,
  ServerURL, RepositoryURL: UnicodeString): UnicodeString;

  function Quoted(const Value: UnicodeString): UnicodeString;
  var
    C: WideChar;
  begin
    for C in Value do
      if (C < #32) or (C = '"') then raise ETransitionInstall.Create('Unsafe setup argument');
    if (Value = '') or (Value[Length(Value)] = '\') then
      raise ETransitionInstall.Create('Empty or ambiguous setup argument');
    Result := '"' + Value + '"';
  end;

  function LocalPath(const Value: UnicodeString): UnicodeString;
  begin
    if (Length(Value) <= 3) or not (Value[1] in ['A'..'Z', 'a'..'z']) or
       (Copy(Value, 2, 2) <> ':\') or (Pos(':', Copy(Value, 3, MaxInt)) <> 0) or
       not UnicodeSameText(ExpandFileName(Value), Value) then
      raise ETransitionInstall.Create('Setup requires a canonical local path');
    Result := Quoted(Value);
  end;

  function HTTPS(const Value: UnicodeString): UnicodeString;
  var
    URI: TURI;
  begin
    URI := ParseURI(UTF8Encode(Value), False);
    if (LowerCase(URI.Protocol) <> 'https') or (URI.Host = '') or (Pos('@', Value) > 0) or
      (Pos('?', Value) > 0) or (Pos('#', Value) > 0) or (Pos('\', Value) > 0) or
      (Pos(' ', Value) > 0) then raise ETransitionInstall.Create('Setup requires a credential-free HTTPS URL');
    Result := Quoted(Value);
  end;

begin
  Result := '/TRANSITION=1 /VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART /NOCLOSEAPPLICATIONS' +
    ' /RESTARTEXITCODE=' + UnicodeString(IntToStr(TransitionRestartCode)) +
    ' /DIR=' + LocalPath(InstallDir) + ' /TRANSITION_INI=' + LocalPath(ConfigPath) +
    ' /TRANSITION_PACKAGES_DIR=' + LocalPath(PackagesDir) +
    ' /verify_cert=' + LocalPath(HTTPSCA) + ' /CopyPackagesTrustedCA=' + LocalPath(PackageCA) +
    ' /wapt_server=' + HTTPS(ServerURL) + ' /repo_url=' + HTTPS(RepositoryURL);
end;

procedure CheckSetupExit(Code: DWORD);
begin
  case Code of
    0: Exit;
    8, 1641, TransitionRestartCode:
      raise EInstallUncertain.CreateFmt('Installer requires restart (exit code %d)', [Code]);
    1..7: raise ETransitionInstall.CreateFmt('Installer returned exit code %d', [Code]);
    else raise EInstallUncertain.CreateFmt('Installer returned an unknown exit code %d', [Code]);
  end;
end;

function RunLockedInstaller(const Path, Arguments: UnicodeString; Timeout: DWORD): DWORD;
var
  Job: THandle;
  Startup: TStartupInfoW;
  Process: TProcessInformation;
  Command, WorkingDir: UnicodeString;
  Deadline: QWord;
  Accounting: TJobAccounting;

  procedure RejectSuspendedProcess;
  begin
    // The primary thread has never run. No installer code has executed.
    if not TerminateProcess(Process.hProcess, 1) or
      (WaitForSingleObject(Process.hProcess, 5000) <> WAIT_OBJECT_0) then
      raise EInstallUncertain.Create('Cannot account for suspended installer process');
    raise ETransitionInstall.Create('Cannot start the installer inside its tracking job');
  end;

begin
  if (Timeout = 0) or (Pos('"', Path) > 0) then
    raise ETransitionInstall.Create('Invalid installer launch settings');
  Job := NewJob(nil, nil);
  if Job = 0 then raise ETransitionInstall.Create('Cannot create installer tracking job');
  try
    FillChar(Startup, SizeOf(Startup), 0);
    Startup.cb := SizeOf(Startup);
    Command := '"' + Path + '" ' + Arguments;
    UniqueString(Command);
    WorkingDir := ExtractFileDir(Path);
    if not CreateProcessW(PWideChar(Path), PWideChar(Command), nil, nil, False,
      CREATE_SUSPENDED or CREATE_NO_WINDOW, nil, PWideChar(WorkingDir), Startup, Process) then
      raise ETransitionInstall.CreateFmt('Cannot create installer process (%d)', [GetLastError]);
    try
      if not AssignJob(Job, Process.hProcess) then RejectSuspendedProcess;
      if ResumeThread(Process.hThread) = High(DWORD) then RejectSuspendedProcess;
      Deadline := GetTickCount64 + Timeout;
      repeat
        if not QueryJob(Job, JobBasicAccounting, @Accounting, SizeOf(Accounting), nil) then
          raise EInstallUncertain.Create('Cannot determine installer process tree status');
        if Accounting.ActiveProcesses = 0 then Break;
        if GetTickCount64 >= Deadline then
          raise EInstallUncertain.Create('Installer deadline exceeded and process tree may still be active');
        Sleep(25);
      until False;
      if not GetExitCodeProcess(Process.hProcess, @Result) then
        raise EInstallUncertain.Create('Cannot read installer exit status');
    finally
      CloseHandle(Process.hThread);
      CloseHandle(Process.hProcess);
    end;
  finally
    // Closing a job without KILL_ON_JOB_CLOSE leaves active processes alone.
    CloseHandle(Job);
  end;
end;

end.
