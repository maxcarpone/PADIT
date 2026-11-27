unit transitionrestore;

{$mode objfpc}{$H+}

interface

uses Windows, SysUtils, fpjson, transitionbackup;

// The caller owns the trusted destination scope, recorded installer additions and service quiescence.
procedure RestoreVerifiedFiles(const BackupRoot, InstallDir, CacheDir: UnicodeString;
  const TransitionID, Digest: string; const Scope, InstalledFiles: TBackupPaths);
procedure CheckRestorePaths(Manifest: TJSONObject; const Scope: TBackupPaths;
  const StoreRoot, InstallDir, CacheDir: UnicodeString; const InstalledFiles: TBackupPaths);
implementation

uses Classes, transitionstorage, transitionsecurity;

const
  FileMetadata = FILE_ATTRIBUTE_READONLY or FILE_ATTRIBUTE_HIDDEN or
    FILE_ATTRIBUTE_SYSTEM or FILE_ATTRIBUTE_ARCHIVE or FILE_ATTRIBUTE_NOT_CONTENT_INDEXED;
  OwnerGroupDacl = OWNER_SECURITY_INFORMATION or GROUP_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION;

function SddlToDescriptor(Text: PWideChar; Revision: DWORD;
  out Descriptor: PSECURITY_DESCRIPTOR; Size: PDWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

type
  TFileBasicMetadata = record
    Created, Accessed, Written, Changed: Int64;
    Attributes, Padding: DWORD;
  end;

function SetFileInformation(Handle: THandle; InfoClass: Integer; Data: Pointer; Size: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetFileInformationByHandle';

procedure Require(Condition: Boolean; const Diagnostic: string);
begin
  if not Condition then raise ETransitionBackup.Create(Diagnostic);
end;

function Below(const Path, Parent: UnicodeString): Boolean;
begin
  Result := UnicodeSameText(Path, Parent) or UnicodeSameText(
    Copy(Path, 1, Length(IncludeTrailingPathDelimiter(Parent))),
    IncludeTrailingPathDelimiter(Parent));
end;

function Attributes(const Path: UnicodeString): DWORD;
begin
  Result := GetFileAttributesW(PWideChar(Path));
  if Result = INVALID_FILE_ATTRIBUTES then
    Require(GetLastError in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND],
      'Cannot inspect restoration path')
  else
    Require((Result and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_ENCRYPTED)) = 0,
      'Unsupported reparse point or encrypted restoration path');
end;

procedure ValidatePath(const Path: UnicodeString; IsDirectory: Boolean);
var
  Part: UnicodeString;
  Attr: DWORD;
