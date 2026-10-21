#requires -Version 5.1
<#
.SYNOPSIS
  Assemble the autonomous Python/PADIT runtime for PADIT Community 1.8.3.

.DESCRIPTION
  Controlled replacement for the runtime-assembly portions of historical
  init_workdir.bat. It deliberately does NOT:
    - git clean the repository
    - download dependencies
    - upgrade pip/setuptools from the Internet
    - build Lazarus projects
    - build the Inno Setup installer
    - sign binaries

  Baseline assumptions:
    - bootstrap CPython 2.7.18 x86 is installed temporarily
    - C:\padit-build-kit contains the validated controlled inputs
    - this script is run from a WAPT 1.8.3 source tree

  The resulting runtime is expected to execute without C:\Python27 in sys.path.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoRoot = "",

    [Parameter()]
    [string]$BuildKit = "C:\padit-build-kit",

    [Parameter()]
    [string]$BootstrapPython = "C:\Python27\python.exe",

    [Parameter()]
    [string]$Output = "C:\padit-runtime-1.8.3",

    [switch]$Force,

    [Parameter()]
    [string]$UjsonPytestPackages = "",

    [Parameter()]
    [string]$BuildPython = "C:\padit-build-python2\Scripts\python.exe"
)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text"
}

function Assert-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file missing: $Path"
    }
}

function Assert-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory missing: $Path"
    }
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    Assert-File $Path
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw "SHA256 mismatch for $Path`nExpected: $Expected`nActual:   $actual"
    }
}

function Copy-Checked([string]$Source, [string]$Destination, [string]$Sha256) {
    Assert-Sha256 $Source $Sha256
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Assert-Sha256 $Destination $Sha256
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}


# ---------------------------------------------------------------------------
# Controlled Windows native dependency build: ujson 2.0.3 (Python 2.7 x86)
# ---------------------------------------------------------------------------

function Invoke-UjsonNative([string]$Name, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Name failed (exit $LASTEXITCODE)" }
}

function Build-ControlledUjsonWheel {
    Write-Step "Building patched ujson 2.0.3 wheel with VC9 (wheel absent)"
    $Archive = Join-Path $BuildKit 'python\sources\ujson-2.0.3.tar.gz'
    $PatchRoot = Join-Path $RepoRoot 'utils\patch-ujson-2.0.3'
    $WorkRoot = Join-Path $BuildKit ('python\work\ujson-2.0.3-integrated-' + [guid]::NewGuid().ToString('N'))
    $SourceDir = Join-Path $WorkRoot 'ujson-2.0.3'
    $WheelDir = $BuiltWheels
    $StageDir = Join-Path $WorkRoot 'wheel-dist'
    $VC9 = Join-Path $env:LOCALAPPDATA 'Programs\Common\Microsoft\Visual C++ for Python\9.0\vcvarsall.bat'

    $Patches = @(
        @{Name='CVE-2022-31116.patch'; Hash='CCEF883E16BBD8DAD3B790F38FF2D324F5D0515A7E0D6F6377B86F509A6FB18D'},
        @{Name='issue-334-buffer-overflow.patch'; Hash='1DDBA061DDC6E776E518A5A272D6D7CA0263BAC3B5EE947F554ABC82795658FD'},
        @{Name='windows-vc9-python27.patch'; Hash='F09F47A57A20ED1C77E9D1AF32CFB6B9BC1DE88799831BB97855DA5A028276A0'},
        @{Name='CVE-2022-31117.patch'; Hash='BBA4CDAB6C20EA2455B6C278C6CEA0E86E82C2ED4A7666F7DB06EC831DB69E52'},
        @{Name='CVE-2026-44660.patch'; Hash='09D96A036B39CD4C43555E210E53E778B216E83598F25D3A8BB984A7C4B8AD50'},
        @{Name='CVE-2026-54911.patch'; Hash='0CAB6CBD582872DB6703989D68CD3DCD1B087153C85C86CC1204E6B5096210B0'}
    )

    Assert-Sha256 $Archive 'BD2DEFFC983827510E5145FB66E4CC0F577480C62FE0B4882139F8F7D27AE9A3'
    Assert-File $BuildPython
    Assert-File $VC9
    Assert-File (Join-Path $PatchRoot 'tests\test_ujson_security.py')
    foreach ($Item in $Patches) {
        Assert-Sha256 (Join-Path $PatchRoot $Item.Name) $Item.Hash
    }


    if ([string]::IsNullOrWhiteSpace($UjsonPytestPackages)) {
        throw 'UjsonPytestPackages must be provided for tests before wheel production.'
    }
    if (-not (Test-Path -LiteralPath $UjsonPytestPackages -PathType Container)) {
        throw "Missing test dependencies: $UjsonPytestPackages"
    }
    if (Test-Path -LiteralPath $WorkRoot) {
        throw "Work directory exists; refusing to overwrite: $WorkRoot"
    }

    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    Invoke-UjsonNative 'extract archive' { & tar -xf $Archive -C $WorkRoot }
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { throw "Missing extracted source: $SourceDir" }

    foreach ($Item in $Patches) {
        $Path = Join-Path $PatchRoot $Item.Name
        Invoke-UjsonNative "check patch $($Item.Name)" { & git -C $SourceDir apply --check $Path }
        Invoke-UjsonNative "apply patch $($Item.Name)" { & git -C $SourceDir apply $Path }
        Write-Host "[OK] $($Item.Name)"
    }

    Copy-Item -LiteralPath (Join-Path $PatchRoot 'tests\test_ujson_security.py') -Destination (Join-Path $SourceDir 'tests\test_ujson_security.py')

    $OldPythonPath = $env:PYTHONPATH
    try {
        # pytest dependencies are only needed in the test subprocess.
        $env:PYTHONPATH = $UjsonPytestPackages
        Push-Location $SourceDir
        try {
            $BuildCmd = 'call "' + $VC9 + '" x86 && set DISTUTILS_USE_SDK=1 && set MSSdk=1 && "' + $BuildPython + '" setup.py build_ext --inplace --force'
            Invoke-UjsonNative 'VC9 extension build' { & cmd.exe /d /s /c $BuildCmd }
            Invoke-UjsonNative 'pytest' { & $BuildPython -m pytest tests\test_ujson.py tests\test_ujson_security.py -q }
        }
        finally { Pop-Location }
    }
    finally { $env:PYTHONPATH = $OldPythonPath }

    # CVE-2022-31117: source-level fix reviewed; deterministic realloc-failure
    # injection has NOT been tested. This limitation is not a wheel build blocker.
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    $WheelCmd = 'call "' + $VC9 + '" x86 && set DISTUTILS_USE_SDK=1 && set MSSdk=1 && "' + $BuildPython + '" setup.py bdist_wheel --dist-dir "' + $StageDir + '"'
    Push-Location $SourceDir
    try { Invoke-UjsonNative 'VC9 wheel build' { & cmd.exe /d /s /c $WheelCmd } }
    finally { Pop-Location }

    $Wheels = @(Get-ChildItem -LiteralPath $StageDir -Filter 'ujson-2.0.3-*-win32.whl' -File)
    if ($Wheels.Count -ne 1) { throw "Expected exactly one ujson 2.0.3 win32 wheel, got $($Wheels.Count)" }
    $Wheel = $Wheels[0]
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Wheel.FullName)
    try {
        $Names = @($Zip.Entries | ForEach-Object { $_.FullName })
        if (-not ($Names -contains 'ujson.pyd')) { throw 'Wheel missing ujson.pyd' }
        if (-not (@($Names | Where-Object { $_ -match '^ujson-2\.0\.3\.dist-info/(METADATA|PKG-INFO)$' }).Count -gt 0)) {
            throw 'Wheel missing ujson 2.0.3 package metadata'
        }
    }
    finally { $Zip.Dispose() }

    New-Item -ItemType Directory -Path $WheelDir -Force | Out-Null
    if ($Wheel.Name -ne 'ujson-2.0.3-cp27-cp27m-win32.whl') {
        throw "Unexpected wheel tag: $($Wheel.Name)"
    }
    $FinalWheel = Join-Path $WheelDir $Wheel.Name
    if (Test-Path -LiteralPath $FinalWheel) {
        if ((Get-FileHash -LiteralPath $FinalWheel -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $Wheel.FullName -Algorithm SHA256).Hash) {
            throw "Wheel already exists with different content: $FinalWheel"
        }
        Write-Host '[OK] Identical wheel already in controlled wheelhouse'
    }
    else { Copy-Item -LiteralPath $Wheel.FullName -Destination $FinalWheel }
    if ((Get-FileHash -LiteralPath $FinalWheel -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $Wheel.FullName -Algorithm SHA256).Hash) { throw 'Wheel copy verification failed' }
    Write-Host '[PASS] Patched source compiled and Python tests passed'
    Write-Host '[PASS] Windows wheel generated and checked:'
    Get-Item -LiteralPath $FinalWheel | Select-Object FullName, Length
    Write-Host ('SHA256: ' + (Get-FileHash -LiteralPath $FinalWheel -Algorithm SHA256).Hash)
    Write-Host '[NOTE] CVE-2022-31117 realloc-failure injection not exercised; source-level fix reviewed.'
 }

