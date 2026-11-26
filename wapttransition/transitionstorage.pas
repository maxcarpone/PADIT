unit transitionstorage;

{$mode objfpc}{$H+}

interface

uses SysUtils, Windows;

const
  FILE_FLAG_OPEN_REPARSE_POINT = $00200000;

type
  TDirectoryPins = array of THandle;

function GetVolumePathNameW(Path, Volume: PWideChar; Size: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'GetVolumePathNameW';

function SecureTransitionRoot(const OverrideRoot: UnicodeString;
  var Pins: TDirectoryPins): UnicodeString;
function SecurityDescriptor(IsDirectory: Boolean): PSECURITY_DESCRIPTOR;
procedure SecureDirectory(const Path: UnicodeString);
procedure CheckStorageFile(const Path: UnicodeString);
procedure CheckLocalPath(const Path: UnicodeString);
procedure CheckStorageTree(const Path: UnicodeString);
function OpenStorageFile(const Path: UnicodeString; Access, ShareMode,
  Disposition: DWORD): THandle;
function DirectoryHasEntries(const Path: UnicodeString): Boolean;

implementation

uses WinDirs;

const
  ReadControl = $00020000;
  InheritedAceFlag = $10;
  FileAllAccess = $001F01FF;

function SddlToDescriptor(Text: PWideChar; Revision: DWORD;
  out Descriptor: PSECURITY_DESCRIPTOR; Size: PDWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

function LocalAttributes(const Path: UnicodeString): DWORD;
var
  Code: DWORD;
begin
  Result := GetFileAttributesW(PWideChar(Path));
  if Result = INVALID_FILE_ATTRIBUTES then
  begin
    Code := GetLastError;
    if Code <> ERROR_FILE_NOT_FOUND then
      RaiseLastOSError(Code);
  end
  else if (Result and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
    raise Exception.Create('Reparse point in transition path');
end;

procedure CheckLocalPath(const Path: UnicodeString);
var
  Current: UnicodeString;
  Attributes: DWORD;
begin
  Current := ExcludeTrailingPathDelimiter(Path);
  if (Length(Current) < 2) or (Current[2] <> ':') then
    raise Exception.Create('A local Windows drive path is required');
  while Length(Current) > 2 do
  begin
    Attributes := LocalAttributes(Current);
    if Attributes = INVALID_FILE_ATTRIBUTES then
      raise Exception.Create('A required local path does not exist');
    Current := ExcludeTrailingPathDelimiter(ExtractFileDir(Current));
  end;
end;

function SecurityDescriptor(IsDirectory: Boolean): PSECURITY_DESCRIPTOR;
var
  Sddl, Inheritance: UnicodeString;
begin
  Inheritance := '';
  if IsDirectory then
    Inheritance := 'OICI';
  Sddl := 'O:BAG:BAD:P(A;' + Inheritance + ';FA;;;SY)(A;' +
    Inheritance + ';FA;;;BA)';
  if not SddlToDescriptor(PWideChar(Sddl), 1, Result, nil) then
    RaiseLastOSError;
end;

procedure VerifySecurity(const Path: UnicodeString; IsDirectory,
  RequireProtected: Boolean);
var
  Handle: THandle;
  Info: TByHandleFileInformation;
  Buffer: array of Byte;
  Needed, Revision, Index: DWORD;
  Present, Defaulted: BOOL;
  Control: SECURITY_DESCRIPTOR_CONTROL;
  Descriptor, Reference: PSECURITY_DESCRIPTOR;
  Owner, AdminSid, SystemSid: PSID;
  Acl, ReferenceAcl: PACL;
  Ace, ReferenceAce: Pointer;
  AdminSeen, SystemSeen: Boolean;
  Flags: Byte;
begin
  Handle := CreateFileW(PWideChar(Path), ReadControl or FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Handle, Info) then RaiseLastOSError;
    if ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or
       (((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) <> IsDirectory) or
       ((not IsDirectory) and (Info.nNumberOfLinks <> 1)) then
      raise Exception.Create('Unsafe object in transition directory');
    Needed := 0;
    GetKernelObjectSecurity(Handle, OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
      nil, 0, @Needed);
    if Needed = 0 then RaiseLastOSError;
    SetLength(Buffer, Needed);
    Descriptor := PSECURITY_DESCRIPTOR(@Buffer[0]);
    if not GetKernelObjectSecurity(Handle, OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
      Descriptor, Length(Buffer), @Needed) then RaiseLastOSError;
    Reference := SecurityDescriptor(IsDirectory);
    try
      if not GetSecurityDescriptorOwner(Reference, AdminSid, @Defaulted) or
         not GetSecurityDescriptorDacl(Reference, @Present, ReferenceAcl, @Defaulted) or
         not GetAce(ReferenceAcl, 0, ReferenceAce) then RaiseLastOSError;
      SystemSid := @PACCESS_ALLOWED_ACE(ReferenceAce)^.SidStart;
      if not GetSecurityDescriptorOwner(Descriptor, Owner, @Defaulted) or
         not GetSecurityDescriptorDacl(Descriptor, @Present, Acl, @Defaulted) or
         not GetSecurityDescriptorControl(Descriptor, @Control, @Revision) then RaiseLastOSError;
      if (Owner = nil) or not (EqualSid(Owner, AdminSid) or EqualSid(Owner, SystemSid)) or
         not Present or (Acl = nil) or (Acl^.AceCount <> 2) or
         (RequireProtected and ((Control and $1000) = 0)) then
        raise Exception.Create('Unsafe transition owner or NTFS permissions');
      Flags := 0;
      if IsDirectory then Flags := OBJECT_INHERIT_ACE or CONTAINER_INHERIT_ACE;
      AdminSeen := False;
      SystemSeen := False;
      for Index := 0 to Acl^.AceCount - 1 do
      begin
        if not GetAce(Acl, Index, Ace) then RaiseLastOSError;
        with PACCESS_ALLOWED_ACE(Ace)^ do
        begin
          if (Header.AceType <> ACCESS_ALLOWED_ACE_TYPE) or
             ((Header.AceFlags and not InheritedAceFlag) <> Flags) or
             (Mask <> FileAllAccess) then
            raise Exception.Create('Unsafe transition NTFS access entry');
          if EqualSid(@SidStart, AdminSid) then AdminSeen := True
          else if EqualSid(@SidStart, SystemSid) then SystemSeen := True;
        end;
      end;
      if not (AdminSeen and SystemSeen) then
        raise Exception.Create('Transition permissions must grant only SYSTEM and Administrators');
    finally
      LocalFree(HLOCAL(Reference));
    end;
  finally
    CloseHandle(Handle);
  end;
end;

procedure SecureDirectory(const Path: UnicodeString);
var
  Security: TSecurityAttributes;
  Descriptor: PSECURITY_DESCRIPTOR;
  Code: DWORD;
begin
  if LocalAttributes(Path) = INVALID_FILE_ATTRIBUTES then
  begin
    Descriptor := SecurityDescriptor(True);
    try
      Security.nLength := SizeOf(Security);
      Security.lpSecurityDescriptor := Descriptor;
      Security.bInheritHandle := False;
      if not CreateDirectoryW(PWideChar(Path), @Security) then
      begin
        Code := GetLastError;
        if Code <> ERROR_ALREADY_EXISTS then RaiseLastOSError(Code);
      end;
    finally
      LocalFree(HLOCAL(Descriptor));
    end;
  end;
  VerifySecurity(Path, True, True);
end;

procedure CheckStorageFile(const Path: UnicodeString);
begin
  if LocalAttributes(Path) <> INVALID_FILE_ATTRIBUTES then
    VerifySecurity(Path, False, False);
end;

function OpenStorageFile(const Path: UnicodeString; Access, ShareMode,
  Disposition: DWORD): THandle;
var
  Security: TSecurityAttributes;
  Descriptor: PSECURITY_DESCRIPTOR;
  Code: DWORD;
begin
  CheckStorageFile(Path);
  Descriptor := SecurityDescriptor(False);
  try
    Security.nLength := SizeOf(Security);
    Security.lpSecurityDescriptor := Descriptor;
    Security.bInheritHandle := False;
    Result := CreateFileW(PWideChar(Path), Access, ShareMode, @Security,
      Disposition, FILE_FLAG_OPEN_REPARSE_POINT or FILE_ATTRIBUTE_NORMAL, 0);
    Code := GetLastError;
  finally
    LocalFree(HLOCAL(Descriptor));
  end;
  SetLastError(Code);
end;

function SidToText(Sid: PSID; out Text: PWideChar): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertSidToStringSidW';

function IsTrustedParentSid(Sid: PSID): Boolean;
var
  Text: PWideChar;
  Value: UnicodeString;
begin
  if Sid = nil then Exit(False);
  if not SidToText(Sid, Text) then RaiseLastOSError;
  try
    Value := Text;
    Result := (Value = 'S-1-5-18') or (Value = 'S-1-5-32-544') or
      (Value = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464');
  finally
    LocalFree(HLOCAL(Text));
  end;
end;

procedure VerifyParentPermissions(Directory: THandle);
const
  ParentChangeRights = $10000000 or $40000000 or $000D0000 or
    FILE_DELETE_CHILD or FILE_WRITE_ATTRIBUTES;
  InheritOnly = $08;
var
  Needed, Index: DWORD;
  Buffer: array of Byte;
  Descriptor: PSECURITY_DESCRIPTOR;
  Owner: PSID;
  Acl: PACL;
  Present, Defaulted: BOOL;
  Ace: Pointer;
begin
  Needed := 0;
  GetKernelObjectSecurity(Directory, OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
    nil, 0, @Needed);
  if Needed = 0 then RaiseLastOSError;
  SetLength(Buffer, Needed);
  Descriptor := PSECURITY_DESCRIPTOR(@Buffer[0]);
  if not GetKernelObjectSecurity(Directory, OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
    Descriptor, Length(Buffer), @Needed) or
    not GetSecurityDescriptorOwner(Descriptor, Owner, @Defaulted) or
    not GetSecurityDescriptorDacl(Descriptor, @Present, Acl, @Defaulted) then RaiseLastOSError;
  if not IsTrustedParentSid(Owner) or not Present or (Acl = nil) then
    raise Exception.Create('Unsafe transition parent owner or permissions');
  for Index := 1 to Acl^.AceCount do
  begin
    if not GetAce(Acl, Index - 1, Ace) then RaiseLastOSError;
    with PACCESS_ALLOWED_ACE(Ace)^ do
    begin
      if (Header.AceFlags and InheritOnly) <> 0 then Continue;
      case Header.AceType of
        ACCESS_ALLOWED_ACE_TYPE:
          if ((Mask and ParentChangeRights) <> 0) and not IsTrustedParentSid(@SidStart) then
            raise Exception.Create('Unsafe transition parent NTFS access entry');
        ACCESS_DENIED_ACE_TYPE: ;
        else raise Exception.Create('Unsupported transition parent NTFS access entry');
      end;
    end;
  end;
end;

procedure PinDirectory(const Path: UnicodeString; var Pins: TDirectoryPins;
  ValidateParent: Boolean = False);
var
  Directory: THandle;
  Info: TByHandleFileInformation;
begin
  // Keep each ancestor open without share-delete until the lock is released.
  Directory := CreateFileW(PWideChar(Path), FILE_LIST_DIRECTORY or ReadControl,
    FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Directory = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Directory, Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <>
       FILE_ATTRIBUTE_DIRECTORY then
      raise Exception.Create('Unsafe or reparse point in transition parent');
    if ValidateParent then VerifyParentPermissions(Directory);
    SetLength(Pins, Length(Pins) + 1);
    Pins[High(Pins)] := Directory;
  except
    CloseHandle(Directory);
    raise;
  end;
end;

procedure PinAncestors(const Path: UnicodeString; var Pins: TDirectoryPins;
  ValidateParents: Boolean);
var
  Parent, Current: UnicodeString;
begin
  Current := ExcludeTrailingPathDelimiter(Path);
  if (Length(Current) < 2) or (Current[2] <> ':') then
    raise Exception.Create('A local Windows drive path is required');
  if Length(Current) = 2 then
    Current := IncludeTrailingPathDelimiter(Current)
  else
  begin
    Parent := ExtractFileDir(Current);
    PinAncestors(Parent, Pins, ValidateParents);
  end;
  PinDirectory(Current, Pins, ValidateParents);
end;

function SecureTransitionRoot(const OverrideRoot: UnicodeString;
  var Pins: TDirectoryPins): UnicodeString;
var
  Parent: UnicodeString;
  Volume, FileSystem: array[0..MAX_PATH] of WideChar;
begin
  if OverrideRoot = '' then
  begin
    Parent := GetWindowsSpecialDirUnicode(FOLDERID_ProgramData, False);
    if Parent = '' then raise Exception.Create('Could not resolve ProgramData');
    Result := IncludeTrailingPathDelimiter(Parent) + 'PADIT\Transition';
  end
  else
  begin
    Result := ExcludeTrailingPathDelimiter(ExpandFileName(OverrideRoot));
    Parent := ExtractFileDir(Result);
  end;
  PinAncestors(Parent, Pins, OverrideRoot = '');
  if not GetVolumePathNameW(PWideChar(Parent), @Volume[0], Length(Volume)) or
     not GetVolumeInformationW(@Volume[0], nil, 0, nil, nil, nil,
       @FileSystem[0], Length(FileSystem)) then RaiseLastOSError;
  if (GetDriveTypeW(@Volume[0]) <> DRIVE_FIXED) or
     (UnicodeString(PWideChar(@FileSystem[0])) <> 'NTFS') then
    raise Exception.Create('Transition directory requires NTFS');
  if OverrideRoot = '' then
  begin
    SecureDirectory(ExtractFileDir(Result));
    PinDirectory(ExtractFileDir(Result), Pins);
    VerifySecurity(ExtractFileDir(Result), True, True);
  end;
  SecureDirectory(Result);
  PinDirectory(Result, Pins);
  VerifySecurity(Result, True, True);
  Result := IncludeTrailingPathDelimiter(Result);
end;

function ScanDirectory(const Path: UnicodeString; Verify: Boolean): Boolean;
var
  Info: TWin32FindDataW;
  Search: THandle;
  Child, Name: UnicodeString;
  Code: DWORD;
begin
  Result := False;
  Search := FindFirstFileW(PWideChar(IncludeTrailingPathDelimiter(Path) + '*'), Info);
  if Search = INVALID_HANDLE_VALUE then
  begin
    Code := GetLastError;
    if Code = ERROR_FILE_NOT_FOUND then Exit;
    RaiseLastOSError(Code);
  end;
  try
    repeat
      Name := PWideChar(@Info.cFileName[0]);
      if (Name = '.') or (Name = '..') then Continue;
      Result := True;
      if not Verify then Exit;
      Child := IncludeTrailingPathDelimiter(Path) + Name;
      if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      begin
        VerifySecurity(Child, True, False);
        ScanDirectory(Child, True);
      end
      else
        VerifySecurity(Child, False, False);
    until not FindNextFileW(Search, Info);
    if GetLastError <> ERROR_NO_MORE_FILES then RaiseLastOSError;
  finally
    Windows.FindClose(Search);
  end;
end;

procedure CheckStorageTree(const Path: UnicodeString);
begin
  VerifySecurity(Path, True, False);
  ScanDirectory(Path, True);
end;

function DirectoryHasEntries(const Path: UnicodeString): Boolean;
begin
  Result := ScanDirectory(Path, False);
end;

end.
