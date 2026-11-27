program test_transition_trust;

{$mode objfpc}{$H+}

uses Classes, SysUtils, Windows, fpjson, transitionstorage, transitionhandoff, transitionsecurity;

const
  EnginePin = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  InstallerPin = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  Components: array[0..6] of string = ('waptagent.exe', 'patchs/wapttransition.exe',
    'padit_transition_confirmation.py', 'certificates/https.pem', 'certificates/packages.pem',
    'waptagent.sha256', 'signer-policy.json');

procedure Check(Value: Boolean; const Diagnostic: string);
begin
  if not Value then raise Exception.Create(Diagnostic);
end;

procedure Put(const Path: UnicodeString; const Content: RawByteString);
var
  Handle: THandle;
  Count: DWORD;
begin
  Handle := OpenStorageFile(Path, GENERIC_WRITE, 0, CREATE_ALWAYS);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Check(WriteFile(Handle, Content[1], Length(Content), Count, nil) and
      (Count = Length(Content)), 'Cannot write trust fixture');
  finally
    CloseHandle(Handle);
  end;
end;

function Digest(const Path: UnicodeString): string;
var
  Handle: THandle;
begin
  Handle := OpenStorageFile(Path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Result := FileSHA256(Handle);
  finally
    CloseHandle(Handle);
  end;
end;

procedure ExpectBadPolicy(const Root, Diagnostic: UnicodeString);
begin
  try
    LoadTransitionSignerPolicy(Root);
    raise Exception.Create('Invalid policy accepted');
  except
    on E: ESecurityPrecheck do Check(Pos(Diagnostic, UnicodeString(E.Message)) > 0, E.Message);
  end;
end;

procedure ExpectBadPayload(const Root: UnicodeString; const Hash, Diagnostic: string);
begin
  try
    CheckStagedPayload(Root, Hash);
    raise Exception.Create('Invalid payload accepted');
  except
    on E: EHandoff do Check(Pos(Diagnostic, E.Message) > 0, E.Message);
  end;
end;

procedure TestPolicy(const Root: UnicodeString);
var
  Policy: TTransitionSignerPolicy;
  Stream: TStringStream;
begin
  ExpectBadPolicy(Root, 'unavailable');
  Stream := TStringStream.Create('{"engine_sha256":"bad","installer_sha256":"' + InstallerPin + '"}');
  try
    try
      ParseTransitionSignerPolicy(Stream);
      raise Exception.Create('Invalid fingerprints accepted');
    except
      on E: ESecurityPrecheck do Check(Pos('fingerprints', E.Message) > 0, E.Message);
    end;
  finally
    Stream.Free;
  end;
  Stream := TStringStream.Create('{"engine_sha256":"' + EnginePin +
    '","installer_sha256":"' + InstallerPin + '"}');
  try
    Policy := ParseTransitionSignerPolicy(Stream);
  finally
    Stream.Free;
  end;
  RequireAuthorizedSigner(EnginePin, Policy.EngineSignerSHA256);
  RequireAuthorizedSigner(InstallerPin, Policy.InstallerSignerSHA256);
  try
    RequireAuthorizedSigner(InstallerPin, Policy.EngineSignerSHA256);
    raise Exception.Create('Valid but unauthorized fixture signer accepted');
  except
    on E: ESecurityPrecheck do Check(Pos('not authorized', E.Message) > 0, E.Message);
  end;
  WriteLn('PASS independent policy: absent, invalid, authorized, wrong role');
end;

procedure TestPayload(const Root: UnicodeString);
var
  Manifest, Hashes: TJSONObject;
  Name: string;
  Path, Payload: UnicodeString;
  OriginalDigest, Original: string;
  I: Integer;
begin
  Payload := Root + 'payload\';
  SecureDirectory(Payload);
  SecureDirectory(Payload + 'patchs');
  SecureDirectory(Payload + 'certificates');
  Manifest := TJSONObject.Create;
  try
    Manifest.Add('schema_version', 2);
    Manifest.Add('deployable', False);
    for I := 1 to 7 do Manifest.Add('fixture' + IntToStr(I), I);
    Hashes := TJSONObject.Create;
    Manifest.Add('components_sha256', Hashes);
    for Name in Components do
    begin
      Path := Payload + UTF8Decode(StringReplace(Name, '/', '\', [rfReplaceAll]));
      Put(Path, Name);
      Hashes.Add(Name, Digest(Path));
    end;
    Original := Manifest.AsJSON;
    Put(Payload + 'transition.json', Original);
    OriginalDigest := Digest(Payload + 'transition.json');
    CheckStagedPayload(Payload, OriginalDigest);
    ExpectBadPayload(Payload, '', 'missing');
    Put(Payload + 'transition.json', Original + ' ');
    ExpectBadPayload(Payload, OriginalDigest, 'approved digest');
    Put(Payload + 'transition.json', Original);
    Put(Payload + 'padit_transition_confirmation.py', 'changed after preparation');
    ExpectBadPayload(Payload, OriginalDigest, 'component SHA256 mismatch');
    Manifest.Integers['schema_version'] := 1;
    Put(Payload + 'transition.json', Manifest.AsJSON);
    ExpectBadPayload(Payload, OriginalDigest, 'approved digest');
    ExpectBadPayload(Payload, Digest(Payload + 'transition.json'), 'Unsupported transition contract');
    WriteLn('PASS staged v2: missing digest, manifest change, component change, v1 downgrade');
  finally
    Manifest.Free;
  end;
end;

var
  Root: UnicodeString;
begin
  Root := IncludeTrailingPathDelimiter(ExtractFileDir(UnicodeString(ParamStr(0)))) + 'isolated\';
  TestPolicy(IncludeTrailingPathDelimiter(ExtractFileDir(UnicodeString(ParamStr(0)))));
  if ParamStr(1) <> '--policy-only' then
  begin
    SecureDirectory(Root);
    TestPayload(Root);
  end;
end.