function Ensure-ControlledUjsonWheel {
    $Expected = '3FB4044AF8DA8BB21C486365EEA4C74BC7C6C0B134FBF83569659DC18D5B05CD'
    if (Test-Path -LiteralPath $UjsonWheel -PathType Leaf) {
        Write-Step 'Reusing SHA256-verified patched ujson 2.0.3 wheel'
        Assert-Sha256 $UjsonWheel $Expected
    }
    else {
        if ([string]::IsNullOrWhiteSpace($UjsonPytestPackages)) {
            throw 'Wheel absent: provide -UjsonPytestPackages pointing to offline pytest dependencies.'
        }
        Build-ControlledUjsonWheel
        # A new VC9 build may have a different PE timestamp and therefore a
        # different SHA256. Its source, patches, tests, wheel tag and contents
        # have been verified by Build-ControlledUjsonWheel.
        Assert-File $UjsonWheel
        Write-Host ('[PASS] Freshly built wheel SHA256: ' + (Get-FileHash -LiteralPath $UjsonWheel -Algorithm SHA256).Hash)
    }
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Controlled Python 2.7 pyasn1 0.5.1 security wheel
# ---------------------------------------------------------------------------
function Build-ControlledPyasn1Wheel {
    $Archive = Join-Path $BuildKit 'python\sources\pyasn1-0.5.1.tar.gz'
    $PatchRoot = Join-Path $RepoRoot 'utils\patch-pyasn1-0.5.1'
    $WorkRoot = Join-Path $BuildKit ('python\work\pyasn1-0.5.1-' + [guid]::NewGuid().ToString('N'))
    $SourceDir = Join-Path $WorkRoot 'pyasn1-0.5.1'
    $DistDir = Join-Path $WorkRoot 'wheel-dist'

    $Patches = @(
        'CVE-2026-23490.patch',
        'CVE-2026-59886.patch',
        'CVE-2026-59884.patch',
        'CVE-2026-30922.patch',
        'CVE-2026-59885.patch',
        'PADIT-python27-compat.patch',
        'PADIT-windows-mkstemp.patch'
    )

    Assert-Sha256 $Archive '6D391A96E59B23130A5CFA74D6FD7F388DBBE26CC8F1EDF39FDDDF08D9D6676C'
    Assert-File $BuildPython

    # Verify every patch against the committed SHA256SUMS file.
    $SumsFile = Join-Path $PatchRoot 'SHA256SUMS'
    Assert-File $SumsFile
    $ExpectedHashes = @{}

    foreach ($Line in (Get-Content -LiteralPath $SumsFile)) {
        if ($Line -notmatch '^([0-9a-fA-F]{64})\s+\*?(\S+)$') {
            throw "Invalid SHA256SUMS entry: $Line"
        }
        if ($ExpectedHashes.ContainsKey($Matches[2])) {
            throw "Duplicate SHA256SUMS entry: $($Matches[2])"
        }
        $ExpectedHashes[$Matches[2]] = $Matches[1]
    }

    if ($ExpectedHashes.Count -ne $Patches.Count) {
        throw 'Unexpected number of pyasn1 patch hashes'
    }

    foreach ($Name in $Patches) {
        if (-not $ExpectedHashes.ContainsKey($Name)) {
            throw "Missing SHA256 for $Name"
        }
        Assert-Sha256 (Join-Path $PatchRoot $Name) $ExpectedHashes[$Name]
    }

    Write-Step 'Building SHA256-controlled patched pyasn1 0.5.1 wheel'

    New-Item -ItemType Directory -Path $WorkRoot, $DistDir -Force | Out-Null
    Invoke-UjsonNative 'pyasn1 archive extraction' {
        & tar -xf $Archive -C $WorkRoot
    }
    Assert-Dir $SourceDir

    foreach ($Name in $Patches) {
        $Patch = Join-Path $PatchRoot $Name
        Invoke-UjsonNative "check pyasn1 patch $Name" {
            & git -C $SourceDir apply --check $Patch
        }
        Invoke-UjsonNative "apply pyasn1 patch $Name" {
            & git -C $SourceDir apply $Patch
        }
        Write-Host "[PASS] $Name"
    }

    $OldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = $SourceDir
        Push-Location $SourceDir
        try {
            Invoke-Checked $BuildPython @(
                '-m', 'unittest', 'discover',
                '-s', 'tests', '-p', 'test_*.py'
            )

            # Direct setup.py build avoids PEP 517 isolation on Python 2.7.
            Invoke-Checked $BuildPython @(
                'setup.py', 'bdist_wheel',
                '--dist-dir', $DistDir
            )
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $env:PYTHONPATH = $OldPythonPath
    }

    $Wheels = @(
        Get-ChildItem -LiteralPath $DistDir -Filter 'pyasn1-0.5.1-*.whl' -File
    )
    if ($Wheels.Count -ne 1) {
        throw "Expected one patched pyasn1 wheel; found $($Wheels.Count)"
    }

    $Wheel = $Wheels[0].FullName
    Write-Host ('[PASS] Patched wheel SHA256: ' +
        (Get-FileHash -LiteralPath $Wheel -Algorithm SHA256).Hash)

    Write-Step 'Installing tested patched pyasn1 wheel offline'
    Invoke-Checked $RuntimePython @(
        '-m', 'pip', 'install',
        '--no-cache-dir', '--no-index', '--no-deps',
        '--force-reinstall', $Wheel
    )
}

# ---------------------------------------------------------------------------
# Controlled pywin32 b228 native security build (CVE-2021-32559).
# This function is intentionally part of the runtime builder, not a new tool.
# ---------------------------------------------------------------------------
function Build-ControlledPywin32Native {
    $Archive = Join-Path $BuildKit 'python\sources\pywin32-b228-source.zip'
    $PatchDir = Join-Path $RepoRoot 'utils\patch-pywin32-228'
    $WorkDir = Join-Path $BuildKit ('python\work\pywin32-b228-controlled-' + [guid]::NewGuid().ToString('N'))
    $SourceDir = Join-Path $WorkDir 'source'
    $LibDir = Join-Path $WorkDir 'lib'
    $TempDir = Join-Path $WorkDir 'temp'
    $CompatDir = Join-Path $WorkDir 'sdk-compat\Lib\x86'
    $VC9Root = Join-Path $env:LOCALAPPDATA 'Programs\Common\Microsoft\Visual C++ for Python\9.0'
    $VcVars = Join-Path $VC9Root 'vcvarsall.bat'
    $SdkRoot = Join-Path $VC9Root 'WinSDK'
    $SdkLib = Join-Path $SdkRoot 'Lib'
    $SdkInclude = Join-Path $SdkRoot 'Include'
    $CmdFile = Join-Path $WorkDir 'build-native.cmd'
    $LogFile = Join-Path $WorkDir 'build-native.log'
    $Patches = @(
        @{Name='CVE-2021-32559-upstream.patch'; Hash='CF8697686F75A93FE23226604649055857A4FFC80D340C84FBC35B2C8CDE134A'},
        @{Name='CVE-2021-32559-regression.patch'; Hash='8304ED6E3F347D4562BDA221DAD0EC5BF239DB315591457AED378D2E101E4E7E'},
        @{Name='PADIT-targeted-build.patch'; Hash='C4B7489C94830F4D487B2F73149CB89AEC4FF8EC606E15C52DA42F0B2040CF15'}
    )

    Write-Step 'Building controlled pywin32 b228 native security modules'
    Assert-Sha256 $Archive '792247C46F0F51D8EBF37374493FB285E9F2BBD4C5044855BA0379491725C1A0'
    foreach ($Path in @($BuildPython, $VcVars, (Join-Path $VC9Root 'VC\Bin\cl.exe'))) { Assert-File $Path }
    foreach ($Path in @($SdkLib, $SdkInclude)) { Assert-Dir $Path }
    foreach ($Item in $Patches) { Assert-Sha256 (Join-Path $PatchDir $Item.Name) $Item.Hash }
    $SumFile = Join-Path $PatchDir 'SHA256SUMS'
    Assert-File $SumFile
    # Security patch manifest is stored separately from the PADIT build patch.
    foreach ($Item in $Patches[0..1]) {
        $Matching = @(Get-Content -LiteralPath $SumFile | Where-Object { $_ -eq ($Item.Hash.ToLowerInvariant() + '  ' + $Item.Name) })
        if ($Matching.Count -ne 1) { throw "Invalid SHA256SUMS entry for $($Item.Name)" }
    }

    New-Item -ItemType Directory -Path $WorkDir, $SourceDir, $LibDir, $TempDir, $CompatDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $SourceDir)
    Assert-File (Join-Path $SourceDir 'win32\src\PyACL.cpp')
    Assert-File (Join-Path $SourceDir 'setup.py')

    foreach ($Item in $Patches) {
        $Patch = Join-Path $PatchDir $Item.Name
        Invoke-Checked 'git.exe' @('-C', $SourceDir, 'apply', '--check', $Patch)
        Invoke-Checked 'git.exe' @('-C', $SourceDir, 'apply', $Patch)
        Write-Host "[PASS] $($Item.Name)"
    }

    # VC9 SDK libraries are flat; pywin32 expects an x86 subdirectory.
    $SdkFiles = @(Get-ChildItem -LiteralPath $SdkLib -Filter '*.lib' -File)
    if ($SdkFiles.Count -lt 100) { throw "Unexpected VC9 SDK library count: $($SdkFiles.Count)" }
    foreach ($Name in @('kernel32.lib','user32.lib','advapi32.lib')) {
        Assert-File (Join-Path $SdkLib $Name)
    }
    foreach ($File in $SdkFiles) {
        Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $CompatDir $File.Name)
    }
    $CmdLines = @(
        '@echo off',
        ('call "' + $VcVars + '" x86'),
        'if errorlevel 1 exit /b 10',
        ('set "MSSDK_INCLUDE=' + $SdkInclude + '"'),
        ('set "MSSDK_LIB=' + (Join-Path $WorkDir 'sdk-compat\Lib') + '"'),
        ('cd /d "' + $SourceDir + '"'),
        'if errorlevel 1 exit /b 11',
        ('"' + $BuildPython + '" setup.py --skip-verstamp build_ext --build-lib "' + $LibDir + '" --build-temp "' + $TempDir + '"'),
        'exit /b %ERRORLEVEL%'
    )
    [IO.File]::WriteAllLines($CmdFile, $CmdLines, [Text.Encoding]::ASCII)
    $CmdLine = 'call "' + $CmdFile + '" > "' + $LogFile + '" 2>&1'
    & cmd.exe /d /c $CmdLine
    $BuildExit = $LASTEXITCODE
    if ($BuildExit -ne 0) {
        Get-Content -LiteralPath $LogFile -Tail 35 | ForEach-Object { Write-Host $_ }
        throw "pywin32 native build failed ($BuildExit): $LogFile"
    }
    if (-not (Select-String -LiteralPath $LogFile -Pattern 'PyACL\.cpp' -Quiet)) {
        throw "PyACL.cpp was not compiled: $LogFile"
    }
    if (-not (Select-String -LiteralPath $LogFile -Pattern 'All extension modules built OK' -Quiet)) {
        throw "pywin32 native build did not complete: $LogFile"
    }

    $Dll = Join-Path $LibDir 'pywin32_system32\pywintypes27.dll'
    $Pyd = Join-Path $LibDir 'win32\win32security.pyd'
    Assert-File $Dll
    Assert-File $Pyd
    $DllHash = (Get-FileHash -LiteralPath $Dll -Algorithm SHA256).Hash
    $PydHash = (Get-FileHash -LiteralPath $Pyd -Algorithm SHA256).Hash
    $Site = Join-Path $Output 'Lib\site-packages'
    $SiteDll = Join-Path $Site 'pywin32_system32\pywintypes27.dll'
    $SitePyd = Join-Path $Site 'win32\win32security.pyd'
    Assert-File $SiteDll
    Assert-File $SitePyd
    Copy-Checked $Dll $SiteDll $DllHash
    Copy-Checked $Pyd $SitePyd $PydHash
    $script:ControlledPywin32Dll = $Dll
    $script:ControlledPywin32Hash = $DllHash
    $script:ControlledPywin32PydHash = $PydHash
    Write-Host "[PASS] pywintypes27.dll SHA256 $DllHash"
    Write-Host "[PASS] win32security.pyd SHA256 $PydHash"
    Write-Host "[PASS] pywin32 targeted build log: $LogFile"
}