begin
  Require((Length(Path) > 3) and ((Path[1] in ['A'..'Z', 'a'..'z'])) and
    (Copy(Path, 2, 2) = ':\') and UnicodeSameText(ExpandFileName(Path), Path) and
    (Pos('/', Path) = 0) and (Pos(':', Copy(Path, 3, MaxInt)) = 0),
    'Restoration path must be a canonical local drive path');
  Part := Path;
  repeat
    Require((ExtractFileName(Part) <> '') and
      not (Part[Length(Part)] in [' ', '.']) and (Pos(#0, Part) = 0),
      'Invalid restoration path component');
    Attr := Attributes(Part);
    Require((Attr = INVALID_FILE_ATTRIBUTES) or
      (((Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0) = IsDirectory),
      'Restoration path has an unexpected type');
    IsDirectory := True;
    Part := ExcludeTrailingPathDelimiter(ExtractFileDir(Part));
  until Length(Part) <= 2;
end;

function Original(Entry: TJSONObject): UnicodeString;
begin
  Result := UTF8Decode(Entry.Strings['source']);
end;

procedure CheckRestorePaths(Manifest: TJSONObject; const Scope: TBackupPaths;
  const StoreRoot, InstallDir, CacheDir: UnicodeString; const InstalledFiles: TBackupPaths);
var
  Entries: TJSONArray;
  Entry: TJSONObject;
  Path, Root, Candidate: UnicodeString;
  Found: Boolean;
  I: Integer;
  Destinations: TStringList;
  Descriptor: PSECURITY_DESCRIPTOR;
begin
  Entries := Manifest.Arrays['entries'];
  Destinations := TStringList.Create;
  try
    Destinations.Sorted := True;
    Destinations.CaseSensitive := True;
    for I := 0 to Entries.Count - 1 do
    begin
      Entry := Entries.Objects[I];
      if Entry.Find('artifact') <> nil then Continue;
      Path := Original(Entry);
      ValidatePath(Path, Entry.Booleans['directory']);
      Found := False;
      for Root in Scope do
        if Below(Path, Root) then Found := True;
      Require(Found and not Below(Path, StoreRoot) and not Below(StoreRoot, Path) and
        not Below(Path, CacheDir), 'Restoration path is outside the approved scope');
      Require(Destinations.IndexOf(UTF8Encode(UnicodeLowerCase(Path))) < 0,
        'Duplicate original restoration path');
      Destinations.Add(UTF8Encode(UnicodeLowerCase(Path)));
      Require((Entry.QWords['attributes'] and not QWord(FileMetadata or
        FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_NORMAL)) = 0,
        'Unsupported original NTFS attributes');
      Require(SddlToDescriptor(PWideChar(UTF8Decode(Entry.Strings['sddl'])), 1, Descriptor, nil),
        'Invalid original NTFS permissions');
      LocalFree(HLOCAL(Descriptor));
    end;
    for Candidate in InstalledFiles do
    begin
      ValidatePath(Candidate, False);
      Found := False;
      for Root in Scope do
        if Below(Candidate, Root) then Found := True;
      Require((Below(Candidate, InstallDir) or (Found and
        UnicodeSameText(ExtractFileName(Candidate), 'padit-transition-packages.pem'))) and
        not UnicodeSameText(Candidate, InstallDir) and
        not Below(Candidate, CacheDir) and not Below(Candidate, StoreRoot),
        'Removal is outside the installation or overlaps protected data');
      Require(Destinations.IndexOf(UTF8Encode(UnicodeLowerCase(Candidate))) < 0,
        'Removal would delete a historical object');
    end;
  finally
    Destinations.Free;
  end;
end;

procedure PinParents(const Path: UnicodeString; var Pins: TDirectoryPins);
var
  Parent: UnicodeString;
  Handle: THandle;
  Info: TByHandleFileInformation;
begin
  Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(Path));
  if Length(Parent) <= 2 then Exit;
  PinParents(Parent, Pins);
  Handle := CreateFileW(PWideChar(Parent), FILE_READ_ATTRIBUTES, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS, 0);
  Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot pin restoration parent directory');
  SetLength(Pins, Length(Pins) + 1);
  Pins[High(Pins)] := Handle;
  Require(GetFileInformationByHandle(Handle, Info) and
    ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) =
      FILE_ATTRIBUTE_DIRECTORY), 'Unsafe restoration parent directory');
end;

procedure ReleasePins(const Pins: TDirectoryPins);
var
  I: Integer;
begin
  for I := High(Pins) downto Low(Pins) do CloseHandle(Pins[I]);
end;

function Clock(Value: QWord): TFileTime;
begin
  Result.dwLowDateTime := DWORD(Value);
  Result.dwHighDateTime := DWORD(Value shr 32);
end;

procedure ApplyMetadata(FileHandle: THandle; Entry: TJSONObject);
var
  Created, Accessed, Written: TFileTime;
  Descriptor: PSECURITY_DESCRIPTOR;
  Attr, Revision, Parts: DWORD;
  Control: SECURITY_DESCRIPTOR_CONTROL;
  Info: TByHandleFileInformation;
  Basic: TFileBasicMetadata;
begin
  Created := Clock(Entry.QWords['created']);
  Accessed := Clock(Entry.QWords['accessed']);
  Written := Clock(Entry.QWords['written']);
  Require(SetFileTime(FileHandle, @Created, @Accessed, @Written), 'Cannot restore file timestamps');
  Attr := DWORD(Entry.QWords['attributes']) and FileMetadata;
  if Attr = 0 then Attr := FILE_ATTRIBUTE_NORMAL;
  FillChar(Basic, SizeOf(Basic), 0);
  Basic.Attributes := Attr;
  Require(SetFileInformation(FileHandle, 0, @Basic, SizeOf(Basic)), 'Cannot restore file attributes');
  Require(GetFileInformationByHandle(FileHandle, Info) and
    ((Info.dwFileAttributes and FileMetadata) = (Attr and FileMetadata)) and
    (CompareFileTime(@Info.ftCreationTime, @Created) = 0) and
    (CompareFileTime(@Info.ftLastAccessTime, @Accessed) = 0) and
    (CompareFileTime(@Info.ftLastWriteTime, @Written) = 0), 'Restored Windows metadata differs from manifest');
  // Reapplying an identical DACL may clear the NTFS auto-inherited flag.
  if SDDL(FileHandle) = Entry.Strings['sddl'] then Exit;
  Require(SddlToDescriptor(PWideChar(UTF8Decode(Entry.Strings['sddl'])), 1, Descriptor, nil),
    'Cannot decode original NTFS permissions');
  try
    Require(GetSecurityDescriptorControl(Descriptor, @Control, @Revision),
      'Cannot read original NTFS protection flag');
    Parts := OwnerGroupDacl;
    if (Control and $1000) <> 0 then Parts := Parts or DWORD($80000000) // protected DACL
    else Parts := Parts or DWORD($20000000); // unprotected DACL
    Require(SetKernelObjectSecurity(FileHandle, Parts, Descriptor),
      'Cannot restore original NTFS permissions');
    Require(SDDL(FileHandle) = Entry.Strings['sddl'], 'Restored NTFS permissions differ from manifest');
  finally
    LocalFree(HLOCAL(Descriptor));
  end;
end;

function OpenFileForRestoration(const Path: UnicodeString; Attr, Flags: DWORD): THandle;
const
  Access = GENERIC_READ or GENERIC_WRITE or WRITE_DAC or WRITE_OWNER;
var
  Metadata: THandle;
  Info: TByHandleFileInformation;
  Basic: TFileBasicMetadata;
  RemovedReadOnly: Boolean;
begin
  if Attr = INVALID_FILE_ATTRIBUTES then
    Exit(CreateFileW(PWideChar(Path), Access, 0, nil, CREATE_NEW, Flags, 0));
  if (Attr and FILE_ATTRIBUTE_READONLY) = 0 then
    Exit(CreateFileW(PWideChar(Path), Access, 0, nil, OPEN_EXISTING, Flags, 0));

  // Attribute-only access can coexist with the exclusive content handle.
  Metadata := CreateFileW(PWideChar(Path), FILE_READ_ATTRIBUTES or FILE_WRITE_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, Flags, 0);
  Require(Metadata <> INVALID_HANDLE_VALUE, 'Cannot open read-only restoration destination');
  RemovedReadOnly := False;
  Result := INVALID_HANDLE_VALUE;
  try
    Require(GetFileInformationByHandle(Metadata, Info) and (Info.nNumberOfLinks = 1) and
      ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY or
        FILE_ATTRIBUTE_ENCRYPTED)) = 0), 'Unsafe read-only restoration destination');
    FillChar(Basic, SizeOf(Basic), 0);
    Basic.Attributes := (Info.dwFileAttributes and FileMetadata) and not FILE_ATTRIBUTE_READONLY;
    if Basic.Attributes = 0 then Basic.Attributes := FILE_ATTRIBUTE_NORMAL;
    Require(SetFileInformation(Metadata, 0, @Basic, SizeOf(Basic)), 'Cannot clear read-only attribute');
    RemovedReadOnly := True;
    Result := CreateFileW(PWideChar(Path), Access, 0, nil, OPEN_EXISTING, Flags, 0);
  finally
    if RemovedReadOnly and (Result = INVALID_HANDLE_VALUE) then
    begin
      Basic.Attributes := Info.dwFileAttributes and FileMetadata;
      Require(SetFileInformation(Metadata, 0, @Basic, SizeOf(Basic)),
        'Cannot reinstate read-only attribute after a refused restoration');
    end;
    CloseHandle(Metadata);
  end;
