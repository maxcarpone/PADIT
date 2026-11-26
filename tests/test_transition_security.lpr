program test_transition_security;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, fpjson, jsonparser, transitionstate,
  transitionsecurity, transitionprecheck;

const
  ZeroHash = '0000000000000000000000000000000000000000000000000000000000000000';

procedure RequireTest(Value: Boolean; const Diagnostic: string);
begin
  if not Value then raise Exception.Create(Diagnostic);
end;

function OpenRead(const Path: UnicodeString): THandle;
begin
  Result := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Result = INVALID_HANDLE_VALUE then RaiseLastOSError;
end;

function ReadFixture(const Path: UnicodeString): RawByteString;
var
  Handle: THandle;
  Stream: THandleStream;
begin
  Handle := OpenRead(Path);
  try
    Stream := THandleStream.Create(Handle);
    try
      SetLength(Result, Stream.Size);
      Stream.ReadBuffer(Result[1], Length(Result));
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

procedure ExpectSecurityError(const Expected: string; E: Exception);
begin
  RequireTest(Pos(Expected, E.Message) > 0, E.Message);
end;

procedure TestPayload(const Root: UnicodeString; const Version: UTF8String);
var
  Handle: THandle;
  Metadata: TLocalMetadata;
  Repo: UTF8String;
  Bundle, Sidecar: RawByteString;
begin
  Metadata.SourceURL := 'https://source.example.test';
  Metadata.TargetURL := 'https://target.example.test';
  Metadata.TargetVersion := Version;
  Handle := OpenRead(Root + '\waptagent.exe');
  try
    CheckPayload(Root, Handle, Metadata, Repo, Bundle);
    RequireTest(Repo = 'https://repo.example.test/wapt', 'Incorrect repository endpoint');
    Sidecar := ReadFixture(Root + '\waptagent.sha256');
    try
      CheckInstallerHash(Handle, ZeroHash, ZeroHash + '  waptagent.exe' + #10);
      raise Exception.Create('Invalid payload hash was accepted');
    except
      on E: ESecurityPrecheck do ExpectSecurityError('does not match payload', E);
    end;
    try
      CheckInstallerHash(Handle, ZeroHash, Sidecar);
      raise Exception.Create('Inconsistent sidecar was accepted');
    except
      on E: ESecurityPrecheck do ExpectSecurityError('differs between sidecar and manifest', E);
    end;
    Metadata.TargetVersion := '1.8.3.0';
    try
      CheckPayload(Root, Handle, Metadata, Repo, Bundle);
      raise Exception.Create('Inconsistent PE version was accepted');
    except
      on E: ELocalPrecheck do ExpectSecurityError('version does not match', E);
    end;
  finally
    CloseHandle(Handle);
  end;
end;

procedure TestIdentity(const Root: UnicodeString);
begin
  CheckHistoricalIdentity(Root + '\host.crt', Root + '\host.pem', 'fixture-id');
  try
    CheckHistoricalIdentity(Root + '\host.crt', Root + '\other.pem', 'fixture-id');
    raise Exception.Create('Unrelated key was accepted');
  except
    on E: ESecurityPrecheck do ExpectSecurityError('do not match', E);
  end;
  try
    CheckHistoricalIdentity(Root + '\host.crt', Root + '\host.pem', 'another-id');
    raise Exception.Create('Unrelated UUID was accepted');
  except
    on E: ESecurityPrecheck do ExpectSecurityError('CN does not match UUID', E);
  end;
end;

procedure TestSignature(const Path: UnicodeString; const Pin, ExpectedError: string);
var
  Handle: THandle;
begin
  Handle := OpenRead(Path);
  try
    try
      CheckAuthenticode(Path, Handle, Pin);
      RequireTest(ExpectedError = '', 'Unexpected signature acceptance');
    except
      on E: ESecurityPrecheck do
      begin
        if ExpectedError = '' then raise;
        ExpectSecurityError(ExpectedError, E);
      end;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

procedure TestStatus;
const
  Redirects: array[0..3] of DWORD = (301, 302, 307, 308);
var
  Status: DWORD;
begin
  CheckProbeStatus(200);
  for Status in Redirects do
    try
      CheckProbeStatus(Status);
      raise Exception.Create('A simulated redirect response was accepted');
    except
      on E: ESecurityPrecheck do ExpectSecurityError('rejected status', E);
    end;
end;

procedure TestGate(const Root: UnicodeString);
var
  Store: TTransitionStore;
  Policy: TTransitionSignerPolicy;
  Diagnostic: RawByteString;
begin
  Policy.InstallerSignerSHA256 := ZeroHash;
  Policy.EngineSignerSHA256 := ZeroHash;
  Store := TTransitionStore.Create(Root + '\gate');
  try
    RequireTest(Store.Initialize, 'Initial journal write failed');
    try
      Store.RunFullPrecheck(Policy);
      raise Exception.Create('Missing staged package was accepted');
    except
      on E: EOSError do ;
    end;
    RequireTest(Store.ReadState = tsPrecheckFailed, 'Failed precheck was not persisted');
    Diagnostic := ReadFixture(Store.RootDirectory + 'state.json');
    RequireTest(Pos('Cannot validate protected transition payload directory', Diagnostic) > 0,
      'Missing persistent precheck diagnostic');
    try
      Store.Advance(tsPrepared);
      raise Exception.Create('PREPARED bypass was accepted');
    except
      on E: ETransitionState do ExpectSecurityError('requires successful full prechecks', E);
    end;
  finally
    Store.Free;
  end;
end;

var
  Mode: string;
  Root: UnicodeString;
begin
  try
    Mode := ParamStr(1);
    Root := UnicodeString(ParamStr(2));
    if Mode = 'crypto' then
    begin
      TestPayload(Root, ParamStr(3));
      TestIdentity(Root);
      TestSignature(Root + '\waptagent.exe', ZeroHash, 'Authenticode verification failed');
      TestStatus;
    end
    else if Mode = 'signature' then
      TestSignature(Root, ParamStr(3), ParamStr(4))
    else if Mode = 'https' then
    begin
      try
        CheckHttps(ParamStr(3), ReadFixture(Root));
        RequireTest(ParamStr(4) = '', 'Unexpected HTTPS acceptance');
      except
        on E: ESecurityPrecheck do
        begin
          if ParamStr(4) = '' then raise;
          ExpectSecurityError(ParamStr(4), E);
        end;
      end;
    end
    else if Mode = 'gate' then
      TestGate(Root)
    else
      raise Exception.Create('Unknown security test mode');
    WriteLn('PASS ', Mode);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      ExitCode := 1;
    end;
  end;
end.