function Test-ControlledPywin32Acl {
    Write-Step 'Testing controlled pywin32 native ACL security (7 variants)'
    $TestFile = Join-Path $env:TEMP ('padit-pywin32-acl-' + [guid]::NewGuid().ToString('N') + '.py')
    $Code = @'
import os, ctypes, hashlib
import pywintypes, win32security
root = os.path.normcase(os.path.realpath(__import__('sys').prefix))
site = os.path.join(root, 'Lib', 'site-packages')
paths = (os.path.join(root, 'pywintypes27.dll'), os.path.join(site, 'pywin32_system32', 'pywintypes27.dll'))
assert os.path.isfile(paths[0]) and os.path.isfile(paths[1])
def digest(p):
    with open(p, 'rb') as f: return hashlib.sha256(f.read()).hexdigest()
assert digest(paths[0]) == digest(paths[1]), 'Different root and site pywintypes DLLs'
for module in (pywintypes, win32security):
    assert os.path.normcase(os.path.realpath(module.__file__)).startswith(root + os.sep), module.__file__
k32 = ctypes.windll.kernel32
h = k32.GetModuleHandleW(u'pywintypes27.dll')
assert h, 'pywintypes27.dll not loaded'
buf = ctypes.create_unicode_buffer(32768)
assert k32.GetModuleFileNameW(h, buf, len(buf)) > 0
loaded = os.path.normcase(os.path.realpath(buf.value))
assert loaded in tuple(os.path.normcase(os.path.realpath(p)) for p in paths), 'Wrong DLL loaded: ' + loaded
sid = win32security.ConvertStringSidToSid('S-1-1-0')
rev = win32security.ACL_REVISION
revds = win32security.ACL_REVISION_DS
guid = pywintypes.IID('{00000000-0000-0000-0000-000000000001}')
cases = (
    ('AddAccessAllowedAce', lambda a: a.AddAccessAllowedAce(rev, 1, sid)),
    ('AddAccessAllowedAceEx', lambda a: a.AddAccessAllowedAceEx(rev, 0, 1, sid)),
    ('AddAuditAccessAce', lambda a: a.AddAuditAccessAce(rev, 1, sid, 1, 1)),
    ('AddAuditAccessAceEx', lambda a: a.AddAuditAccessAceEx(rev, 0, 1, sid, 1, 1)),
    ('AddAccessAllowedObjectAce', lambda a: a.AddAccessAllowedObjectAce(revds, 0, 1, guid, None, sid)),
    ('AddAccessDeniedObjectAce', lambda a: a.AddAccessDeniedObjectAce(revds, 0, 1, guid, None, sid)),
    ('AddAuditAccessObjectAce', lambda a: a.AddAuditAccessObjectAce(revds, 0, 1, guid, None, sid, 1, 1)),
)
for name, add in cases:
    acl = win32security.ACL()
    count = 0
    caught = False
    for i in range(5000):
        try: add(acl); count += 1
        except OverflowError as exc:
            assert 'size limit' in str(exc).lower(), (name, str(exc))
            caught = True
            break
    assert caught and acl.GetAceCount() == count, (name, count, acl.GetAceCount())
    print('[PASS] %s: %d ACEs' % (name, count))
print('[PASS] 7/7 ACL checks; loaded DLL: %s' % loaded)
'@
    [IO.File]::WriteAllText($TestFile, $Code, (New-Object Text.UTF8Encoding($false)))
    $OldPythonPath = $env:PYTHONPATH
    try {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
        Push-Location $env:TEMP
        try { Invoke-Checked $RuntimePython @($TestFile) }
        finally { Pop-Location }
    }
    finally {
        if ($null -eq $OldPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
        else { $env:PYTHONPATH = $OldPythonPath }
        Remove-Item -LiteralPath $TestFile -Force -ErrorAction SilentlyContinue
    }
}

# Controlled inputs
# ---------------------------------------------------------------------------

$BuiltWheels = Join-Path $BuildKit "python\built-wheels"
$PaditBins   = Join-Path $BuildKit "python\padit-binaries"
$OpenSslZip  = Join-Path $BuildKit "runtime\openssl\openssl-1.0.2u-i386-win32.zip"

$Python27Dll = Join-Path $PaditBins "python27.dll"
$PythonCom   = Join-Path $PaditBins "pywin32-228\pythoncom27.dll"
$PythonComL  = Join-Path $PaditBins "pywin32-228\pythoncomloader27.dll"
$UjsonWheel = Join-Path $BuiltWheels "ujson-2.0.3-cp27-cp27m-win32.whl"
$ActiveDir   = Join-Path $PaditBins "active_directory-0.6.7.py"

$ReqGeneric  = Join-Path $RepoRoot "requirements-agent.txt"
$ReqWindows  = Join-Path $RepoRoot "requirements-agent-windows.txt"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Step "Preflight"

Assert-File $BootstrapPython
Assert-Dir $RepoRoot
Assert-Dir $BuiltWheels
Assert-File $ReqGeneric
Assert-File $ReqWindows

Assert-Sha256 $Python27Dll "8C81C84548CE191B11390EBAA71397D23662593B1C113AAA0392E40FF0F9307A"
Assert-Sha256 $PythonCom   "074F23F9710BBCF1447763829C0E3D16AFA5502EFC6F784077CF334F28CEFFB7"
Assert-Sha256 $PythonComL  "CC5BA5439CFA435FC9BD442F6509EBDF83646DF0756093DFF6777775FD2246E6"
Ensure-ControlledUjsonWheel
Assert-Sha256 $ActiveDir   "EDFE01A38139D79A2EAC7B6F409B0495A447536CBB004318811D5CAF5842A556"
Assert-Sha256 $OpenSslZip  "644FEDF6FC567716EF25F4FC805E2AAAC5BB7D32D01349EAEB62802CD20AE81A"

$bootstrapRoot = Split-Path (Split-Path $BootstrapPython -Parent) -Parent
# For C:\Python27\python.exe, Split-Path -Parent once is the actual root.
$bootstrapRoot = Split-Path $BootstrapPython -Parent
$bootstrapLib  = Join-Path $bootstrapRoot "Lib"
$bootstrapDlls = Join-Path $bootstrapRoot "DLLs"
$bootstrapLibs = Join-Path $bootstrapRoot "libs"

Assert-Dir $bootstrapLib
Assert-Dir $bootstrapDlls
Assert-Dir $bootstrapLibs

$bootstrapLibFiles = Get-ChildItem -LiteralPath $bootstrapLibs -File

if ($bootstrapLibFiles.Count -ne 19) {
    throw "Unexpected Python 2.7 libs content: expected 19 files, found $($bootstrapLibFiles.Count) in $bootstrapLibs"
}

# Prevent destructive/ambiguous output choices.
$repoFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
$outFull  = [IO.Path]::GetFullPath($Output).TrimEnd('\')
$kitFull  = [IO.Path]::GetFullPath($BuildKit).TrimEnd('\')

if ($outFull -eq $repoFull -or $outFull.StartsWith($repoFull + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Output must not be the WAPT repository or a child of it: $Output"
}
if ($outFull -eq $kitFull -or $outFull.StartsWith($kitFull + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Output must not be inside the controlled build-kit: $Output"
}

# Clear PYTHONPATH for every bootstrap operation.
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue

# Validate bootstrap interpreter.
$pyInfo = & $BootstrapPython -c "import sys,struct; print(sys.version.split()[0]); print(struct.calcsize('P')*8)"
if ($LASTEXITCODE -ne 0) { throw "Unable to run bootstrap Python." }
if ($pyInfo[0].Trim() -ne "2.7.18" -or $pyInfo[1].Trim() -ne "32") {
    throw "Bootstrap Python must be Python 2.7.18 x86. Got: $($pyInfo -join ' / ')"
}

if (Test-Path -LiteralPath $Output) {
    if (-not $Force) {
        throw "Output already exists: $Output. Use -Force to replace it."
    }
    Write-Step "Removing existing output"
    Remove-Item -LiteralPath $Output -Recurse -Force
}

# ---------------------------------------------------------------------------
# Create virtualenv
# ---------------------------------------------------------------------------

Write-Step "Creating isolated Python 2.7 runtime"

Invoke-Checked $BootstrapPython @("-m", "virtualenv", "--always-copy", $Output)

$RuntimePython  = Join-Path $Output "Scripts\python.exe"
$RuntimePythonW = Join-Path $Output "Scripts\pythonw.exe"
$RuntimePip     = Join-Path $Output "Scripts\pip.exe"

Assert-File $RuntimePython
Assert-File $RuntimePip

# ---------------------------------------------------------------------------
# Install controlled wheels
# ---------------------------------------------------------------------------

Write-Step "Installing generic requirements offline"

Invoke-Checked $RuntimePython @(
    "-m", "pip", "install",
    "--no-cache-dir", "--no-index", "--no-deps",
    "--find-links=$BuiltWheels",
    "--requirement", $ReqGeneric
)

# Install the Windows-specific requirements directly from their manifest.
# ujson is excluded because its patched wheel is installed separately.
$WindowsPackages = @(
    Get-Content -LiteralPath $ReqWindows |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            $_ -and
            -not $_.StartsWith('#') -and
            $_ -notmatch '^ujson=='
        }
)

Write-Step "Installing Windows requirement layer offline"
Invoke-Checked $RuntimePython (@(
    "-m", "pip", "install",
    "--no-cache-dir", "--no-index", "--no-deps",
    "--find-links=$BuiltWheels"
) + $WindowsPackages)

Build-ControlledPyasn1Wheel
Build-ControlledPywin32Native

Write-Step "Installing patched ujson 2.0.3 wheel offline"
Invoke-Checked $RuntimePython @(
    "-m", "pip", "install",
    "--no-cache-dir", "--no-index", "--no-deps",
    $UjsonWheel
)

# ---------------------------------------------------------------------------
# urllib3 1.26.20 security backports, shared with the Bookworm runtime.
# Apply after pip installation, before dependency and runtime smoke tests.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Restore WAPT certificate verification compatibility for cryptography 3.3.2.
# These modules are maintained in utils/patch-cryptography.
# ---------------------------------------------------------------------------
Write-Step "Installing WAPT cryptography 3.3.2 compatibility modules"

$CryptoX509Dir = Join-Path $Output 'Lib\site-packages\cryptography\x509'
$CryptoPatchDir = Join-Path $RepoRoot 'utils\patch-cryptography'

foreach ($Name in @('__init__.py', 'verification.py')) {
    $Source = Join-Path $CryptoPatchDir $Name
    $Destination = Join-Path $CryptoX509Dir $Name

    Assert-File $Source

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

& $RuntimePython -m py_compile `
    (Join-Path $CryptoX509Dir '__init__.py') `
    (Join-Path $CryptoX509Dir 'verification.py')

if ($LASTEXITCODE -ne 0) {
    throw 'cryptography compatibility module compilation failed'
}

Write-Host '[PASS] WAPT cryptography compatibility modules installed'

# ---------------------------------------------------------------------------
# CVE-2023-29483 TuDoor: reuse validated Bookworm/Unix backports.
# ---------------------------------------------------------------------------
Write-Step "Applying CVE-2023-29483 Eventlet and dnspython backports"

$SecurityPatches = @(
    @{
        Name = 'dnspython'
        Version = '1.16.0'
        Directory = Join-Path $Output 'Lib\site-packages\dns'
        Patch = Join-Path $RepoRoot 'utils\patch-dnspython-1.16.0\CVE-2023-29483.patch'
        SHA256 = 'F87CA8BC3C3608EBD8CB84A5EDE045EA243D1F69D07FFACCC6873F70B5502E84'
        Files = @('query.py', 'resolver.py')
    },
    @{
        Name = 'eventlet'
        Version = '0.33.3'
        Directory = Join-Path $Output 'Lib\site-packages\eventlet'
        Patch = Join-Path $RepoRoot 'utils\patch-eventlet-0.33.3\CVE-2023-29483.patch'
        SHA256 = 'CFB887610C8229A14D595921B1FD79D0ECC2997EC74DD6A1A220978E9F7A5AD1'
        Files = @('support\greendns.py')
    }
)

foreach ($Item in $SecurityPatches) {
    Assert-Dir $Item.Directory
    Assert-File $Item.Patch

    $ActualHash = (Get-FileHash -LiteralPath $Item.Patch -Algorithm SHA256).Hash
    if ($ActualHash -ne $Item.SHA256) {
        throw "Unexpected CVE-2023-29483 patch SHA256: $($Item.Name)"
    }

    $PackageName = $Item.Name
    $InstalledVersion = & $RuntimePython -c "import pkg_resources; print(pkg_resources.get_distribution('$PackageName').version)"
    if ($LASTEXITCODE -ne 0 -or $InstalledVersion.Trim() -ne $Item.Version) {
        throw "Unexpected $PackageName version: $InstalledVersion"
    }

    foreach ($RelativeFile in $Item.Files) {
        Assert-File (Join-Path $Item.Directory $RelativeFile)
    }

    Push-Location $Item.Directory
    try {
        & git apply --check -p1 $Item.Patch
        if ($LASTEXITCODE -ne 0) {
            throw "CVE-2023-29483 patch check failed: $PackageName"
        }

        & git apply -p1 $Item.Patch
        if ($LASTEXITCODE -ne 0) {
            throw "CVE-2023-29483 patch application failed: $PackageName"
        }
    }
    finally {
        Pop-Location
    }

    foreach ($RelativeFile in $Item.Files) {
        & $RuntimePython -m py_compile (Join-Path $Item.Directory $RelativeFile)
        if ($LASTEXITCODE -ne 0) {
            throw "CVE-2023-29483 Python compilation failed: $PackageName"
        }
    }

    Write-Host "[PASS] $PackageName CVE-2023-29483 backport"
}

$DnsQueryFile = Join-Path $Output 'Lib\site-packages\dns\query.py'
$DnsResolverFile = Join-Path $Output 'Lib\site-packages\dns\resolver.py'
$GreenDnsFile = Join-Path $Output 'Lib\site-packages\eventlet\support\greendns.py'

foreach ($Entry in @(
    @{ Path = $DnsQueryFile; Marker = 'ignore_errors=ignore_errors, query=q' },
    @{ Path = $DnsResolverFile; Marker = 'ignore_errors=True' },
    @{ Path = $GreenDnsFile; Marker = 'ignore_errors=False' }
)) {
    $Contents = [System.IO.File]::ReadAllText($Entry.Path)
    if (-not $Contents.Contains($Entry.Marker)) {
        throw "Missing CVE-2023-29483 protection marker: $($Entry.Path)"
    }
}

Write-Host '[PASS] CVE-2023-29483 protection markers verified'

Write-Step "Applying urllib3 1.26.20 security backports"

$Urllib3Dir = Join-Path $Output 'Lib\site-packages\urllib3'
$Urllib3Response = Join-Path $Urllib3Dir 'response.py'
$Urllib3PatchDir = Join-Path $RepoRoot 'utils\patch-urllib3-1.26.20'

$Urllib3Patches = @(
    'CVE-2026-97689.patch',
    'CVE-2025-66418.patch',
    'CVE-2025-66471.patch',
    'CVE-2026-21441.patch',
    'CVE-2026-97687.patch'
)

Assert-File $Urllib3Response

$Urllib3Version = & $RuntimePython -c 'import urllib3; print(urllib3.__version__)'
if ($LASTEXITCODE -ne 0 -or $Urllib3Version.Trim() -ne '1.26.20') {
    throw "Unexpected urllib3 version: $Urllib3Version"
}

Push-Location $Urllib3Dir
try {
    foreach ($PatchName in $Urllib3Patches) {
        $PatchPath = Join-Path $Urllib3PatchDir $PatchName
        Assert-File $PatchPath

        & git apply --unidiff-zero --check -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "urllib3 patch check failed: $PatchName"
        }

        & git apply --unidiff-zero -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "urllib3 patch application failed: $PatchName"
        }

        Write-Host "[PASS] urllib3 $PatchName"
    }
}
finally {
    Pop-Location
}

& $RuntimePython -m py_compile $Urllib3Response
if ($LASTEXITCODE -ne 0) {
    throw 'urllib3 response.py syntax check failed'
}

$Urllib3Text = [System.IO.File]::ReadAllText($Urllib3Response)
foreach ($Marker in @(
    '_MAX_CHUNK_LINE_LENGTH',
    'max_decode_links = 5',
    'unconsumed_tail',
    '_has_decoded_content'
)) {
    if (-not $Urllib3Text.Contains($Marker)) {
        throw "Missing urllib3 protection marker: $Marker"
    }
}

Write-Host '[PASS] urllib3 backports applied and syntax verified'

Write-Step 'Running urllib3 security regression tests'
$Urllib3TestDir = Join-Path $Urllib3PatchDir 'tests'

foreach ($TestName in @(
    'test_urllib3_security_windows.py',
    'test_CVE-2026-21441-abandoned.py',
    'test_CVE-2026-21441-compatibility.py',
    'test_CVE-2026-21441-redirect.py',
    'test_CVE-2026-97687.py'
)) {
    $TestPath = Join-Path $Urllib3TestDir $TestName
    Assert-File $TestPath
    & $RuntimePython $TestPath
    if ($LASTEXITCODE -ne 0) {
        throw "urllib3 regression test failed: $TestName"
    }
}

Write-Host '[PASS] urllib3 security regression tests'

# ---------------------------------------------------------------------------
# requests 2.27.1 security backports (Python 2.7)
# ---------------------------------------------------------------------------

Write-Step 'Applying requests 2.27.1 security backports'

$RequestsDir = Join-Path $Output 'Lib\site-packages\requests'
$RequestsPatchDir = Join-Path $RepoRoot 'utils\patch-requests-2.27.1'

Assert-Dir $RequestsDir
Assert-Dir $RequestsPatchDir

$RequestsVersion = & $RuntimePython -c 'import requests; print(requests.__version__)'
if ($LASTEXITCODE -ne 0 -or $RequestsVersion.Trim() -ne '2.27.1') {
    throw "Unexpected requests version: $RequestsVersion"
}

$RequestsPatches = @(
    'CVE-2023-32681.patch',
    'CVE-2024-35195.patch',
    'CVE-2024-47081.patch',
    'CVE-2026-25645.patch'
)


$RequestsExpectedHashes = @{
    'CVE-2023-32681.patch' = '003EB163893C401F94E65172B6E11E659D4A5983E8CF6F85EED43E674DD8ECA2'
    'CVE-2024-35195.patch' = '4AF162E6E503F464AE8A62FB208E89D4427F3349606014C2C22901F02A8451D8'
    'CVE-2024-47081.patch' = '1FFC179DAE25541AAEFB867361535D4FDA56A51462E988CC06C9DF330AB23196'
    'CVE-2026-25645.patch' = '8B3A91CF7E963B2FA50311525DB2B23F297C966FD1860042190019443384937A'
}

foreach ($PatchName in $RequestsPatches) {
    $PatchPath = Join-Path $RequestsPatchDir $PatchName
    Assert-File $PatchPath

    $ActualHash = (Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256).Hash
    if ($ActualHash -ne $RequestsExpectedHashes[$PatchName]) {
        throw "requests patch SHA256 mismatch: $PatchName"
    }

    Push-Location $RequestsDir
    try {
        & git apply --check --unsafe-paths -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "requests patch check failed: $PatchName"
        }

        & git apply --unsafe-paths -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "requests patch application failed: $PatchName"
        }
    }
    finally {
        Pop-Location
    }

    Write-Host "[PASS] requests $PatchName"
}

& $RuntimePython -m py_compile `
    (Join-Path $RequestsDir 'sessions.py') `
    (Join-Path $RequestsDir 'adapters.py') `
    (Join-Path $RequestsDir 'utils.py')

if ($LASTEXITCODE -ne 0) {
    throw 'requests Python compilation failed'
}

Write-Host '[PASS] requests security backports applied'
Write-Step 'Running requests security regression tests'

$RequestsTest = Join-Path $RequestsPatchDir 'tests\test_requests_security_windows.py'
Assert-File $RequestsTest

& $RuntimePython $RequestsTest
if ($LASTEXITCODE -ne 0) {
    throw 'requests security regression tests failed'
}

Write-Host '[PASS] requests security regression suite'
# ---------------------------------------------------------------------------
# Controlled certifi CA bundle - Mozilla 2026.7.22 / Python 2.7
# ---------------------------------------------------------------------------

Write-Step 'Installing controlled certifi CA bundle'

$CertifiSource = Join-Path $RepoRoot 'utils\patch-certifi-2021.10.8\cacert-2026.7.22.pem'
$CertifiTest = Join-Path $RepoRoot 'utils\patch-certifi-2021.10.8\test_certifi_bundle.py'
$CertifiExpectedHash = '9CC2A774B5198DCFF14D9BE1E66091F538975D867CE029A96BCE15A55DFD730F'

Assert-File $CertifiSource
Assert-File $CertifiTest

$CertifiActualHash = (Get-FileHash -LiteralPath $CertifiSource -Algorithm SHA256).Hash
if ($CertifiActualHash -ne $CertifiExpectedHash) {
    throw 'Controlled certifi source SHA256 mismatch'
}

$CertifiDir = Join-Path $Output 'Lib\site-packages\certifi'
$CertifiTarget = Join-Path $CertifiDir 'cacert.pem'

Assert-Dir $CertifiDir
Assert-File $CertifiTarget

$CertifiVersion = & $RuntimePython -c 'import certifi; print(certifi.__version__)'
if ($LASTEXITCODE -ne 0 -or $CertifiVersion.Trim() -ne '2021.10.08') {
    throw "Unexpected certifi version: $CertifiVersion"
}

Copy-Item -LiteralPath $CertifiSource -Destination $CertifiTarget -Force

$CertifiInstalledHash = (Get-FileHash -LiteralPath $CertifiTarget -Algorithm SHA256).Hash
if ($CertifiInstalledHash -ne $CertifiExpectedHash) {
    throw 'Installed certifi bundle SHA256 mismatch'
}

Write-Step 'Running certifi security regression tests'

& $RuntimePython $CertifiTest
if ($LASTEXITCODE -ne 0) {
    throw 'certifi security regression tests failed'
}

Write-Host '[PASS] Controlled certifi 2026.7.22 bundle installed and validated'
# ---------------------------------------------------------------------------
# Werkzeug 1.0.1 security backports - Python 2.7 Windows x86
# ---------------------------------------------------------------------------

Write-Step 'Applying Werkzeug 1.0.1 security backports'

$WerkzeugDir = Join-Path $Output 'Lib\site-packages\werkzeug'
$WerkzeugPatchDir = Join-Path $RepoRoot 'utils\patch-werkzeug-1.0.1'
$WerkzeugTestDir = Join-Path $WerkzeugPatchDir 'tests'

Assert-Dir $WerkzeugDir
Assert-Dir $WerkzeugPatchDir
Assert-Dir $WerkzeugTestDir

$WerkzeugVersion = & $RuntimePython -c 'import werkzeug; print(werkzeug.__version__)'
if ($LASTEXITCODE -ne 0 -or $WerkzeugVersion.Trim() -ne '1.0.1') {
    throw "Unexpected Werkzeug version: $WerkzeugVersion"
}

$WerkzeugPatches = @(
    'CVE-2023-23934.patch',
    'CVE-2023-25577.patch',
    'CVE-2024-34069.patch',
    'safe-join-security-backports.patch'
)

$WerkzeugExpectedHashes = @{
    'CVE-2023-23934.patch' = '9E682A6132FFCAC899723307E8098ED6ADEE57CD69218A938C1E5B13C315514E'
    'CVE-2023-25577.patch' = '2E40F24444EC9ADBC8297550116CEAF17506C8CF6887FA4DB4A0201E066866EC'
    'CVE-2024-34069.patch' = '69C1B353EDB4B311A532C8FD81E9F3DE07A30951A064165047250C28F1CA0F8D'
    'safe-join-security-backports.patch' = 'ACCA1E1741F0C0B65B2A67498FCE315772B5C9A9C1D763A6BD60AF0436543650'
}

foreach ($PatchName in $WerkzeugPatches) {
    $PatchPath = Join-Path $WerkzeugPatchDir $PatchName
    Assert-File $PatchPath

    $ActualHash = (Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256).Hash
    if ($ActualHash -ne $WerkzeugExpectedHashes[$PatchName]) {
        throw "Werkzeug patch SHA256 mismatch: $PatchName"
    }

    Push-Location $WerkzeugDir
    try {
        & git apply --check -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Werkzeug patch check failed: $PatchName"
        }

        & git apply -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Werkzeug patch application failed: $PatchName"
        }
    }
    finally {
        Pop-Location
    }

    Write-Host "[PASS] Werkzeug $PatchName"
}

$WerkzeugTests = @(
    'test_werkzeug_1.py',
    'test_werkzeug_2.py',
    'test_werkzeug_3.py',
    'test_werkzeug_4.py',
    'test_werkzeug_windows_paths.py'
)

foreach ($TestName in $WerkzeugTests) {
    $TestPath = Join-Path $WerkzeugTestDir $TestName
    Assert-File $TestPath

    & $RuntimePython -u $TestPath
    if ($LASTEXITCODE -ne 0) {
        throw "Werkzeug regression test failed: $TestName"
    }
}

Write-Host '[PASS] Werkzeug security regression suites: 5/5'
# ---------------------------------------------------------------------------
# Flask 1.1.4 security backport - Python 2.7 Windows x86
# ---------------------------------------------------------------------------

Write-Step 'Applying Flask 1.1.4 security backport'

$FlaskDir = Join-Path $Output 'Lib\site-packages\flask'
$FlaskPatch = Join-Path $RepoRoot 'utils\patch-flask-1.1.4\CVE-2023-30861-CVE-2026-27205.patch'
$FlaskTest = Join-Path $RepoRoot 'utils\patch-flask-1.1.4\tests\test_flask_security_windows.py'

Assert-Dir $FlaskDir
Assert-File $FlaskPatch
Assert-File $FlaskTest

$FlaskVersion = & $RuntimePython -c 'import flask; print(flask.__version__)'

if ($LASTEXITCODE -ne 0 -or $FlaskVersion.Trim() -ne '1.1.4') {
    throw "Unexpected Flask version: $FlaskVersion"
}

$FlaskActualHash = (Get-FileHash -LiteralPath $FlaskPatch -Algorithm SHA256).Hash

if ($FlaskActualHash -ne '4B2A84CCDC10495DB631719F1B58FA16E2C4A7DEF27695FF39E6A0E3C1CC3312') {
    throw 'Flask security patch SHA256 mismatch'
}

# Patch paths use src/flask/*.py. Work on a temporary source layout,
# then copy only the four patched files into the new runtime.
$FlaskStage = Join-Path $Output '_flask_security_stage'
$FlaskStageSrc = Join-Path $FlaskStage 'src'
$FlaskStagePackage = Join-Path $FlaskStageSrc 'flask'

if (Test-Path -LiteralPath $FlaskStage) {
    throw "Flask staging directory already exists: $FlaskStage"
}

New-Item -ItemType Directory -Path $FlaskStageSrc | Out-Null
Copy-Item -LiteralPath $FlaskDir -Destination $FlaskStagePackage -Recurse

Push-Location $FlaskStage
try {
    & git apply --check -p1 $FlaskPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'Flask patch validation failed'
    }

    & git apply -p1 $FlaskPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'Flask patch application failed'
    }
}
finally {
    Pop-Location
}

foreach ($Name in @('app.py', 'ctx.py', 'sessions.py', 'templating.py')) {
    Copy-Item `
        -LiteralPath (Join-Path $FlaskStagePackage $Name) `
        -Destination (Join-Path $FlaskDir $Name) -Force
}

Remove-Item -LiteralPath $FlaskStage -Recurse -Force

& $RuntimePython -m py_compile `
    (Join-Path $FlaskDir 'app.py') `
    (Join-Path $FlaskDir 'ctx.py') `
    (Join-Path $FlaskDir 'sessions.py') `
    (Join-Path $FlaskDir 'templating.py')

if ($LASTEXITCODE -ne 0) {
    throw 'Flask patched modules compilation failed'
}

& $RuntimePython -u $FlaskTest

if ($LASTEXITCODE -ne 0) {
    throw 'Flask security regression tests failed'
}

Write-Host '[PASS] Flask 1.1.4 security backport and regression tests'


$Jinja2ExpectedHashes = @{
    'CVE-2024-22195-CVE-2024-34064.patch' = '1FC110B20B369FFADC501EA06F6CC88C9FA7D09A7965472C7F6388FB2CC5248F'
    'CVE-2024-56326-CVE-2025-27516.patch' = '61E272F9EC3A062CD419F13A3E6C5D6520A2E1C42426CD08889563E1D3A59B31'
}

# ---------------------------------------------------------------------------
# Jinja2 2.11.3 security backports - Windows Python 2.7 x86
# ---------------------------------------------------------------------------

Write-Step 'Applying Jinja2 2.11.3 security backports'

$Jinja2Dir = Join-Path $Output 'Lib\site-packages\jinja2'
$Jinja2PatchDir = Join-Path $RepoRoot 'utils\patch-jinja2-2.11.3'
$Jinja2Test = Join-Path $Jinja2PatchDir 'tests\test_jinja2_security_windows.py'

Assert-Dir $Jinja2Dir
Assert-Dir $Jinja2PatchDir
Assert-File $Jinja2Test

$Jinja2Version = & $RuntimePython -c 'import jinja2; print(jinja2.__version__)'

if ($LASTEXITCODE -ne 0 -or $Jinja2Version.Trim() -ne '2.11.3') {
    throw "Unexpected Jinja2 version: $Jinja2Version"
}

$Jinja2Patches = @(
    'CVE-2024-22195-CVE-2024-34064.patch'
    'CVE-2024-56326-CVE-2025-27516.patch'
)

$Jinja2Stage = Join-Path $Output '_jinja2_security_stage'
$Jinja2StageSrc = Join-Path $Jinja2Stage 'src'
$Jinja2StagePackage = Join-Path $Jinja2StageSrc 'jinja2'

if (Test-Path -LiteralPath $Jinja2Stage) {
    throw "Jinja2 staging directory already exists: $Jinja2Stage"
}

New-Item -ItemType Directory -Path $Jinja2StageSrc | Out-Null
Copy-Item -LiteralPath $Jinja2Dir -Destination $Jinja2StagePackage -Recurse

foreach ($PatchName in $Jinja2Patches) {
    $PatchPath = Join-Path $Jinja2PatchDir $PatchName
    Assert-File $PatchPath

    $ActualHash = (Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256).Hash

    if ($ActualHash -ne $Jinja2ExpectedHashes[$PatchName]) {
        throw "Jinja2 patch SHA256 mismatch: $PatchName"
    }

    Push-Location $Jinja2Stage
    try {
        & git apply --check -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Jinja2 patch check failed: $PatchName"
        }

        & git apply -p1 $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Jinja2 patch application failed: $PatchName"
        }
    }
    finally {
        Pop-Location
    }

    Write-Host "[PASS] Jinja2 $PatchName"
}

foreach ($Name in @('filters.py', 'sandbox.py')) {
    Copy-Item `
        -LiteralPath (Join-Path $Jinja2StagePackage $Name) `
        -Destination (Join-Path $Jinja2Dir $Name) -Force
}

Remove-Item -LiteralPath $Jinja2Stage -Recurse -Force

& $RuntimePython -m py_compile `
    (Join-Path $Jinja2Dir 'filters.py') `
    (Join-Path $Jinja2Dir 'sandbox.py')

if ($LASTEXITCODE -ne 0) {
    throw 'Jinja2 patched modules compilation failed'
}

& $RuntimePython -u $Jinja2Test

if ($LASTEXITCODE -ne 0) {
    throw 'Jinja2 security regression tests failed'
}

Write-Host '[PASS] Jinja2 security regression suites: 4 CVEs + compatibility'

# ---------------------------------------------------------------------------
# idna 2.10 security backport - Windows Python 2.7 x86 (W15)
# ---------------------------------------------------------------------------
Write-Step 'Applying idna 2.10 security backport'

$IdnaDir = Join-Path $Output 'Lib\site-packages\idna'
$IdnaPatch = Join-Path $RepoRoot 'utils\patch-idna-2.10\CVE-2024-3651-CVE-2026-45409.patch'
$IdnaStage = Join-Path $Output '_idna_security_stage'
$IdnaStagePackage = Join-Path $IdnaStage 'idna'

Assert-Dir $IdnaDir
Assert-File $IdnaPatch

$IdnaVersion = & $RuntimePython -c 'import idna; print(idna.__version__)'
if ($LASTEXITCODE -ne 0 -or $IdnaVersion.Trim() -ne '2.10') {
    throw "Unexpected idna version: $IdnaVersion"
}

Assert-Sha256 $IdnaPatch '01FCC4AC316420E773B3E64B71FC80773101B659DEA1E8324992B839425CED88'

if (Test-Path -LiteralPath $IdnaStage) {
    throw "idna stage already exists: $IdnaStage"
}

New-Item -ItemType Directory -Path $IdnaStage | Out-Null
Copy-Item -LiteralPath $IdnaDir -Destination $IdnaStagePackage -Recurse

Push-Location $IdnaStage
try {
    & git apply --check -p1 $IdnaPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'idna patch validation failed'
    }

    & git apply -p1 $IdnaPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'idna patch application failed'
    }
}
finally {
    Pop-Location
}

foreach ($Name in @('core.py', 'codec.py')) {
    Copy-Item `
        -LiteralPath (Join-Path $IdnaStagePackage $Name) `
        -Destination (Join-Path $IdnaDir $Name) -Force
}

Remove-Item -LiteralPath $IdnaStage -Recurse -Force

& $RuntimePython -m py_compile `
    (Join-Path $IdnaDir 'core.py') `
    (Join-Path $IdnaDir 'codec.py')

if ($LASTEXITCODE -ne 0) {
    throw 'idna patched module compilation failed'
}

# Confirm that the installed files match the validated patched sources.
$IdnaReference = Join-Path $RepoRoot 'utils\patch-idna-2.10\wip'

foreach ($Name in @('core.py', 'codec.py')) {
    $Installed = Join-Path $IdnaDir $Name
    $Reference = Join-Path $IdnaReference $Name

    Assert-File $Installed
    Assert-File $Reference

    $InstalledHash = (Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash
    $ReferenceHash = (Get-FileHash -LiteralPath $Reference -Algorithm SHA256).Hash

    if ($InstalledHash -ne $ReferenceHash) {
        # Windows git apply may preserve CRLF, unlike the Unix LF reference.
        $InstalledText = [System.IO.File]::ReadAllText($Installed)
        $ReferenceText = [System.IO.File]::ReadAllText($Reference)

        $InstalledNormalized = $InstalledText.Replace("`r`n", "`n")
        $ReferenceNormalized = $ReferenceText.Replace("`r`n", "`n")

        if ($InstalledNormalized -cne $ReferenceNormalized) {
            throw "idna patched source mismatch: $Name"
        }

        Write-Host "[PASS] idna $Name matches reference after CRLF normalization"
    }
    else {
        Write-Host "[PASS] idna $Name SHA256 matches reference"
    }

    Write-Host "       Installed SHA256: $InstalledHash"
    Write-Host "       Reference SHA256: $ReferenceHash"
}

