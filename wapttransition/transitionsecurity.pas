unit transitionsecurity;

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses SysUtils, Windows;

type
  ESecurityPrecheck = class(Exception);
  // Maintenance will take these SHA256 pins from public signer certificates
  // and provision them through trusted PADIT configuration outside the package.
  // A future policy can allow N and N-1 independently for both roles during
  // renewal. WinVerifyTrust remains required for each authorized signer.
  TTransitionSignerPolicy = record
    InstallerSignerSHA256, EngineSignerSHA256: string;
  end;

procedure CheckInstallerHash(FileHandle: THandle; const ManifestHash, Sidecar: RawByteString);
procedure CheckAuthenticode(const Path: UnicodeString; FileHandle: THandle;
  const ExpectedSignerSHA256: string);
procedure CheckHistoricalIdentity(const CertificatePath, KeyPath: UnicodeString;
  const UUID: UTF8String);
procedure CheckProbeStatus(Status: DWORD);
procedure CheckHttps(const URL: UTF8String; const TrustBundle: RawByteString);

implementation

uses Classes, JwaWinCrypt, JwaSspi, JwaWinError, JwaWinsock2, JwaWS2tcpip,
  URIParser, transitionstorage;

const
  Sha256Alg = $0000800C;
  RsaAesProvider = 24;
  Encoding = X509_ASN_ENCODING or PKCS_7_ASN_ENCODING;
  GenericVerify: TGUID = '{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}';
  TrustVerify = 1;
  TrustClose = 2;


type
  TWintrustFile = record
    Size: DWORD;
    Path: PWideChar;
    Handle: THandle;
    KnownSubject: PGUID;
  end;

  // The original WINTRUST_DATA layout is accepted on older Windows.
  TWintrustData = record
    Size: DWORD;
    PolicyCallback, SIPClient: Pointer;
    UIChoice, RevocationChecks, UnionChoice: DWORD;
    FileInfo: ^TWintrustFile;
    StateAction: DWORD;
    StateData: THandle;
    URLReference: PWideChar;
    ProviderFlags, UIContext: DWORD;
  end;

  PProviderCert = ^TProviderCert;
  TProviderCert = record
    Size: DWORD;
    Cert: PCCERT_CONTEXT;
  end;

function WinVerifyTrust(Window: HWND; const Action: TGUID; Data: Pointer): LongInt;
  stdcall; external 'wintrust.dll' name 'WinVerifyTrust';
function ProviderData(StateData: THandle): Pointer;
  stdcall; external 'wintrust.dll' name 'WTHelperProvDataFromStateData';
function ProviderSigner(Data: Pointer; Index: DWORD; CounterSigner: BOOL;
  CounterIndex: DWORD): Pointer;
  stdcall; external 'wintrust.dll' name 'WTHelperGetProvSignerFromChain';
function ProviderCert(Signer: Pointer; Index: DWORD): PProviderCert;
  stdcall; external 'wintrust.dll' name 'WTHelperGetProvCertFromChain';
function DecodeBase64(Text: PAnsiChar; TextSize, Flags: DWORD; Output: PByte;
  var OutputSize: DWORD; Skip, UsedFlags: PDWORD): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptStringToBinaryA';

procedure Require(Condition: Boolean; const Diagnostic: string);
begin
  if not Condition then raise ESecurityPrecheck.Create(Diagnostic);
end;

function IsSHA256(const Value: string): Boolean;
var
  C: Char;
begin
  if Length(Value) <> 64 then Exit(False);
  for C in Value do
    if not (C in ['0'..'9', 'a'..'f', 'A'..'F']) then Exit(False);
  Result := True;
end;

function HashHex(const Bytes: array of Byte): string;
var
  B: Byte;
begin
  Result := '';
  for B in Bytes do
    Result := Result + LowerCase(IntToHex(B, 2));
end;

function CryptoContext: HCRYPTPROV;
begin
  Result := 0;
  Require(CryptAcquireContextW(Result, nil, nil, RsaAesProvider, CRYPT_VERIFYCONTEXT),
    'Cannot open transient Windows crypto provider');
end;

function FileSHA256(FileHandle: THandle): string;
var
  Crypto: HCRYPTPROV;
  Hash: HCRYPTHASH;
  Buffer: array[0..65535] of Byte;
  Digest: array[0..31] of Byte;
  Stream: THandleStream;
  Count: Integer;
  Size: DWORD;
begin
  Crypto := CryptoContext;
  try
    Hash := 0;
    Require(CryptCreateHash(Crypto, Sha256Alg, 0, 0, Hash), 'Cannot initialize SHA256');
    try
      Stream := THandleStream.Create(FileHandle);
      try
        Stream.Position := 0;
        repeat
          Count := Stream.Read(Buffer, SizeOf(Buffer));
          Require(Count >= 0, 'Cannot read installer for SHA256');
          if Count > 0 then
            Require(CryptHashData(Hash, @Buffer[0], Count, 0), 'Cannot calculate installer SHA256');
        until Count = 0;
      finally
        Stream.Free;
      end;
      Size := SizeOf(Digest);
      Require(CryptGetHashParam(Hash, HP_HASHVAL, @Digest[0], Size, 0) and
        (Size = SizeOf(Digest)), 'Cannot read installer SHA256');
      Result := HashHex(Digest);
    finally
      CryptDestroyHash(Hash);
    end;
  finally
    CryptReleaseContext(Crypto, 0);
  end;
