unit transitionhandoff;

{$mode objfpc}{$H+}

interface

uses Windows, SysUtils, transitionsecurity;

type
  EHandoff = class(Exception);
  TPayloadLocks = array[0..7] of THandle;

procedure StagePayload(const SourceDir, Destination: UnicodeString; const ManifestDigest: string);
procedure ReleasePayload(var Locks: TPayloadLocks);
procedure LockVerifiedPayload(const Directory: UnicodeString; const ApprovedDigest: string;
  out Locks: TPayloadLocks);
procedure CheckStagedPayload(const Directory: UnicodeString; const ApprovedDigest: string);
function OpenProducer(PID: DWORD; Created: QWord; const ImagePath: UnicodeString): THandle;
procedure WaitForProducer(Producer: THandle; Timeout: DWORD);

implementation

uses Classes, fpjson, jsonparser, jsonscanner, transitionstorage;

const
  Components: array[0..6] of UnicodeString = ('waptagent.exe', 'patchs/wapttransition.exe',
    'padit_transition_confirmation.py', 'certificates/https.pem', 'certificates/packages.pem',
    'waptagent.sha256', 'signer-policy.json');
  QueryLimited = $1000;

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then raise EHandoff.Create(MessageText);
end;

function FileHandle(const Path: UnicodeString; Protected: Boolean): THandle;
begin
  if Protected then Result := OpenStorageFile(Path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING)
  else
  begin
    CheckLocalPath(Path);
    Result := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT, 0);
  end;
  Require(Result <> INVALID_HANDLE_VALUE, 'Cannot open transition component');
end;

function Manifest(const Directory: UnicodeString): TJSONObject;
var
  Handle: THandle;
  Stream: THandleStream;
  Parser: TJSONParser;
  Parsed: TJSONData;
begin
  Handle := FileHandle(IncludeTrailingPathDelimiter(Directory) + 'transition.json', True);
  try
    Stream := THandleStream.Create(Handle);
    try
      Require((Stream.Size > 0) and (Stream.Size <= 65536), 'Invalid transition manifest size');
      Parser := TJSONParser.Create(Stream, [joUTF8, joStrict]);
      try
        Parsed := Parser.Parse;
        if not (Parsed is TJSONObject) then
        begin
          Parsed.Free;
          raise EHandoff.Create('Transition manifest must be an object');
        end;
        Result := TJSONObject(Parsed);
      finally
        Parser.Free;
      end;
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

function ComponentHashes(Data: TJSONObject): TJSONObject;
begin
  Require((Data.Count = 10) and (Data.Find('schema_version', jtNumber) <> nil) and
    (Data.Find('schema_version').AsJSON = '2') and (Data.Find('deployable', jtBoolean) <> nil) and
    not Data.Booleans['deployable'], 'Unsupported transition contract');
  Result := TJSONObject(Data.Find('components_sha256', jtObject));
  Require((Result <> nil) and (Result.Count = Length(Components)), 'Invalid transition component list');
end;

procedure ReleasePayload(var Locks: TPayloadLocks);
var
  I: Integer;
begin
  for I := Low(Locks) to High(Locks) do
    if Locks[I] <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(Locks[I]);
      Locks[I] := INVALID_HANDLE_VALUE;
    end;
end;

procedure LockPayload(const Directory: UnicodeString; const ApprovedDigest: string;
  out Locks: TPayloadLocks);
var
  Root, Name: UnicodeString;
  Data, Hashes: TJSONObject;
  I: Integer;