$IdnaTests = @(
    'test_idna_baseline.py',
    'test_idna_security.py',
    'test_idna_incremental.py',
    'test_idna_boundaries.py',
    'test_idna_unicode_codec.py'
)

foreach ($TestName in $IdnaTests) {
    $TestPath = Join-Path $IdnaReference $TestName
    Assert-File $TestPath

    & $RuntimePython -u $TestPath

    if ($LASTEXITCODE -ne 0) {
        throw "idna regression failed: $TestName"
    }

    Write-Host "[PASS] Windows idna regression: $TestName"
}
Write-Host '[PASS] idna 2.10 security patch applied'
Write-Step "Checking Python package dependency consistency"
Invoke-Checked $RuntimePython @("-m", "pip", "check")

# ---------------------------------------------------------------------------
# Controlled WAPT-specific Python inputs and patches
# ---------------------------------------------------------------------------

$SitePackages = Join-Path $Output "Lib\site-packages"

Write-Step "Injecting controlled active_directory"
Copy-Checked $ActiveDir (Join-Path $SitePackages "active_directory.py") "EDFE01A38139D79A2EAC7B6F409B0495A447536CBB004318811D5CAF5842A556"

Write-Step "Applying WAPT SocketIO and cryptography patches"

$SocketIoPatch = Join-Path $RepoRoot "utils\patch-socketio-client-2"
$CryptoPatch   = Join-Path $RepoRoot "utils\patch-cryptography"