end;

procedure CheckInstallerHash(FileHandle: THandle; const ManifestHash, Sidecar: RawByteString);
var
  ExpectedLine: RawByteString;
begin
  Require(IsSHA256(ManifestHash), 'Invalid installer SHA256 in transition manifest');
  ExpectedLine := Copy(Sidecar, 1, 64) + '  waptagent.exe';
  Require(IsSHA256(Copy(Sidecar, 1, 64)) and
    ((Sidecar = ExpectedLine + #10) or (Sidecar = ExpectedLine + #13#10)),
    'Invalid waptagent.sha256 format');
  Require(SameText(Copy(Sidecar, 1, 64), ManifestHash),
    'Installer SHA256 differs between sidecar and manifest');
  Require(SameText(FileSHA256(FileHandle), ManifestHash), 'Installer SHA256 does not match payload');
end;

procedure CheckAuthenticode(const Path: UnicodeString; FileHandle: THandle;
  const ExpectedSignerSHA256: string);
var
  FileInfo: TWintrustFile;
  Data: TWintrustData;
  Provider, Signer: Pointer;
  Certificate: PProviderCert;
  Digest: array[0..31] of Byte;
  Size: DWORD;
  Status: LongInt;
begin
  Require(IsSHA256(ExpectedSignerSHA256), 'Expected Authenticode signer was not configured');
  FillChar(FileInfo, SizeOf(FileInfo), 0);
  FileInfo.Size := SizeOf(FileInfo);
  FileInfo.Path := PWideChar(Path);
  FileInfo.Handle := FileHandle;
  FillChar(Data, SizeOf(Data), 0);
  Data.Size := SizeOf(Data);
  Data.UIChoice := 2; // WTD_UI_NONE
  Data.RevocationChecks := 1; // WTD_REVOKE_WHOLECHAIN
  Data.UnionChoice := 1; // WTD_CHOICE_FILE
  Data.FileInfo := @FileInfo;
  Data.StateAction := TrustVerify;
  // Chain revocation (except root), cached retrieval only, reject MD2/MD4.
  Data.ProviderFlags := $80 or $1000 or $2000;
  Status := WinVerifyTrust(INVALID_HANDLE_VALUE, GenericVerify, @Data);
  try
    Require(Status = 0, 'Authenticode verification failed (0x' + IntToHex(DWORD(Status), 8) + ')');
    Provider := ProviderData(Data.StateData);
    Require(Provider <> nil, 'Authenticode signer data missing');
    Signer := ProviderSigner(Provider, 0, False, 0);
    Require(Signer <> nil, 'Authenticode signer missing');
    Certificate := ProviderCert(Signer, 0);
    Require((Certificate <> nil) and (Certificate^.Cert <> nil), 'Authenticode signer certificate missing');
    Size := SizeOf(Digest);
    Require(CryptHashCertificate(0, Sha256Alg, 0, Certificate^.Cert^.pbCertEncoded,
      Certificate^.Cert^.cbCertEncoded, @Digest[0], Size) and (Size = SizeOf(Digest)),
      'Cannot hash Authenticode signer certificate');
    Require(SameText(HashHex(Digest), ExpectedSignerSHA256), 'Authenticode signer is not authorized');
  finally
    if Data.StateData <> 0 then
    begin
      Data.StateAction := TrustClose;
      WinVerifyTrust(INVALID_HANDLE_VALUE, GenericVerify, @Data);
    end;
  end;
end;

function ReadIdentityFile(const Path: UnicodeString): RawByteString;
var
  FileHandle: THandle;
  Stream: THandleStream;
begin
  CheckLocalPath(Path);
  FileHandle := CreateFileW(PWideChar(Path), GENERIC_READ, FILE_SHARE_READ,
    nil, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
  Require(FileHandle <> INVALID_HANDLE_VALUE, 'Cannot open historical identity file');
  try
    Stream := THandleStream.Create(FileHandle);
    try
      Require((Stream.Size > 0) and (Stream.Size <= 65536), 'Invalid historical identity file size');
      SetLength(Result, Stream.Size);
      Stream.ReadBuffer(Result[1], Length(Result));
    finally
      Stream.Free;
    end;
  finally
    CloseHandle(FileHandle);
  end;
end;

procedure ClearBytes(var Data: RawByteString);
begin
  if Data <> '' then FillChar(Data[1], Length(Data), 0);
  Data := '';
end;

function DecodePEM(const Text, LabelText: RawByteString; var Offset: SizeInt): RawByteString;
var
  Opening, Closing: RawByteString;
  First, Last: SizeInt;
  Size: DWORD;
begin
  Opening := '-----BEGIN ' + LabelText + '-----';
  Closing := '-----END ' + LabelText + '-----';
  First := Pos(Opening, Text, Offset);
  Require(First > 0, 'Expected PEM block is missing');
  First := First + Length(Opening);
  Last := Pos(Closing, Text, First);
  Require(Last > First, 'Incomplete PEM block');
  Size := 0;
  Require(DecodeBase64(@Text[First], Last - First, CRYPT_STRING_BASE64,
    nil, Size, nil, nil) and (Size > 0), 'Invalid PEM encoding');
  SetLength(Result, Size);
  Require(DecodeBase64(@Text[First], Last - First, CRYPT_STRING_BASE64,
    @Result[1], Size, nil, nil), 'Invalid PEM encoding');
  SetLength(Result, Size);
  Offset := Last + Length(Closing);
end;

function DecodeCertificate(const PEM: RawByteString; var Offset: SizeInt): PCCERT_CONTEXT;
var
  DER: RawByteString;
begin
  DER := DecodePEM(PEM, 'CERTIFICATE', Offset);
  Result := CertCreateCertificateContext(Encoding, @DER[1], Length(DER));
  Require(Result <> nil, 'Invalid public certificate');
end;

function GetPublicBlob(Key: HCRYPTKEY): RawByteString;
var
  Size: DWORD;
begin
  Size := 0;
  Require(CryptExportKey(Key, 0, PUBLICKEYBLOB, 0, nil, Size) and (Size > 8),
    'Cannot export historical RSA public key');
  SetLength(Result, Size);
  Require(CryptExportKey(Key, 0, PUBLICKEYBLOB, 0, @Result[1], Size),
    'Cannot export historical RSA public key');
  // Skip the BLOBHEADER, whose algorithm can differ for signing and exchange.
  Delete(Result, 1, 8);
end;

procedure CheckHistoricalIdentity(const CertificatePath, KeyPath: UnicodeString;
  const UUID: UTF8String);
var
  Certificate: PCCERT_CONTEXT;
  KeyPEM, KeyDER, PrivateBlob: RawByteString;
  Offset: SizeInt;
  Crypto: HCRYPTPROV;
  Key, PublicKey: HCRYPTKEY;
  Size: DWORD;
  CN: array[0..255] of WideChar;
  Expected: array[0..31] of Byte;
  Challenge: array[0..1023] of Byte;
begin
  Offset := 1;
  Certificate := DecodeCertificate(ReadIdentityFile(CertificatePath), Offset);
  try
    Size := CertGetNameStringW(Certificate, CERT_NAME_ATTR_TYPE, 0,
      PAnsiChar(szOID_COMMON_NAME), @CN[0], Length(CN));
    Require((Size > 1) and (Size < Length(CN)) and
      (UTF8Encode(UnicodeString(PWideChar(@CN[0]))) = UUID), 'Historical certificate CN does not match UUID');
    KeyPEM := ReadIdentityFile(KeyPath);
    try
      Offset := 1;
      // WAPT SSLPrivateKey.as_pem uses the TraditionalOpenSSL RSA format.
      KeyDER := DecodePEM(KeyPEM, 'RSA PRIVATE KEY', Offset);
      Size := 0;
      Require(CryptDecodeObject(Encoding, PKCS_RSA_PRIVATE_KEY, @KeyDER[1],
        Length(KeyDER), 0, nil, Size) and (Size > 0), 'Invalid historical RSA private key');
      SetLength(PrivateBlob, Size);
      Require(CryptDecodeObject(Encoding, PKCS_RSA_PRIVATE_KEY, @KeyDER[1],
        Length(KeyDER), 0, @PrivateBlob[1], Size), 'Invalid historical RSA private key');
      Crypto := CryptoContext;
      try
        Key := 0;
        PublicKey := 0;
        try
          Require(CryptImportKey(Crypto, @PrivateBlob[1], Size, 0, 0, Key),
            'Cannot load historical RSA private key');
          Require(CryptImportPublicKeyInfo(Crypto, Encoding,
            @Certificate^.pCertInfo^.SubjectPublicKeyInfo, PublicKey),
            'Cannot read historical certificate public key');
          Require(GetPublicBlob(Key) = GetPublicBlob(PublicKey),
            'Historical certificate and private key do not match');
          Size := SizeOf(Expected);
          Require(CryptGenRandom(Crypto, Size, @Expected[0]), 'Cannot generate historical RSA challenge');
          Move(Expected[0], Challenge[0], Size);
          Require(
            CryptEncrypt(PublicKey, 0, True, 0, @Challenge[0], Size, Length(Challenge)) and
            CryptDecrypt(Key, 0, True, 0, @Challenge[0], Size) and (Size = SizeOf(Expected)) and
            CompareMem(@Challenge[0], @Expected[0], Size),
            'Historical private key cannot perform an RSA operation');
        finally
          if PublicKey <> 0 then CryptDestroyKey(PublicKey);
          if Key <> 0 then CryptDestroyKey(Key);
        end;
      finally
        CryptReleaseContext(Crypto, 0);
      end;
    finally
      ClearBytes(PrivateBlob);
      ClearBytes(KeyDER);
      ClearBytes(KeyPEM);
    end;
  finally
    CertFreeCertificateContext(Certificate);
  end;
end;

const
  ProbeTimeout = 5000;
  MaxTLSBuffer = 128 * 1024;
  MaxHTTPHeaders = 16 * 1024;
  SchannelPackage: UnicodeString = 'Microsoft Unified Security Protocol Provider';
  ServerAuthOID: PAnsiChar = '1.3.6.1.5.5.7.3.1';
  // Flags and fields absent from the older FPC Windows declarations.
  RemoteCertContext = $53;
  ManualCertificateValidation = $08;
  NoDefaultCredentials = $10;
  TLS12Client = $800;
  CacheOnlyTrustFlags = $00000004 or $00000100 or $00001000 or $00002000;
  EnablePeerTrust = $400;

type
  TSchannelCredentials = record
    Version, CertificateCount: DWORD;
    Certificates: Pointer;
    RootStore: HCERTSTORE;
    MapperCount: DWORD;
    Mappers: Pointer;
    AlgorithmCount: DWORD;
    Algorithms: Pointer;
    Protocols, MinStrength, MaxStrength, SessionLifetime, Flags, CredentialFormat: DWORD;
  end;

  TExclusiveChainConfig = record
    Base: TCertChainEngineConfig;
    ExclusiveRoots, ExclusivePeers: HCERTSTORE;
    ExclusiveFlags: DWORD;
  end;

  TTLSStreamSizes = record
    Header, Trailer, MaximumMessage, Buffers, BlockSize: DWORD;
  end;

  TSSLPolicy = record
    Size, AuthType, Checks: DWORD;
    ServerName: PWideChar;
  end;

  PDNSLookup = ^TDNSLookup;
  TDNSLookup = record
    References: LongInt;
    Ready: THandle;
    Host, Service: AnsiString;
    Addresses: PAddrInfo;
    Status: Integer;
  end;

function Remaining(Deadline: QWord): DWORD;
var
  Ticks: QWord;
begin
  Ticks := GetTickCount64;
  Require(Ticks < Deadline, 'HTTPS deadline exceeded');
  Result := Deadline - Ticks;
end;

procedure ReleaseLookup(Lookup: PDNSLookup);
begin
  if InterlockedDecrement(Lookup^.References) <> 0 then Exit;
  if Lookup^.Addresses <> nil then FreeAddrInfo(Lookup^.Addresses);
  if Lookup^.Ready <> 0 then CloseHandle(Lookup^.Ready);
  Dispose(Lookup);
end;

function ResolveHost(Data: Pointer): PtrInt;
var
  Lookup: PDNSLookup;
  Hints: TAddrInfo;
  Winsock: TWSAData;
  Started: Boolean;
begin
  Lookup := PDNSLookup(Data);
  Started := WSAStartup($0202, Winsock) = 0;
  try
    if Started then
    begin
      FillChar(Hints, SizeOf(Hints), 0);
      Hints.ai_family := AF_UNSPEC;
      Hints.ai_socktype := SOCK_STREAM;
      Hints.ai_protocol := IPPROTO_TCP;
      Lookup^.Status := GetAddrInfo(PAnsiChar(Lookup^.Host), PAnsiChar(Lookup^.Service),
        @Hints, Lookup^.Addresses);
    end;
  finally
    SetEvent(Lookup^.Ready);
    ReleaseLookup(Lookup);
    if Started then WSACleanup;
  end;
  Result := 0;
end;

procedure WaitSocket(SocketHandle: TSocket; ForWrite: Boolean; Deadline: QWord);
var
  ReadySet, Errors: TFDSet;
  Timeout: TTimeVal;
  Milliseconds: DWORD;
  Count: Integer;
begin
  Milliseconds := Remaining(Deadline);
  Timeout.tv_sec := Milliseconds div 1000;
  Timeout.tv_usec := (Milliseconds mod 1000) * 1000;
  FD_ZERO(ReadySet);
  _FD_SET(SocketHandle, ReadySet);
  if ForWrite then
  begin
    FD_ZERO(Errors);
    _FD_SET(SocketHandle, Errors);
    Count := Select(0, nil, @ReadySet, @Errors, @Timeout);
  end
  else
    Count := Select(0, @ReadySet, nil, nil, @Timeout);
  Require(Count <> 0, 'HTTPS deadline exceeded');
  Require(Count > 0, 'HTTPS socket wait failed');
end;

function ConnectHTTPS(const Host: AnsiString; Port: Word; Deadline: QWord): TSocket;
var
  Lookup: PDNSLookup;
  Worker: TThreadID;
  Address: PAddrInfo;
  Candidate: TSocket;
  Nonblocking: u_long;
  SocketError, ErrorLength: Integer;
begin
  New(Lookup);
  Lookup^.References := 1;
  Lookup^.Addresses := nil;
  Lookup^.Status := -1;
  Lookup^.Ready := CreateEventW(nil, True, False, nil);
  try
    Require(Lookup^.Ready <> 0, 'Cannot initialize HTTPS DNS lookup');
    Lookup^.Host := Host;
    Lookup^.Service := IntToStr(Port);
    // The worker holds its own reference if DNS outlives this probe.
    InterlockedIncrement(Lookup^.References);
    Worker := BeginThread(@ResolveHost, Lookup);
    if (Worker = 0) or (Worker = TThreadID(-1)) then
    begin
      ReleaseLookup(Lookup);
      raise ESecurityPrecheck.Create('Cannot start HTTPS DNS lookup');
    end;
    CloseHandle(Worker);
    Require(WaitForSingleObject(Lookup^.Ready, Remaining(Deadline)) = WAIT_OBJECT_0,
      'HTTPS DNS lookup deadline exceeded');
    Require((Lookup^.Status = 0) and (Lookup^.Addresses <> nil), 'HTTPS DNS lookup failed');
    Address := Lookup^.Addresses;
    while Address <> nil do
    begin
      Remaining(Deadline);
      Candidate := Socket(Address^.ai_family, Address^.ai_socktype, Address^.ai_protocol);
      if Candidate <> INVALID_SOCKET then
      try
        Nonblocking := 1;
        Require(IOCtlSocket(Candidate, LongInt(FIONBIO), Nonblocking) = 0, 'Cannot configure HTTPS socket');
        if Connect(Candidate, Address^.ai_addr, Address^.ai_addrlen) = 0 then
        begin
          Result := Candidate;
          Candidate := INVALID_SOCKET;
          Exit;
        end;
        if WSAGetLastError = WSAEWOULDBLOCK then
        begin
          WaitSocket(Candidate, True, Deadline);
          ErrorLength := SizeOf(SocketError);
          if (GetSockOpt(Candidate, SOL_SOCKET, SO_ERROR, PAnsiChar(@SocketError), ErrorLength) = 0) and
             (SocketError = 0) then
          begin
            Result := Candidate;
            Candidate := INVALID_SOCKET;
            Exit;
          end;
        end;
      finally
        if Candidate <> INVALID_SOCKET then CloseSocket(Candidate);
      end;
      Address := Address^.ai_next;
    end;
    raise ESecurityPrecheck.Create('HTTPS server is inaccessible');
  finally
    ReleaseLookup(Lookup);
  end;
end;

procedure SendBytes(SocketHandle: TSocket; Bytes: PByte; Count: Integer; Deadline: QWord);
var
  Sent: Integer;
begin
  while Count > 0 do
  begin
    WaitSocket(SocketHandle, True, Deadline);
    Sent := Send(SocketHandle, Bytes^, Count, 0);
    if (Sent < 0) and (WSAGetLastError = WSAEWOULDBLOCK) then Continue;
    Require(Sent > 0, 'Cannot send HTTPS data');
    Inc(Bytes, Sent);
    Dec(Count, Sent);
  end;
end;

procedure ReceiveTLS(SocketHandle: TSocket; var Buffer: array of Byte; var Used: Integer;
  Deadline: QWord);
var
  Count: Integer;
begin
  Require(Used < Length(Buffer), 'HTTPS TLS record exceeds limit');
  repeat
    WaitSocket(SocketHandle, False, Deadline);
    Count := Recv(SocketHandle, Buffer[Used], Length(Buffer) - Used, 0);
  until (Count >= 0) or (WSAGetLastError <> WSAEWOULDBLOCK);
  Require(Count > 0, 'HTTPS TLS connection closed or read failed');
  Inc(Used, Count);
end;

procedure KeepExtra(var Buffer: array of Byte; var Used: Integer; Extra: DWORD);
begin
  Require(Extra <= DWORD(Used), 'Invalid Schannel trailing data');
  if Extra > 0 then Move(Buffer[Used - Extra], Buffer[0], Extra);
  Used := Extra;
end;

procedure InitDescriptor(var Desc: TSecBufferDesc; var Buffers: array of TSecBuffer);
begin
  FillChar(Buffers[0], Length(Buffers) * SizeOf(TSecBuffer), 0);
  Desc.ulVersion := SECBUFFER_VERSION;
  Desc.cBuffers := Length(Buffers);
  Desc.pBuffers := @Buffers[0];
end;

procedure NegotiateTLS(SocketHandle: TSocket; const Host: UnicodeString; var Cred: TCredHandle;
  var Context: TCtxtHandle; var Buffer: array of Byte; var Used: Integer; Deadline: QWord);
const
  Requests = ISC_REQ_REPLAY_DETECT or ISC_REQ_SEQUENCE_DETECT or ISC_REQ_CONFIDENTIALITY or
    ISC_REQ_STREAM or ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_EXTENDED_ERROR or ISC_REQ_USE_SUPPLIED_CREDS;
var
  Incoming: array[0..1] of TSecBuffer;
  Outgoing: array[0..0] of TSecBuffer;
  InputDesc, OutputDesc: TSecBufferDesc;
  OldContext: PCtxtHandle;
  Input: PSecBufferDesc;
  Attributes, Extra: DWORD;
  Status: SECURITY_STATUS;
begin
  OldContext := nil;
  Input := nil;
  repeat
    Remaining(Deadline);
    InitDescriptor(OutputDesc, Outgoing);
    Outgoing[0].BufferType := SECBUFFER_TOKEN;
    if OldContext <> nil then
    begin
      InitDescriptor(InputDesc, Incoming);
      Incoming[0].BufferType := SECBUFFER_TOKEN;
      Incoming[0].pvBuffer := @Buffer[0];
      Incoming[0].cbBuffer := Used;
      Input := @InputDesc;
    end;
    Status := InitializeSecurityContextW(@Cred, OldContext, PWideChar(Host),
      Requests, 0, SECURITY_NATIVE_DREP, Input, 0, @Context, @OutputDesc, Attributes, nil);
    try
      if Outgoing[0].cbBuffer > 0 then
        SendBytes(SocketHandle, Outgoing[0].pvBuffer, Outgoing[0].cbBuffer, Deadline);
    finally
      if Outgoing[0].pvBuffer <> nil then FreeContextBuffer(Outgoing[0].pvBuffer);
    end;
    Require((Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) or
      (Status = SEC_E_INCOMPLETE_MESSAGE), 'Schannel negotiation failed (0x' + IntToHex(DWORD(Status), 8) + ')');
    if Status <> SEC_E_INCOMPLETE_MESSAGE then
    begin
      Extra := 0;
      if (Input <> nil) and (Incoming[1].BufferType = SECBUFFER_EXTRA) then
        Extra := Incoming[1].cbBuffer;
      KeepExtra(Buffer, Used, Extra);
    end;
    if Status = SEC_E_OK then
    begin
      Require((Attributes and ISC_RET_CONFIDENTIALITY) <> 0, 'Schannel connection is not encrypted');
      Exit;
    end;
    OldContext := @Context;
    if (Status = SEC_E_INCOMPLETE_MESSAGE) or (Used = 0) then
      ReceiveTLS(SocketHandle, Buffer, Used, Deadline);
  until False;
end;

function IsCA(Certificate: PCCERT_CONTEXT): Boolean;
var
  Extension: PCERT_EXTENSION;
  Constraints: TCertBasicConstraints2Info;
  Size: DWORD;
begin
  Extension := CertFindExtension(szOID_BASIC_CONSTRAINTS2,
    Certificate^.pCertInfo^.cExtension, Certificate^.pCertInfo^.rgExtension);
  if Extension = nil then Exit(False);
  Size := SizeOf(Constraints);
  Require(CryptDecodeObject(Encoding, X509_BASIC_CONSTRAINTS2, Extension^.Value.pbData,
    Extension^.Value.cbData, 0, @Constraints, Size), 'Invalid HTTPS trust bundle constraints');
  Result := Constraints.fCA;
end;

procedure LoadTrust(const Bundle: RawByteString; Roots, Peers: HCERTSTORE);
var
  Offset: SizeInt;
  Certificate: PCCERT_CONTEXT;
  Store: HCERTSTORE;
begin
  Offset := 1;
  repeat
    Certificate := DecodeCertificate(Bundle, Offset);
    try
      Require(CertCompareCertificateName(Encoding, @Certificate^.pCertInfo^.Subject,
        @Certificate^.pCertInfo^.Issuer) and
        CryptVerifyCertificateSignatureEx(0, Encoding, 2, Certificate, 2, Certificate, 0, nil),
        'HTTPS trust bundle entries must be self-signed roots or approved server certificates');
      if IsCA(Certificate) then Store := Roots
      else Store := Peers;
      Require(CertAddCertificateContextToStore(Store, Certificate, CERT_STORE_ADD_USE_EXISTING, nil),
        'Cannot load isolated HTTPS trust bundle');
    finally
      CertFreeCertificateContext(Certificate);
    end;
  until Pos('-----BEGIN CERTIFICATE-----', Bundle, Offset) = 0;
end;

function ContainsCertificate(Store: HCERTSTORE; Certificate: PCCERT_CONTEXT): Boolean;
var
  Entry: PCCERT_CONTEXT;
begin
  Entry := nil;
  repeat
    Entry := CertEnumCertificatesInStore(Store, Entry);
    if Entry = nil then Exit(False);
    if (Entry^.cbCertEncoded = Certificate^.cbCertEncoded) and
       CompareMem(Entry^.pbCertEncoded, Certificate^.pbCertEncoded, Entry^.cbCertEncoded) then
    begin
      CertFreeCertificateContext(Entry);
      Exit(True);
    end;
  until False;
end;

procedure CheckServerCertificate(Leaf: PCCERT_CONTEXT; const Host: UnicodeString;
  const Bundle: RawByteString);
var
  Roots, Peers: HCERTSTORE;
  Engine: HCERTCHAINENGINE;
  Config: TExclusiveChainConfig;
  Parameters: TCertChainPara;
  Policy: TCertChainPolicyPara;
  PolicyResult: TCertChainPolicyStatus;
  SSLPolicy: TSSLPolicy;
  Chain: PCCERT_CHAIN_CONTEXT;
  SimpleChain: PCERT_SIMPLE_CHAIN;
  Anchor: PCCERT_CONTEXT;
begin
  Require(not IsCA(Leaf), 'HTTPS peer certificate must be a server certificate');
  Roots := CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, nil);
  Require(Roots <> nil, 'Cannot create isolated CA store');
  try
    Peers := CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, nil);
    Require(Peers <> nil, 'Cannot create isolated peer store');
    try
      LoadTrust(Bundle, Roots, Peers);
      FillChar(Config, SizeOf(Config), 0);
      // Use the Windows 7 layout, which already supports exclusive trust.
      Config.Base.cbSize := SizeOf(Config) - SizeOf(Config.ExclusiveFlags);
      Config.ExclusiveRoots := Roots;
      Config.ExclusivePeers := Peers;
      Require(CertCreateCertificateChainEngine(@Config.Base, Engine), 'Cannot create exclusive HTTPS chain engine');
      try
        FillChar(Parameters, SizeOf(Parameters), 0);
        Parameters.cbSize := SizeOf(Parameters);
        Parameters.RequestedUsage.Usage.cUsageIdentifier := 1;
        Parameters.RequestedUsage.Usage.rgpszUsageIdentifier := @ServerAuthOID;
        Chain := nil;
        Require(CertVerifyTimeValidity(nil, Leaf^.pCertInfo) = 0, 'HTTPS server certificate is outside its validity period');
        Require(CertGetCertificateChain(Engine, Leaf, nil, Leaf^.hCertStore, @Parameters,
          CacheOnlyTrustFlags or EnablePeerTrust, nil, @Chain), 'Cannot build isolated HTTPS trust chain');
        try
          Require((Chain <> nil) and (Chain^.cChain = 1), 'Invalid HTTPS certificate chain');
          Require(Chain^.TrustStatus.dwErrorStatus = 0, 'HTTPS certificate chain or server usage rejected (0x' +
            IntToHex(Chain^.TrustStatus.dwErrorStatus, 8) + ')');
          SimpleChain := PCERT_SIMPLE_CHAIN(PPointer(Chain^.rgpChain)^);
          Require((SimpleChain <> nil) and (SimpleChain^.cElement > 0), 'HTTPS certificate chain is empty');
          Anchor := PCERT_CHAIN_ELEMENT(PPointer(SimpleChain^.rgpElement)[SimpleChain^.cElement - 1])^.pCertContext;
          Require(ContainsCertificate(Roots, Anchor) or
            ((SimpleChain^.cElement = 1) and ContainsCertificate(Peers, Leaf)),
            'HTTPS trust anchor is absent from the transition bundle');
          FillChar(SSLPolicy, SizeOf(SSLPolicy), 0);
          SSLPolicy.Size := SizeOf(SSLPolicy);
          SSLPolicy.AuthType := 2; // AUTHTYPE_SERVER
          SSLPolicy.ServerName := PWideChar(Host);
          FillChar(Policy, SizeOf(Policy), 0);
          Policy.cbSize := SizeOf(Policy);
          Policy.pvExtraPolicyPara := @SSLPolicy;
          FillChar(PolicyResult, SizeOf(PolicyResult), 0);
          PolicyResult.cbSize := SizeOf(PolicyResult);
          Require(CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, Chain, @Policy, @PolicyResult),
            'Cannot verify HTTPS certificate policy');
          Require(PolicyResult.dwError = 0, 'HTTPS certificate DNS name or server usage rejected (0x' +
            IntToHex(PolicyResult.dwError, 8) + ')');
        finally
          if Chain <> nil then CertFreeCertificateChain(Chain);
        end;
      finally
        CertFreeCertificateChainEngine(Engine);
      end;
    finally
      CertCloseStore(Peers, 0);
    end;
  finally
    CertCloseStore(Roots, 0);
  end;