end;

procedure RestoreEntry(Entry: TJSONObject; const BackupRoot: UnicodeString; DirectoryMetadata: Boolean);
var
  Pins: TDirectoryPins;
  Path: UnicodeString;
  Source, Target: THandle;
  ReadCount, Written, Attr, Flags: DWORD;
  Info: TByHandleFileInformation;
  Data: array[0..65535] of Byte;
  IsDirectory: Boolean;
begin
  Path := Original(Entry);
  IsDirectory := Entry.Booleans['directory'];
  Pins := nil;
  try
    PinParents(Path, Pins);
    Attr := Attributes(Path);
    if IsDirectory and (Attr = INVALID_FILE_ATTRIBUTES) then
      Require(CreateDirectoryW(PWideChar(Path), nil), 'Cannot create historical directory');
    if IsDirectory and not DirectoryMetadata then Exit;
    Flags := FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS;
    if IsDirectory then
      Target := CreateFileW(PWideChar(Path), GENERIC_READ or GENERIC_WRITE or WRITE_DAC or WRITE_OWNER,
        FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, Flags, 0)
    else
      Target := OpenFileForRestoration(Path, Attr, Flags);
    Require(Target <> INVALID_HANDLE_VALUE, 'Cannot open historical restoration destination');
    try
      Require(GetFileInformationByHandle(Target, Info) and
        ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_ENCRYPTED)) = 0) and
        (((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) = IsDirectory) and
        (IsDirectory or (Info.nNumberOfLinks = 1)), 'Unsafe historical restoration destination');
      if not IsDirectory then
      begin
        CheckStreams(Target);
        Source := OpenStorageFile(IncludeTrailingPathDelimiter(BackupRoot) +
          UTF8Decode(Entry.Strings['backup']), GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING);
        Require(Source <> INVALID_HANDLE_VALUE, 'Cannot read verified backup file');
        try
          Require((FileSHA256(Source) = Entry.Strings['sha256']) and
            (SetFilePointer(Source, 0, nil, FILE_BEGIN) = 0), 'Backup changed before restoration');
          repeat
            Require(ReadFile(Source, Data[0], SizeOf(Data), ReadCount, nil), 'Cannot read backup data');
            if ReadCount = 0 then Break;
            Require(WriteFile(Target, Data[0], ReadCount, Written, nil) and (Written = ReadCount),
              'Incomplete restoration write');
          until False;
          Require(SetEndOfFile(Target) and FlushFileBuffers(Target), 'Cannot flush restored file');
          Require(FileSHA256(Target) = Entry.Strings['sha256'], 'Restored file SHA256 differs from backup');
        finally
          CloseHandle(Source);
        end;
      end;
      ApplyMetadata(Target, Entry);
    finally
      CloseHandle(Target);
    end;
  finally
    ReleasePins(Pins);
  end;