Assert-Dir $SocketIoPatch
Assert-Dir $CryptoPatch

Copy-Item -LiteralPath (Join-Path $SocketIoPatch "__init__.py") `
    -Destination (Join-Path $SitePackages "socketIO_client\__init__.py") -Force
Copy-Item -LiteralPath (Join-Path $SocketIoPatch "transports.py") `
    -Destination (Join-Path $SitePackages "socketIO_client\transports.py") -Force

$CryptoX509 = Join-Path $SitePackages "cryptography\x509"
Assert-Dir $CryptoX509
Copy-Item -LiteralPath (Join-Path $CryptoPatch "__init__.py") `
    -Destination (Join-Path $CryptoX509 "__init__.py") -Force
Copy-Item -LiteralPath (Join-Path $CryptoPatch "verification.py") `
    -Destination (Join-Path $CryptoX509 "verification.py") -Force

# ---------------------------------------------------------------------------
# Embed CPython stdlib/DLLs and sever virtualenv base-prefix dependency
# ---------------------------------------------------------------------------

Write-Step "Embedding CPython 2.7 standard library"

# Merge, do not mirror/delete: site-packages already contains the controlled
# package layer assembled above.
& robocopy $bootstrapLib (Join-Path $Output "Lib") /E /R:0 /W:0 /XD (Join-Path $bootstrapLib "site-packages") | Out-Host
if ($LASTEXITCODE -gt 7) { throw "robocopy Lib failed with code $LASTEXITCODE" }