end;

procedure SendHEAD(SocketHandle: TSocket; var Context: TCtxtHandle; const Request: RawByteString;
  Deadline: QWord);
var
  Sizes: TTLSStreamSizes;
  Data: array of Byte;
  Buffers: array[0..3] of TSecBuffer;
  Desc: TSecBufferDesc;
  I: Integer;
begin
  Require(QueryContextAttributesW(@Context, SECPKG_ATTR_STREAM_SIZES, @Sizes) = SEC_E_OK,
    'Cannot query Schannel record sizes');
  Require((Length(Request) <= Sizes.MaximumMessage) and
    (QWord(Sizes.Header) + Sizes.Trailer + Length(Request) <= MaxTLSBuffer), 'HTTPS request exceeds TLS size limit');
  SetLength(Data, Sizes.Header + Length(Request) + Sizes.Trailer);
  Move(Request[1], Data[Sizes.Header], Length(Request));
  InitDescriptor(Desc, Buffers);
  Buffers[0].BufferType := SECBUFFER_STREAM_HEADER;
  Buffers[0].pvBuffer := @Data[0];
  Buffers[0].cbBuffer := Sizes.Header;
  Buffers[1].BufferType := SECBUFFER_DATA;
  Buffers[1].pvBuffer := @Data[Sizes.Header];
  Buffers[1].cbBuffer := Length(Request);
  Buffers[2].BufferType := SECBUFFER_STREAM_TRAILER;
  Buffers[2].pvBuffer := @Data[Sizes.Header + Length(Request)];
  Buffers[2].cbBuffer := Sizes.Trailer;
  Require(EncryptMessage(@Context, 0, @Desc, 0) = SEC_E_OK, 'Cannot encrypt HTTPS HEAD request');
  for I := 0 to 2 do
    SendBytes(SocketHandle, Buffers[I].pvBuffer, Buffers[I].cbBuffer, Deadline);
