unit transitionbackup;

{$mode objfpc}{$H+}

interface

uses SysUtils, Windows, fpjson;

type
  ETransitionBackup = class(Exception);
  TBackupPaths = array of UnicodeString;

procedure AddBackupSource(var Sources: TBackupPaths; const Path: UnicodeString);
procedure RequireBackupCapacity(BackupBytes, PayloadSize, BackupFree, InstallFree: QWord;
  SharedVolume: Boolean);
procedure CheckBackupSpace(const BackupRoot, InstallDir: UnicodeString;
  const Sources: TBackupPaths; const CacheDir: UnicodeString; PayloadSize: QWord);
procedure CaptureBackup(const BackupRoot, CacheDir, DatabasePath, InstallDir: UnicodeString;
  const TransitionID: string; const Sources: TBackupPaths; InitialServiceState: DWORD;
  const ServiceName: UnicodeString);
function VerifyBackup(const BackupRoot: UnicodeString; const TransitionID: string): string;

implementation

uses Classes, jsonparser, jsonscanner, transitionstorage, transitionsecurity, transitionbackupwindows;

const
  MinFreeMargin = QWord(1024) * 1024 * 1024;

  MaxManifestSize = 64 * 1024 * 1024;
  SourceSecurity = OWNER_SECURITY_INFORMATION or GROUP_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION;

type
  TWalkBackup = class
  private
    FRoot, FCache: UnicodeString;
    FEntries: TJSONArray;
    FBytes: QWord;
    procedure Walk(const Source, Relative: UnicodeString);
  public
    constructor Create(const Root, Cache: UnicodeString; Entries: TJSONArray);
    procedure IncludeSources(const Sources: TBackupPaths);
  end;

