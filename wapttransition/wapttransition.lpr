program wapttransition;

{$mode objfpc}{$H+}
{$apptype console}

uses
  SysUtils, Windows, transitionstate, transitionprecheck;

{$R *.res}

const
  ExitUsage = 2;
  MaxExecutablePath = 32768;

function FileVersion: string;
var
  Executable: UnicodeString;
  Info: array of Byte;
  PathLength, Handle, Size, ValueSize: DWORD;
  Value: Pointer;
  Version: PVSFixedFileInfo;
begin
  SetLength(Executable, MaxExecutablePath);
  PathLength := GetModuleFileNameW(0, PWideChar(Executable), Length(Executable));
  if (PathLength = 0) or (PathLength >= DWORD(Length(Executable))) then
    RaiseLastOSError;
  SetLength(Executable, PathLength);
  Handle := 0;
  Size := GetFileVersionInfoSizeW(PWideChar(Executable), Handle);
  if Size = 0 then
    RaiseLastOSError;
  Info := nil;
  SetLength(Info, Size);
  if not GetFileVersionInfoW(PWideChar(Executable), 0, Size, @Info[0]) then
    RaiseLastOSError;
  Value := nil;
  ValueSize := 0;
  if not VerQueryValueW(@Info[0], PWideChar(UnicodeString('\')), Value, ValueSize) then
    raise Exception.Create('Missing version resource');
  if ValueSize < SizeOf(TVSFixedFileInfo) then
    raise Exception.Create('Invalid version resource');
  Version := PVSFixedFileInfo(Value);
  Result := Format('%d.%d.%d.%d', [
    HiWord(Version^.dwFileVersionMS), LoWord(Version^.dwFileVersionMS),
    HiWord(Version^.dwFileVersionLS), LoWord(Version^.dwFileVersionLS)]);
end;

procedure PrintHelp;
begin
  WriteLn('PADIT Transition');
  WriteLn('Usage: wapttransition.exe --help | --version');
  WriteLn('  --help     Show this help.');
  WriteLn('  --version  Show the executable version.');
  WriteLn('Exit codes: 0 success, 1 runtime error, 2 invalid arguments.');
end;

begin
  try
    if (ParamCount = 1) and (ParamStr(1) = '--help') then
      PrintHelp
    else if (ParamCount = 1) and (ParamStr(1) = '--version') then
      WriteLn('wapttransition ', FileVersion)
    else
    begin
      if ParamCount = 1 then
        WriteLn(StdErr, 'Unknown argument: ', ParamStr(1))
      else
        WriteLn(StdErr, 'Expected exactly one argument.');
      WriteLn(StdErr, 'Usage: wapttransition.exe --help | --version');
      ExitCode := ExitUsage;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'wapttransition: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