end;

procedure CheckProbeStatus(Status: DWORD);
begin
  Require(Status = 200, 'HTTPS probe rejected status ' + IntToStr(Status));
end;

procedure ReceiveHEAD(SocketHandle: TSocket; var Context: TCtxtHandle; var Buffer: array of Byte;
  var Used: Integer; Deadline: QWord);
var
  Desc: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  Extra, Quality: DWORD;
  Status: SECURITY_STATUS;
  Part, Headers: RawByteString;
  I, EndOfHeaders, Code: Integer;
begin
  Headers := '';
  repeat
    Remaining(Deadline);
    if Used = 0 then ReceiveTLS(SocketHandle, Buffer, Used, Deadline);
    InitDescriptor(Desc, Buffers);
    Buffers[0].BufferType := SECBUFFER_DATA;
    Buffers[0].pvBuffer := @Buffer[0];
    Buffers[0].cbBuffer := Used;
    Status := DecryptMessage(@Context, @Desc, 0, Quality);
    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      ReceiveTLS(SocketHandle, Buffer, Used, Deadline);
      Continue;
    end;
    Require(Status = SEC_E_OK, 'HTTPS response decryption failed or requested TLS renegotiation');
    Extra := 0;
    for I := 0 to High(Buffers) do
      case Buffers[I].BufferType of
        SECBUFFER_EXTRA: Extra := Buffers[I].cbBuffer;
        SECBUFFER_DATA:
          begin
            SetString(Part, PAnsiChar(Buffers[I].pvBuffer), Buffers[I].cbBuffer);
            Headers := Headers + Part;
          end;
      end;
    EndOfHeaders := Pos(#13#10#13#10, Headers);
    if EndOfHeaders > 0 then
    begin
      Require(EndOfHeaders + 3 <= MaxHTTPHeaders, 'HTTPS response headers exceed limit');
      Require(((Copy(Headers, 1, 9) = 'HTTP/1.1 ') or (Copy(Headers, 1, 9) = 'HTTP/1.0 ')) and
        (Length(Headers) >= 13) and (Headers[13] in [' ', #13]) and
        TryStrToInt(Copy(Headers, 10, 3), Code) and (Code >= 100) and (Code <= 599) and
        (IntToStr(Code) = Copy(Headers, 10, 3)), 'Invalid HTTPS response status line');
      CheckProbeStatus(Code);
      Exit;
    end;
    Require(Length(Headers) < MaxHTTPHeaders, 'HTTPS response headers exceed limit');
    KeepExtra(Buffer, Used, Extra);
  until False;
end;

procedure CheckHttps(const URL: UTF8String; const TrustBundle: RawByteString);
var
  Parts: TURI;
  Choice: TSchannelCredentials;
  Cred: TCredHandle;
  Context: TCtxtHandle;
  Expiry: TTimeStamp;
  Peer: PCCERT_CONTEXT;
  SocketHandle: TSocket;
  Winsock: TWSAData;
  Buffer: array of Byte;
  Host, HostHeader, Path: RawByteString;
  C: AnsiChar;
  Port: Word;
  Used: Integer;
  Deadline: QWord;
begin
  Require(Length(URL) <= 2048, 'HTTPS probe endpoint exceeds size limit');
  for C in URL do
    Require(C in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/', ':', '[', ']'],
      'Invalid HTTPS probe endpoint');
  Parts := ParseURI(URL, False);
  Require((Parts.Protocol = 'https') and Parts.HasAuthority and (Parts.Host <> '') and
    (Parts.Username = '') and (Parts.Password = '') and (Parts.Params = '') and
    (Parts.Bookmark = ''), 'Invalid HTTPS probe endpoint');
  Host := Parts.Host;
  if (Length(Host) > 2) and (Host[1] = '[') and (Host[Length(Host)] = ']') then
    Host := Copy(Host, 2, Length(Host) - 2);
  HostHeader := Host;
  if Pos(':', Host) > 0 then HostHeader := '[' + Host + ']';
  Path := Parts.Path + Parts.Document;
  if (Path = '') or (Path[1] <> '/') then Path := '/' + Path;
  Port := Parts.Port;
  if Port = 0 then Port := 443;
  if Port <> 443 then HostHeader := HostHeader + ':' + IntToStr(Port);
  Deadline := GetTickCount64 + ProbeTimeout;
  Require(WSAStartup($0202, Winsock) = 0, 'Cannot initialize Windows sockets');
  try
    SocketHandle := ConnectHTTPS(Host, Port, Deadline);
    try
      FillChar(Choice, SizeOf(Choice), 0);
      // Schannel supplies the TLS transport. The application enforces the
      // certificate policy below before any HTTP bytes are handed to Schannel.
      Choice.Version := 4; // SCHANNEL_CRED_VERSION
      Choice.Protocols := TLS12Client;
      Choice.Flags := ManualCertificateValidation or NoDefaultCredentials;
      Require(AcquireCredentialsHandleW(nil, PWideChar(SchannelPackage),
        SECPKG_CRED_OUTBOUND, nil, @Choice, nil, nil, @Cred, Expiry) = SEC_E_OK,
        'Cannot acquire TLS 1.2 Schannel credentials');
      try
        FillChar(Context, SizeOf(Context), 0);
        SetLength(Buffer, MaxTLSBuffer);
        Used := 0;
        try
          NegotiateTLS(SocketHandle, UnicodeString(Host), Cred, Context, Buffer, Used, Deadline);
          Peer := nil;
          Require(QueryContextAttributesW(@Context, RemoteCertContext, @Peer) = SEC_E_OK,
            'Cannot retrieve Schannel peer certificate');
          Require(Peer <> nil, 'Missing Schannel peer certificate');
          try
            CheckServerCertificate(Peer, UnicodeString(Host), TrustBundle);
          finally
            CertFreeCertificateContext(Peer);
          end;
          SendHEAD(SocketHandle, Context, 'HEAD ' + Path + ' HTTP/1.1'#13#10 +
            'Host: ' + HostHeader + #13#10'Connection: close'#13#10#13#10, Deadline);
          ReceiveHEAD(SocketHandle, Context, Buffer, Used, Deadline);
        finally
          if (Context.dwLower <> 0) or (Context.dwUpper <> 0) then DeleteSecurityContext(@Context);
        end;
      finally
        FreeCredentialsHandle(@Cred);
      end;
    finally
      CloseSocket(SocketHandle);
    end;
  finally
    WSACleanup;
  end;
end;

end.