function SecurityToSDDL(Descriptor: PSECURITY_DESCRIPTOR; Revision, Parts: DWORD;
  out Text: PWideChar; Size: PDWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertSecurityDescriptorToStringSecurityDescriptorW';

function MoreStreams(Handle: THandle; InfoClass: Integer; Buffer: Pointer; Size: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetFileInformationByHandleEx';

procedure Require(Value: Boolean; const Diagnostic: string);
begin
  if not Value then raise ETransitionBackup.Create(Diagnostic);
end;

function IsBelow(const Path, Parent: UnicodeString): Boolean;
begin
  Result := UnicodeSameText(Path, Parent) or UnicodeSameText(
    Copy(Path, 1, Length(IncludeTrailingPathDelimiter(Parent))), IncludeTrailingPathDelimiter(Parent));
end;

procedure AddBackupSource(var Sources: TBackupPaths; const Path: UnicodeString);
var
  I: Integer;
  Normal: UnicodeString;
begin
  Require((Length(Path) >= 3) and (Path[2] = ':') and (Path[3] = '\') and
    (Pos(':', Copy(Path, 3, MaxInt)) = 0), 'Backup source must be a local absolute path');
  Normal := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  Require(Length(Normal) > 2, 'Refusing to back up a volume root');
  for I := High(Sources) downto 0 do
  begin
    if IsBelow(Normal, Sources[I]) then Exit;
    if IsBelow(Sources[I], Normal) then
    begin
      Sources[I] := Sources[High(Sources)];
      SetLength(Sources, Length(Sources) - 1);
    end;
  end;
  SetLength(Sources, Length(Sources) + 1);
  Sources[High(Sources)] := Normal;
end;

function RawAttributes(const Path: UnicodeString): DWORD;
begin
  Result := GetFileAttributesW(PWideChar(Path));
  if Result = INVALID_FILE_ATTRIBUTES then
    raise ETransitionBackup.Create('Backup source is missing or inaccessible');
  Require((Result and FILE_ATTRIBUTE_REPARSE_POINT) = 0, 'Reparse point in backup source');
  Require((Result and FILE_ATTRIBUTE_ENCRYPTED) = 0, 'EFS backup source is unsupported');
end;

function FileOpenForCopy(const Path: UnicodeString; Directory: Boolean): THandle;
var
  Flags, Access: DWORD;
begin
  Flags := FILE_FLAG_OPEN_REPARSE_POINT;
  Access := GENERIC_READ;
  if Directory then Flags := Flags or FILE_FLAG_BACKUP_SEMANTICS;
  Result := CreateFileW(PWideChar(Path), Access, FILE_SHARE_READ, nil,
    OPEN_EXISTING, Flags, 0);
  if Result = INVALID_HANDLE_VALUE then
    raise ETransitionBackup.Create('Backup source is inaccessible or still open for writing');
end;

function SDDL(Handle: THandle): UTF8String;
var
  Descriptor: array of Byte;
  Needed: DWORD;
  Text: PWideChar;
begin
  Needed := 0;
  GetKernelObjectSecurity(Handle, SourceSecurity, nil, 0, @Needed);
  Require(Needed > 0, 'Cannot read backup source NTFS security');
  SetLength(Descriptor, Needed);
  Require(GetKernelObjectSecurity(Handle, SourceSecurity, @Descriptor[0], Length(Descriptor), @Needed),
    'Cannot read backup source NTFS security');
  Require(SecurityToSDDL(@Descriptor[0], 1, SourceSecurity, Text, nil),
    'Cannot encode backup source NTFS security');
  try
    Result := UTF8Encode(UnicodeString(Text));
  finally
    LocalFree(HLOCAL(Text));
  end;
end;

procedure CheckStreams(Handle: THandle);
var
  Data: array[0..1023] of Byte;
  Code: DWORD;
  NameLength: DWORD;
begin
  if not MoreStreams(Handle, 7, @Data[0], SizeOf(Data)) then // FileStreamInfo
  begin
    Code := GetLastError;
    if Code = ERROR_HANDLE_EOF then Exit;
    raise ETransitionBackup.Create('Cannot verify NTFS streams of backup source');
  end;
  NameLength := PDWORD(@Data[4])^;
  Require((PDWORD(@Data[0])^ = 0) and (NameLength = 14) and
    CompareMem(@Data[24], PWideChar(UnicodeString('::$DATA')), NameLength),
    'Alternate NTFS data streams are unsupported');
end;

function FileClock(const Value: TFileTime): QWord;
begin
  Result := (QWord(Value.dwHighDateTime) shl 32) or Value.dwLowDateTime;
end;

procedure CopyFileData(Source: THandle; const Path: UnicodeString;
  const Info: TByHandleFileInformation; Entry: TJSONObject);
var
  Destination: THandle;
  ReadCount, Written: DWORD;
  Buffer: array[0..65535] of Byte;
  Digest: string;
  Total: QWord;
begin
  Require(Info.nNumberOfLinks = 1, 'NTFS hard links in backup source are unsupported');
  CheckStreams(Source);
  Digest := FileSHA256(Source);
  Require(SetFilePointer(Source, 0, nil, FILE_BEGIN) = 0, 'Cannot rewind backup source');
  Destination := OpenStorageFile(Path, GENERIC_READ or GENERIC_WRITE, 0, CREATE_NEW);
  Require(Destination <> INVALID_HANDLE_VALUE, 'Cannot create protected backup file');
  try
    Total := 0;
    repeat
      Require(ReadFile(Source, Buffer[0], SizeOf(Buffer), ReadCount, nil), 'Backup source read failed');
      if ReadCount = 0 then Break;
      Require(WriteFile(Destination, Buffer[0], ReadCount, Written, nil) and (Written = ReadCount),
        'Incomplete backup write or insufficient disk space');
      Inc(Total, Written);
    until False;
    Require(Total = ((QWord(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow),
      'Backup source size changed while copying');
    Require(FlushFileBuffers(Destination), 'Cannot flush backup file');
    Require(FileSHA256(Destination) = Digest, 'Backup copy SHA256 differs from source');
    Entry.Add('size', Total);
    Entry.Add('sha256', Digest);
  finally
    CloseHandle(Destination);
  end;
end;

constructor TWalkBackup.Create(const Root, Cache: UnicodeString; Entries: TJSONArray);
begin
  inherited Create;
  FRoot := IncludeTrailingPathDelimiter(Root);
  FCache := ExcludeTrailingPathDelimiter(ExpandFileName(Cache));
  FEntries := Entries;
end;

procedure TWalkBackup.Walk(const Source, Relative: UnicodeString);
var
  Attributes, Code: DWORD;
  Directory: Boolean;
  SourceHandle, Search: THandle;
  FileInfo: TByHandleFileInformation;
  SizeInfo: TWin32FileAttributeData;
  Info: TWin32FindDataW;
  Name: UnicodeString;
  Entry: TJSONObject;
begin
  if UnicodeSameText(Source, FCache) then Exit;
  Attributes := RawAttributes(Source);
  Directory := (Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0;
  SourceHandle := INVALID_HANDLE_VALUE;
  try
    if FEntries <> nil then
    begin
      SourceHandle := FileOpenForCopy(Source, Directory);
      Require(GetFileInformationByHandle(SourceHandle, FileInfo) and
        ((FileInfo.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_ENCRYPTED)) = 0) and
        (((FileInfo.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) = Directory),
        'Backup source changed or is unsafe');
      Entry := TJSONObject.Create;
      FEntries.Add(Entry);
      Entry.Add('source', UTF8Encode(Source));
      Entry.Add('backup', UTF8Encode(Relative));
      Entry.Add('directory', Directory);
      Entry.Add('attributes', FileInfo.dwFileAttributes);
      Entry.Add('created', FileClock(FileInfo.ftCreationTime));
      Entry.Add('accessed', FileClock(FileInfo.ftLastAccessTime));
      Entry.Add('written', FileClock(FileInfo.ftLastWriteTime));
      Entry.Add('sddl', SDDL(SourceHandle));
      if Directory then SecureDirectory(FRoot + Relative)
      else CopyFileData(SourceHandle, FRoot + Relative, FileInfo, Entry);
    end;
    if not Directory then
    begin
      if FEntries = nil then
      begin
        Require(GetFileAttributesExW(PWideChar(Source), GetFileExInfoStandard, @SizeInfo),
          'Cannot determine backup source size');
        Inc(FBytes, (QWord(SizeInfo.nFileSizeHigh) shl 32) or SizeInfo.nFileSizeLow);
        Inc(FBytes, 8192); // allocation and manifest overhead
      end;
      Exit;
    end;

    Search := FindFirstFileW(PWideChar(IncludeTrailingPathDelimiter(Source) + '*'), Info);
    if Search = INVALID_HANDLE_VALUE then
    begin
      Code := GetLastError;
      if Code = ERROR_FILE_NOT_FOUND then Exit;
      raise ETransitionBackup.Create('Cannot enumerate backup source directory');
    end;
    try
      repeat
        Name := PWideChar(@Info.cFileName[0]);
        if (Name = '.') or (Name = '..') then Continue;
        Walk(IncludeTrailingPathDelimiter(Source) + Name, Relative + '\' + Name);
      until not FindNextFileW(Search, Info);
      Require(GetLastError = ERROR_NO_MORE_FILES, 'Backup directory enumeration failed');
    finally
      Windows.FindClose(Search);
    end;
  finally
    if SourceHandle <> INVALID_HANDLE_VALUE then CloseHandle(SourceHandle);
  end;
end;

procedure TWalkBackup.IncludeSources(const Sources: TBackupPaths);
var
  I: Integer;
begin
  Require(Length(Sources) > 0, 'No backup sources');
  for I := Low(Sources) to High(Sources) do
  begin
    Require(not IsBelow(FRoot, Sources[I]) and not IsBelow(Sources[I], FRoot),
      'Backup source overlaps protected storage');
    CheckLocalPath(Sources[I]);
    Walk(Sources[I], 'agent\' + UnicodeString(IntToStr(I + 1)));
  end;
end;

procedure RequireBackupCapacity(BackupBytes, PayloadSize, BackupFree, InstallFree: QWord;
  SharedVolume: Boolean);
begin
  Require((BackupFree >= MinFreeMargin) and (BackupBytes <= BackupFree - MinFreeMargin),
    'Insufficient disk space on backup volume');
  if SharedVolume then InstallFree := BackupFree - BackupBytes;
  Require((InstallFree >= MinFreeMargin) and (PayloadSize <= InstallFree - MinFreeMargin) and
    (BackupBytes <= InstallFree - MinFreeMargin - PayloadSize),
    'Insufficient disk space on installation volume');
end;

procedure CheckBackupSpace(const BackupRoot, InstallDir: UnicodeString;
  const Sources: TBackupPaths; const CacheDir: UnicodeString; PayloadSize: QWord);
var
  Walk: TWalkBackup;
  BackupFree, InstallFree, Total: Int64;
  BackupVolume, InstallVolume: array[0..MAX_PATH] of WideChar;
begin
  Walk := TWalkBackup.Create(BackupRoot, CacheDir, nil);
  try
    Walk.IncludeSources(Sources);
    Require(GetVolumePathNameW(PWideChar(BackupRoot), @BackupVolume[0], Length(BackupVolume)) and
      GetVolumePathNameW(PWideChar(InstallDir), @InstallVolume[0], Length(InstallVolume)) and
      GetDiskFreeSpaceExW(PWideChar(BackupRoot), BackupFree, Total, nil) and
      GetDiskFreeSpaceExW(PWideChar(InstallDir), InstallFree, Total, nil) and
      (BackupFree >= 0) and (InstallFree >= 0), 'Cannot determine transition volume free space');
    RequireBackupCapacity(Walk.FBytes, PayloadSize, QWord(BackupFree), QWord(InstallFree),
      UnicodeSameText(PWideChar(@BackupVolume[0]), PWideChar(@InstallVolume[0])));
  finally
    Walk.Free;
  end;
end;

function LockDatabase(const Path: UnicodeString): THandle;
var
  Header: array[0..19] of Byte;
  Count, Code: DWORD;
  Suffix: UnicodeString;
const
  Sidecars: array[0..2] of UnicodeString = ('-journal', '-wal', '-shm');
begin
  CheckLocalPath(Path);
  Result := FileOpenForCopy(Path, False);
  try
    Require(ReadFile(Result, Header[0], SizeOf(Header), Count, nil) and
      (Count = SizeOf(Header)) and CompareMem(@Header[0], PAnsiChar('SQLite format 3'#0), 16) and
      (Header[18] = 1) and (Header[19] = 1), 'SQLite backup requires a rollback-journal database');
    for Suffix in Sidecars do
    begin
      Require(GetFileAttributesW(PWideChar(Path + Suffix)) = INVALID_FILE_ATTRIBUTES,
        'SQLite sidecar present after quiescing the agent');
      Code := GetLastError;
      Require(Code = ERROR_FILE_NOT_FOUND, 'Cannot verify SQLite sidecar absence');
    end;
  except
    CloseHandle(Result);
    raise;
  end;
end;

function ProtectedStream(const Path: UnicodeString; Access, Disposition: DWORD;
  out Handle: THandle): THandleStream;
begin
  Handle := OpenStorageFile(Path, Access, FILE_SHARE_READ, Disposition);
  Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot open protected backup data');
  try
    Result := THandleStream.Create(Handle);
  except
    CloseHandle(Handle);
    raise;
  end;
end;

procedure WriteManifest(const Root: UnicodeString; Data: TJSONObject);
var
  Handle: THandle;
  Stream: THandleStream;
  Payload: UTF8String;
begin
  Payload := Data.FormatJSON + #10;
  Require(Length(Payload) <= MaxManifestSize, 'Backup manifest exceeds limit');
  Stream := ProtectedStream(Root + 'manifest.tmp', GENERIC_WRITE, CREATE_NEW, Handle);
  try
    Stream.WriteBuffer(Payload[1], Length(Payload));
    Require(FlushFileBuffers(Handle), 'Cannot flush backup manifest');
  finally
    Stream.Free;
    CloseHandle(Handle);
  end;
  Require(MoveFileExW(PWideChar(Root + 'manifest.tmp'), PWideChar(Root + 'manifest.json'), 8),
    'Cannot publish protected backup manifest'); // MOVEFILE_WRITE_THROUGH, no replacement
end;

procedure CaptureBackup(const BackupRoot, CacheDir, DatabasePath, InstallDir: UnicodeString;
  const TransitionID: string; const Sources: TBackupPaths; InitialServiceState: DWORD;
  const ServiceName: UnicodeString);
var
  Root: UnicodeString;
  Data: TJSONObject;
  Entries: TJSONArray;
  Walk: TWalkBackup;
  Database: THandle;
  SourcePath: UnicodeString;
  DatabaseCovered: Boolean;
begin
  Root := IncludeTrailingPathDelimiter(BackupRoot);
  CheckStorageTree(Root);
  Require(not DirectoryHasEntries(Root), 'A previous backup exists and will be preserved');
  DatabaseCovered := False;
  for SourcePath in Sources do
    if IsBelow(DatabasePath, SourcePath) then DatabaseCovered := True;
  Require(DatabaseCovered and not IsBelow(DatabasePath, CacheDir),
    'SQLite database is absent from backup scope');
  Database := LockDatabase(DatabasePath);
  try
    SecureDirectory(Root + 'agent');
    SecureDirectory(Root + 'registry');
    SecureDirectory(Root + 'services');
    SecureDirectory(Root + 'tasks');
    Data := TJSONObject.Create;
    try
      Data.Add('schema_version', 1);
      Data.Add('transition_id', TransitionID);
      Data.Add('service_initial_state', InitialServiceState);
      Entries := TJSONArray.Create;
      Data.Add('entries', Entries);
      Walk := TWalkBackup.Create(Root, CacheDir, Entries);
      try
        Walk.IncludeSources(Sources);
      finally
        Walk.Free;
      end;
      if ServiceName <> '' then
        CaptureWaptWindowsMetadata(Root, InstallDir, ServiceName, Entries);
      WriteManifest(Root, Data);
    finally
      Data.Free;
    end;
  finally
    CloseHandle(Database);
  end;
end;

function SafeRelative(const Path: UnicodeString): Boolean;
var
  Part: UnicodeString;
  I, Start: Integer;
begin
  Result := False;
  if (Path = '') or (Path[1] = '\') or (Pos(':', Path) > 0) or (Pos('/', Path) > 0) or
    (Pos(#0, Path) > 0) then Exit;
  Start := 1;
  for I := 1 to Length(Path) + 1 do
    if (I > Length(Path)) or (Path[I] = '\') then
    begin
      Part := Copy(Path, Start, I - Start);
      if (Part = '') or (Part = '.') or (Part = '..') or (Part[Length(Part)] in ['.', ' ']) then Exit;
      Start := I + 1;
    end;
  Result := True;
end;

function ManifestField(Entry: TJSONObject; const Name: string; Kind: TJSONtype): TJSONData;
begin
  Result := Entry.Find(Name, Kind);
  Require(Result <> nil, 'Invalid backup manifest field ' + Name);
end;

procedure VerifyEntries(const Root: UnicodeString; Entries: TJSONArray; Paths: TStrings);
var
  Item: TJSONData;
  Entry: TJSONObject;
  Relative, LocalPath: UnicodeString;
  Handle: THandle;
  Info: TByHandleFileInformation;
  I: Integer;
  ExpectedSize: QWord;
  Hash: string;
  Source: UTF8String;
begin
  Require(Entries.Count > 0, 'Backup manifest contains no entries');
  for I := 0 to Entries.Count - 1 do
  begin
    Item := Entries.Items[I];
    Require(Item is TJSONObject, 'Invalid backup manifest entry');
    Entry := TJSONObject(Item);
    Relative := UTF8Decode(ManifestField(Entry, 'backup', jtString).AsString);
    Require(SafeRelative(Relative) and (Paths.IndexOf(UTF8Encode(UnicodeLowerCase(Relative))) < 0),
      'Unsafe or duplicate backup path');
    Paths.Add(UTF8Encode(UnicodeLowerCase(Relative)));
    LocalPath := Root + Relative;
    Source := ManifestField(Entry, 'source', jtString).AsString;
    Require(Source <> '', 'Backup source reference missing');
    if Entry.Find('artifact', jtString) = nil then
    begin
      ManifestField(Entry, 'attributes', jtNumber);
      ManifestField(Entry, 'created', jtNumber);
      ManifestField(Entry, 'accessed', jtNumber);
      ManifestField(Entry, 'written', jtNumber);
      Require(ManifestField(Entry, 'sddl', jtString).AsString <> '', 'Backup ACL metadata is missing');
    end;
    if ManifestField(Entry, 'directory', jtBoolean).AsBoolean then
    begin
      Require(DirectoryExists(LocalPath), 'Backup directory is missing');
      Continue;
    end;
    Handle := OpenStorageFile(LocalPath, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
    Require(Handle <> INVALID_HANDLE_VALUE, 'Backup file is missing or inaccessible');
    try
      Require(TryStrToQWord(ManifestField(Entry, 'size', jtNumber).AsJSON, ExpectedSize) and
        GetFileInformationByHandle(Handle, Info) and
        (((QWord(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow) = ExpectedSize),
        'Backup file size does not match manifest');
      Hash := ManifestField(Entry, 'sha256', jtString).AsString;
      Require(FileSHA256(Handle) = Hash, 'Backup file SHA256 does not match manifest');
    finally
      CloseHandle(Handle);
    end;
  end;
end;

procedure VerifyInventory(const Root, Relative: UnicodeString; Paths: TStrings);
var
  Search: THandle;
  Info: TWin32FindDataW;
  Name, Child: UnicodeString;
  Code: DWORD;
  Unlisted: Boolean;
begin
  Search := FindFirstFileW(PWideChar(Root + Relative + '*'), Info);
  if Search = INVALID_HANDLE_VALUE then
  begin
    Code := GetLastError;
    if Code = ERROR_FILE_NOT_FOUND then Exit;
    raise ETransitionBackup.Create('Cannot enumerate protected backup');
  end;
  try
    repeat
      Name := PWideChar(@Info.cFileName[0]);
      if (Name = '.') or (Name = '..') then Continue;
      Child := Relative + Name;
      if (Relative = '') and ((Name = 'manifest.json') or (Name = 'agent') or
        (Name = 'registry') or (Name = 'services') or (Name = 'tasks')) then Unlisted := False
      else Unlisted := Paths.IndexOf(UTF8Encode(UnicodeLowerCase(Child))) < 0;
      Require(not Unlisted, 'Unlisted object in protected backup');
      if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        VerifyInventory(Root, Child + '\', Paths);
    until not FindNextFileW(Search, Info);
    Require(GetLastError = ERROR_NO_MORE_FILES, 'Cannot enumerate protected backup');
  finally
    Windows.FindClose(Search);
  end;
end;

function VerifyBackup(const BackupRoot: UnicodeString; const TransitionID: string): string;
var
  Root: UnicodeString;
  Handle: THandle;
  Stream: THandleStream;
  Parser: TJSONParser;
  Data: TJSONData;
  Manifest: TJSONObject;
  Paths: TStringList;
begin
  Root := IncludeTrailingPathDelimiter(BackupRoot);
  CheckStorageTree(Root);
  Require(DirectoryExists(Root + 'agent') and DirectoryExists(Root + 'registry') and
    DirectoryExists(Root + 'services') and DirectoryExists(Root + 'tasks'),
    'Missing protected backup directory');
  Stream := ProtectedStream(Root + 'manifest.json', GENERIC_READ, OPEN_EXISTING, Handle);
  try
    Require((Stream.Size > 0) and (Stream.Size <= MaxManifestSize), 'Invalid backup manifest size');
    Parser := TJSONParser.Create(Stream, [joUTF8, joStrict]);
    try
      try
        Data := Parser.Parse;
      except
        on E: Exception do raise ETransitionBackup.Create('Invalid backup manifest JSON');
      end;
      try
        Require(Data is TJSONObject, 'Invalid backup manifest');
        Manifest := TJSONObject(Data);
        Require((Manifest.Count = 4) and
          (ManifestField(Manifest, 'schema_version', jtNumber).AsJSON = '1') and
          (ManifestField(Manifest, 'transition_id', jtString).AsString = TransitionID) and
          (ManifestField(Manifest, 'service_initial_state', jtNumber).AsInteger in
            [SERVICE_RUNNING, SERVICE_STOPPED]),
          'Backup manifest version or transition does not match');
        Paths := TStringList.Create;
        try
          Paths.Sorted := True;
          VerifyEntries(Root, TJSONArray(ManifestField(Manifest, 'entries', jtArray)), Paths);
          VerifyInventory(Root, '', Paths);
        finally
          Paths.Free;
        end;
      finally
        Data.Free;
      end;
    finally
      Parser.Free;
    end;
    Result := FileSHA256(Handle);
  finally
    Stream.Free;
    CloseHandle(Handle);
  end;
end;

end.