end;

procedure RemoveInstalledFile(const Path: UnicodeString);
var
  Pins: TDirectoryPins;
  Handle: THandle;
  Info: TByHandleFileInformation;
  DeleteFileInfo: Byte;
begin
  Pins := nil;
  if Attributes(Path) = INVALID_FILE_ATTRIBUTES then Exit;
  try
    PinParents(Path, Pins);
    Handle := CreateFileW(PWideChar(Path), $00010000 or FILE_READ_ATTRIBUTES, 0,
      nil, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
    Require(Handle <> INVALID_HANDLE_VALUE, 'Cannot open a recorded installation addition for removal');
    try
      Require(GetFileInformationByHandle(Handle, Info) and (Info.nNumberOfLinks = 1) and
        ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) = 0),
        'Cannot remove an unsafe installation addition');
      CheckStreams(Handle);
      DeleteFileInfo := 1;
      Require(SetFileInformation(Handle, 4, @DeleteFileInfo, SizeOf(DeleteFileInfo)),
        'Cannot remove a recorded installation addition');
    finally
      CloseHandle(Handle);
    end;
  finally
    ReleasePins(Pins);
  end;
end;

procedure RestoreFiles(Manifest: TJSONObject; const BackupRoot: UnicodeString;
  const InstalledFiles: TBackupPaths);
var
  Entries: TJSONArray;
  Entry: TJSONObject;
  Path: UnicodeString;
  Token: THandle;
  Requested, OriginalPrivileges: TTokenPrivileges;
  Returned: DWORD;
  I: Integer;
begin
  Require(OpenProcessToken(GetCurrentProcess, TOKEN_ADJUST_PRIVILEGES or TOKEN_QUERY, @Token),
    'Cannot open restore privilege token');
  try
    FillChar(Requested, SizeOf(Requested), 0);
    Requested.PrivilegeCount := 1;
    Requested.Privileges[0].Attributes := SE_PRIVILEGE_ENABLED;
    Require(LookupPrivilegeValueW(nil, 'SeRestorePrivilege', @Requested.Privileges[0].Luid),
      'Cannot locate restore privilege');
    SetLastError(ERROR_SUCCESS);
    Require(AdjustTokenPrivileges(Token, False, @Requested, SizeOf(OriginalPrivileges),
      @OriginalPrivileges, @Returned) and (GetLastError = ERROR_SUCCESS),
      'Restore privilege is not available');
    try
      Entries := Manifest.Arrays['entries'];
      for I := 0 to Entries.Count - 1 do
      begin
        Entry := Entries.Objects[I];
        if Entry.Find('artifact') = nil then RestoreEntry(Entry, BackupRoot, False);
      end;
      for Path in InstalledFiles do RemoveInstalledFile(Path);
      for I := Entries.Count - 1 downto 0 do
      begin
        Entry := Entries.Objects[I];
        if (Entry.Find('artifact') = nil) and Entry.Booleans['directory'] then
          RestoreEntry(Entry, BackupRoot, True);
      end;
    finally
      AdjustTokenPrivileges(Token, False, @OriginalPrivileges, 0, nil, nil);
    end;
  finally
    CloseHandle(Token);
  end;
end;

procedure RestoreVerifiedFiles(const BackupRoot, InstallDir, CacheDir: UnicodeString;
  const TransitionID, Digest: string; const Scope, InstalledFiles: TBackupPaths);
var
  Manifest: TJSONObject;
begin
  Manifest := LoadVerifiedBackup(BackupRoot, TransitionID, Digest);
  try
    CheckRestorePaths(Manifest, Scope, ExcludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(BackupRoot))), InstallDir, CacheDir, InstalledFiles);
    RestoreFiles(Manifest, BackupRoot, InstalledFiles);
  finally
    Manifest.Free;
  end;
end;

end.