Write-Step "Embedding CPython 2.7 native DLL directory"
& robocopy $bootstrapDlls (Join-Path $Output "DLLs") /E /R:0 /W:0 | Out-Host
if ($LASTEXITCODE -gt 7) { throw "robocopy DLLs failed with code $LASTEXITCODE" }

Write-Step "Embedding CPython 2.7 import libraries"

$runtimeLibs = Join-Path $Output "libs"
New-Item -ItemType Directory -Path $runtimeLibs -Force | Out-Null

& robocopy $bootstrapLibs $runtimeLibs /E /R:0 /W:0 | Out-Host
if ($LASTEXITCODE -gt 7) { throw "robocopy libs failed with code $LASTEXITCODE" }

$runtimeLibFiles = Get-ChildItem -LiteralPath $runtimeLibs -File
if ($runtimeLibFiles.Count -ne 19) {
    throw "Unexpected runtime libs content: expected 19 files, found $($runtimeLibFiles.Count) in $runtimeLibs"
}

foreach ($sourceFile in $bootstrapLibFiles) {
    $destinationFile = Join-Path $runtimeLibs $sourceFile.Name
    Assert-File $destinationFile

    $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash

    if ($sourceHash -ne $destinationHash) {
        throw "Python import library hash mismatch: $($sourceFile.Name)"
    }
}