begin
  for I := Low(Locks) to High(Locks) do Locks[I] := INVALID_HANDLE_VALUE;
  Root := IncludeTrailingPathDelimiter(Directory);
  Require(ApprovedDigest <> '', 'Approved manifest digest is missing');
  try
    Locks[0] := FileHandle(Root + 'transition.json', True);
    Require(FileSHA256(Locks[0]) = ApprovedDigest, 'Staged manifest no longer matches approved digest');
    Data := Manifest(Root);
    try
      Hashes := ComponentHashes(Data);
      for I := Low(Components) to High(Components) do
      begin
        Name := Components[I];
        Locks[I + 1] := FileHandle(Root + UTF8Decode(StringReplace(UTF8Encode(Name), '/', '\', [rfReplaceAll])), True);
        Require(FileSHA256(Locks[I + 1]) = Hashes.Get(UTF8Encode(Name), ''),
          'Staged component SHA256 mismatch');
      end;
    finally
      Data.Free;
    end;
  except
    ReleasePayload(Locks);
    raise;
  end;
end;

procedure CheckStagedPayload(const Directory: UnicodeString; const ApprovedDigest: string);
var
  Locks: TPayloadLocks;
begin
  LockPayload(Directory, ApprovedDigest, Locks);
  ReleasePayload(Locks);
end;

procedure LockVerifiedPayload(const Directory: UnicodeString; const ApprovedDigest: string;
  out Locks: TPayloadLocks);
var
  Root: UnicodeString;
  Policy: TTransitionSignerPolicy;
begin
  Root := IncludeTrailingPathDelimiter(Directory);
  CheckStorageTree(Directory);
  LockPayload(Directory, ApprovedDigest, Locks);
  try
    Policy := LoadTransitionSignerPolicy(Root);
    CheckAuthenticode(Root + 'waptagent.exe', Locks[1], Policy.InstallerSignerSHA256);
    CheckAuthenticode(Root + 'patchs\wapttransition.exe', Locks[2], Policy.EngineSignerSHA256);
  except
    ReleasePayload(Locks);
    raise;
  end;
end;

procedure StagePayload(const SourceDir, Destination: UnicodeString; const ManifestDigest: string);
var
  Src, Dst, Name: UnicodeString;
  Data, Hashes: TJSONObject;

  procedure CopyVerified(const Relative: UnicodeString; const Digest: string; MaxBytes: Int64);
  var
    Source, Target: THandle;
    Input, Output: THandleStream;
    LocalName: UnicodeString;
    Info: TByHandleFileInformation;
  begin
    LocalName := UTF8Decode(StringReplace(UTF8Encode(Relative), '/', '\', [rfReplaceAll]));
    Source := FileHandle(Src + LocalName, False);
    try
      Require(GetFileInformationByHandle(Source, Info) and (Info.nNumberOfLinks = 1) and
        ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) = 0),
        'Unsafe source component handle');
      Input := THandleStream.Create(Source);
      try
        Require((Input.Size > 0) and (Input.Size <= MaxBytes), 'Invalid transition component size');
        Require(FileSHA256(Source) = Digest, 'Approved source component SHA256 differs');
        Input.Position := 0;
        Target := OpenStorageFile(Dst + LocalName, GENERIC_READ or GENERIC_WRITE, 0, CREATE_NEW);
        Require(Target <> INVALID_HANDLE_VALUE, 'Cannot create protected transition component');
        try
          Output := THandleStream.Create(Target);
          try
            Output.CopyFrom(Input, 0);
            Require(FlushFileBuffers(Target) and (FileSHA256(Target) = Digest),
              'Cannot verify copied transition component');
          finally
            Output.Free;
          end;
        finally
          CloseHandle(Target);
        end;
      finally
        Input.Free;
      end;
    finally
      CloseHandle(Source);
    end;
  end;

begin
  Src := IncludeTrailingPathDelimiter(SourceDir);
  Dst := IncludeTrailingPathDelimiter(Destination);
  Require(not DirectoryExists(Destination), 'Transition staging already exists');
  SecureDirectory(Destination);
  SecureDirectory(Dst + 'patchs');
  SecureDirectory(Dst + 'certificates');
  CopyVerified('transition.json', ManifestDigest, 65536);
  Data := Manifest(Dst);
  try
    Hashes := ComponentHashes(Data);
    for Name in Components do
      CopyVerified(Name, Hashes.Get(UTF8Encode(Name), ''), Int64(2)*1024*1024*1024);
  finally
    Data.Free;
  end;
end;

function ProducerImage(Process: THandle; Flags: DWORD; Path: PWideChar; var Size: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryFullProcessImageNameW';

function OpenProducer(PID: DWORD; Created: QWord; const ImagePath: UnicodeString): THandle;
var
  Image: UnicodeString;
  Size: DWORD;
  CreatedTime, ExitTime, KernelTime, UserTime: TFileTime;
begin
  Result := OpenProcess(SYNCHRONIZE or QueryLimited, False, PID);
  Require(Result <> 0, 'Cannot open historical producer');
  try
    Require(GetProcessTimes(Result, CreatedTime, ExitTime, KernelTime, UserTime) and
      (Created = ((QWord(CreatedTime.dwHighDateTime) shl 32) or CreatedTime.dwLowDateTime)),
      'Historical producer identity does not match');
    SetLength(Image, 32768);
    Size := Length(Image);
    Require(ProducerImage(Result, 0, PWideChar(Image), Size), 'Cannot identify historical producer image');
    SetLength(Image, Size);
    Require(UnicodeSameText(Image, ImagePath), 'Historical producer image does not match');
  except
    CloseHandle(Result);
    raise;
  end;
end;

procedure WaitForProducer(Producer: THandle; Timeout: DWORD);
begin
  Require((Timeout > 0) and (Timeout <> INFINITE), 'Historical producer wait must be bounded');
  case WaitForSingleObject(Producer, Timeout) of
    WAIT_OBJECT_0: Exit;
    WAIT_TIMEOUT: raise EHandoff.Create('Historical producer is still active at deadline');
    else raise EHandoff.Create('Cannot determine historical producer completion');
  end;
end;

end.