Write-Host "Python import libraries: 19/19 PASS"

$OrigPrefix = Join-Path $Output "Lib\orig-prefix.txt"
if (Test-Path -LiteralPath $OrigPrefix) {
    Remove-Item -LiteralPath $OrigPrefix -Force
}

Write-Step "Installing controlled root runtime DLLs"

Copy-Checked $Python27Dll (Join-Path $Output "python27.dll") "8C81C84548CE191B11390EBAA71397D23662593B1C113AAA0392E40FF0F9307A"
Copy-Checked $PythonCom   (Join-Path $Output "pythoncom27.dll") "074F23F9710BBCF1447763829C0E3D16AFA5502EFC6F784077CF334F28CEFFB7"
Copy-Checked $PythonComL  (Join-Path $Output "pythoncomloader27.dll") "CC5BA5439CFA435FC9BD442F6509EBDF83646DF0756093DFF6777775FD2246E6"
Copy-Checked $ControlledPywin32Dll (Join-Path $Output "pywintypes27.dll") $ControlledPywin32Hash
Test-ControlledPywin32Acl

Copy-Item -LiteralPath $RuntimePython  -Destination (Join-Path $Output "waptpython.exe") -Force
Copy-Item -LiteralPath $RuntimePythonW -Destination (Join-Path $Output "waptpythonw.exe") -Force

# ---------------------------------------------------------------------------
# WAPT core source files
# ---------------------------------------------------------------------------

Write-Step "Copying WAPT core Python files"

$WaptCore = @(
    "waptutils.py",
    "waptcrypto.py",
    "common.py",
    "waptpackage.py",
    "wapt-get.py",
    "keyfinder.py",
    "setuphelpers.py",
    "setuphelpers_windows.py",
    "setuphelpers_linux.py",
    "setuphelpers_unix.py",
    "setuphelpers_macos.py",
    "windnsquery.py",
    "custom_zip.py"
)

foreach ($name in $WaptCore) {
    $src = Join-Path $RepoRoot $name
    Assert-File $src
    Copy-Item -LiteralPath $src -Destination (Join-Path $Output $name) -Force
}

# ---------------------------------------------------------------------------
# External WAPT OpenSSL baseline
# ---------------------------------------------------------------------------

Write-Step "Adding controlled external WAPT OpenSSL baseline"

$sslTemp = Join-Path ([IO.Path]::GetTempPath()) ("wapt-openssl-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $sslTemp | Out-Null
try {
    Expand-Archive -LiteralPath $OpenSslZip -DestinationPath $sslTemp

    Copy-Checked (Join-Path $sslTemp "openssl.exe") `
        (Join-Path $Output "openssl.exe") `
        "6063E160E812F3D57B67B77581E30F110FDFC708F763BB2FCC82FA9CAAC816A3"

    Copy-Checked (Join-Path $sslTemp "libeay32.dll") `
        (Join-Path $Output "libeay32.dll") `
        "5264A4A478383F501961F2BD9BEB1F77A43A487B76090561BBA2CBFE951E5305"

    Copy-Checked (Join-Path $sslTemp "ssleay32.dll") `
        (Join-Path $Output "ssleay32.dll") `
        "0A4031AB00664CC5E202C8731798800F0475EF76800122CEBD71D249655D725F"
}
finally {
    Remove-Item -LiteralPath $sslTemp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Acceptance tests
# ---------------------------------------------------------------------------

Write-Step "Validating final embedded Python package manager"
Invoke-Checked $RuntimePython @("-m", "pip", "--version")
Invoke-Checked $RuntimePython @("-m", "pip", "check")

Write-Step "Running autonomous runtime acceptance tests"

Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue

$TestScript = @'
import sys
import ctypes

assert sys.version.startswith("2.7.18")
assert sys.maxsize == 2147483647

bad = [p for p in sys.path if p and p.lower().startswith(r"c:\python27")]
assert not bad, "System Python leaked into sys.path: %r" % bad

k32 = ctypes.windll.kernel32
h = k32.GetModuleHandleA("python27.dll")
assert h
buf = ctypes.create_string_buffer(1024)
k32.GetModuleFileNameA(h, buf, len(buf))
loaded = buf.value.lower()
expected = (sys.prefix + r"\python27.dll").lower()
assert loaded == expected, "Wrong python27.dll loaded: %s (expected %s)" % (loaded, expected)

import os, json, ssl, hashlib, sqlite3, ctypes
import pythoncom, pywintypes, win32api
import ujson
assert ujson.__version__ == '2.0.3', ujson.__version__
import active_directory
import cryptography.x509.verification
import waptutils
import waptcrypto
import waptpackage
import setuphelpers
import common

assert waptutils.__version__ == "1.8.3"

print("Python:", sys.version.split()[0])
print("Executable:", sys.executable)
print("Prefix:", sys.prefix)
print("Loaded python27.dll:", buf.value)
print("pywin32: OK")
print("PADIT core: OK")
print("PADIT 1.8.3 AUTONOMOUS RUNTIME: PASS")
'@

$TestFile = Join-Path $env:TEMP ("wapt-runtime-test-" + [Guid]::NewGuid().ToString("N") + ".py")
[IO.File]::WriteAllText($TestFile, $TestScript, [Text.Encoding]::ASCII)
try {
    Push-Location $env:TEMP
    try {
        Invoke-Checked (Join-Path $Output "waptpython.exe") @($TestFile)
        Invoke-Checked (Join-Path $Output "waptpython.exe") @((Join-Path $Output "wapt-get.py"), "--help")
        Invoke-Checked (Join-Path $Output "openssl.exe") @("version")
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-Item -LiteralPath $TestFile -Force -ErrorAction SilentlyContinue
}

Write-Step "SUCCESS"
Write-Host "Autonomous PADIT 1.8.3 runtime assembled at:"
Write-Host "  $Output"
Write-Host ""
Write-Host "This script does not yet build Lazarus projects, populate the full product tree,"
Write-Host "compile the Inno Setup installer, or sign release artifacts."
