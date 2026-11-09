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
    [string]$BuildPython = "C:\padit-build-python2\Scripts\python.exe",

    [switch]$OpenSsl35,

    [switch]$OpenSslFullTests
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
        'CVE-2026-119194.patch',
        'CVE-2026-119195.patch',
        'CVE-2026-119197.patch',
        'CVE-2026-119196.patch',
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
# W32: controlled OpenSSL 3.5.9 source archives.
$OpenSsl35Source = Join-Path $BuildKit 'runtime\openssl\sources\openssl-3.5.9.tar.gz'
$Python27Source = Join-Path $BuildKit 'python\sources\Python-2.7.18.tgz'
$Cryptography33Source = Join-Path $BuildKit 'python\sources\cryptography-3.3.2.tar.gz'

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
if (-not $OpenSsl35) {
    Assert-Sha256 $OpenSslZip "644FEDF6FC567716EF25F4FC805E2AAAC5BB7D32D01349EAEB62802CD20AE81A"
}
if ($OpenSslFullTests -and -not $OpenSsl35) {
    throw 'OpenSslFullTests requires OpenSsl35'
}



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

if ($OpenSsl35) {
    if ($Force) {
        throw 'W32 mode forbids -Force'
    }

    if (Test-Path -LiteralPath $Output) {
        throw "W32 output already exists: $Output"
    }
    Write-Step 'Validating controlled OpenSSL 3.5.9 sources'

    Assert-Sha256 $OpenSsl35Source `
        '603F5602E2EEF00D77FBD429D34DCD5822BB301757A1BC9CDB24C670F1EB859A'

    Assert-Sha256 $Python27Source `
        'DA3080E3B488F648A3D7A4560DDEE895284C3380B11D6DE75EDB986526B9A814'

    Assert-Sha256 $Cryptography33Source `
        '5A60D3780149E13B7A6FF7AD6526B38846354D11A15E21068E57073E29E19BED'

    $Crypto33PatchDir = Join-Path $RepoRoot 'utils\patch-cryptography-3.3.2'

    Assert-Sha256 (Join-Path $Crypto33PatchDir 'openssl3-compat.patch') `
        '2D2529DAD4C11757524942FF797937C03573F1DCB12F32AEFC2EE8227F1AF626'

    Assert-Sha256 (Join-Path $Crypto33PatchDir 'CVE-2023-49083.patch') `
        '3CE50D0C316AC82C00824D45777CD5E23F0AAAD329FA4088DF1A097936C0E162'

    Assert-Sha256 (Join-Path $Crypto33PatchDir 'CVE-2023-23931.patch') `
        'A9D0DDA2DA3A3419E786E549C63E2C6D89B1E61CB0196AAA27FD9670AAA8DBF6'
    Assert-Sha256 (Join-Path $Crypto33PatchDir 'CVE-2026-26007-sect-guard.patch') `
        '7099CBE06506D7B92696F786608D251DEF15BE92C8BE03A40DC72477DF07F079'

    Write-Host '[PASS] Controlled OpenSSL 3.5.9 sources'


    Write-Step 'Building OpenSSL 3.5.9 Windows x86'

    $W32VcVars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'
    $W32Perl = 'C:\Strawberry\perl\bin\perl.exe'
    $W32Nasm = 'C:\Program Files\NASM\nasm.exe'

    foreach ($Tool in @($W32VcVars, $W32Perl, $W32Nasm)) {
        Assert-File $Tool
    }

    $W32Work = Join-Path $BuildKit (
        'runtime\openssl\work\W32-' + [Guid]::NewGuid().ToString('N')
    )

    $W32Source = Join-Path $W32Work 'openssl-3.5.9'
    $W32Install = Join-Path $W32Work 'install'

    New-Item -ItemType Directory -Path $W32Work -Force | Out-Null

    Write-Host "OpenSSL work directory: $W32Work"

    & tar.exe -xzf $OpenSsl35Source -C $W32Work

    if ($LASTEXITCODE -ne 0) {
        throw 'OpenSSL 3.5.9 extraction failed'
    }

    Assert-File (Join-Path $W32Source 'Configure')

    $W32Batch = Join-Path $W32Work 'run-step.cmd'

    function Invoke-W32OpenSslStep {
        param(
            [string]$Name,
            [string]$Command
        )

        $Log = Join-Path $W32Work ($Name + '.log')

        if (Test-Path -LiteralPath $Log) {
            throw "Existing OpenSSL log: $Log"
        }

        $Commands = @(
            '@echo off'
            "call `"$W32VcVars`" x86 >nul"
            'if errorlevel 1 exit /b 1'
            'set "PATH=C:\Strawberry\perl\bin;C:\Program Files\NASM;%PATH%"'
            "cd /d `"$W32Source`""
            "$Command > `"$Log`" 2>&1"
            'exit /b %ERRORLEVEL%'
        )

        [IO.File]::WriteAllLines(
            $W32Batch,
            $Commands,
            [Text.Encoding]::ASCII
        )

        Write-Host "Running OpenSSL step: $Name"

        & cmd.exe /d /c "`"$W32Batch`""

        $ExitCode = $LASTEXITCODE

        if (-not (Test-Path -LiteralPath $Log -PathType Leaf)) {
            throw "OpenSSL $Name log missing"
        }

        Get-Content -LiteralPath $Log -Tail 12

        if ($ExitCode -ne 0) {
            throw "OpenSSL $Name failed: exit $ExitCode; log: $Log"
        }

        Write-Host "[PASS] OpenSSL $Name"
    }

    Invoke-W32OpenSslStep 'configure' (
        'perl.exe Configure VC-WIN32 no-makedepend ' +
        '--prefix="' + $W32Install + '" ' +
        '--openssldir="' + $W32Install + '\ssl"'
    )

    foreach ($Name in @('configdata.pm', 'makefile')) {
        Assert-File (Join-Path $W32Source $Name)
    }

    Invoke-W32OpenSslStep 'build' 'nmake /nologo'

    foreach ($Relative in @(
        'libcrypto-3.dll',
        'libssl-3.dll',
        'providers\legacy.dll',
        'apps\openssl.exe'
    )) {
        $Artifact = Join-Path $W32Source $Relative
        Assert-File $Artifact

        $Info = Get-Item -LiteralPath $Artifact

        if ($Info.Length -eq 0) {
            throw "Empty OpenSSL artifact: $Relative"
        }

        Write-Host "[PASS] OpenSSL artifact: $Relative"
        Write-Host "SHA256: $((Get-FileHash $Artifact -Algorithm SHA256).Hash)"
    }

    if ($OpenSslFullTests) {
        Invoke-W32OpenSslStep 'tests' 'nmake /nologo test'

        $TestLog = Join-Path $W32Work 'tests.log'
        $TestText = [IO.File]::ReadAllText($TestLog)

        if ($TestText -notmatch 'All tests successful\.' -or
            $TestText -notmatch 'Result:\s*PASS') {
            throw 'OpenSSL native test summary does not indicate PASS'
        }

        Write-Host '[PASS] OpenSSL complete native test suite'
    }

    Write-Host '[PASS] OpenSSL 3.5.9 Windows x86 native build'

    # W32: temporary guard until CPython modules and packaging are integrated.
    # -----------------------------------------------------------------------
    # W32 / Rebuild CPython 2.7.18 SSL extensions against OpenSSL 3.5.9
    # -----------------------------------------------------------------------

    Write-Step 'Building CPython 2.7.18 SSL extensions'

    $W32PythonSourceRoot = Join-Path $W32Work 'python-source'
    $W32PythonSource = Join-Path $W32PythonSourceRoot 'Python-2.7.18'
    $W32PythonBuild = Join-Path $W32Work 'python-extensions'

    New-Item -ItemType Directory -Path $W32PythonSourceRoot | Out-Null
    New-Item -ItemType Directory -Path $W32PythonBuild | Out-Null

    & tar.exe -xzf $Python27Source -C $W32PythonSourceRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'CPython 2.7.18 source extraction failed'
    }

    $W32SslC = Join-Path $W32PythonSource 'Modules\_ssl.c'
    $W32HashC = Join-Path $W32PythonSource 'Modules\_hashopenssl.c'

    Assert-Sha256 $W32SslC `
        'CB7C7F78309FB2EC95A794282F893D92C1A8D27AC16E348126B6CA790A00D22E'

    Assert-Sha256 $W32HashC `
        'DE4BD1262A96F03D79C2573389D71A62D25869AA84DF22C106D5719698241763'

    # W32-H55: CPython 2.7.18 ALPN double PyBuffer_Release fix.
    # Apply after upstream SHA256 validation, before compiling _ssl.pyd.
    $W32AlpnPattern = '(SSL_CTX_set_alpn_select_cb\(self->ctx, _selectALPN_cb, self\);)\r?\n(?:[ \t]*\r?\n)*[ \t]*PyBuffer_Release\(&protos\);'
    $W32AlpnMatches = [regex]::Matches(
        [IO.File]::ReadAllText($W32SslC), $W32AlpnPattern
    )

    if ($W32AlpnMatches.Count -ne 1) {
        throw "Expected one ALPN double-release site; found $($W32AlpnMatches.Count)"
    }

    $W32SslText = [IO.File]::ReadAllText($W32SslC)
    $W32SslText = [regex]::Replace(
        $W32SslText, $W32AlpnPattern, '$1'
    )
    [IO.File]::WriteAllText(
        $W32SslC, $W32SslText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host '[PASS] CPython ALPN double-release corrected'

    # W32-H57: CPython SSL allocator ownership fix.
    # PyMem_Malloc belongs to Python VC9; PyMem_FREE maps to the
    # MSVC 2022 CRT free() and must not release Python allocations.
    $W32AllocatorExpected = @{
        'PyMem_FREE(self->npn_protocols);' = 1
        'PyMem_FREE(self->alpn_protocols);' = 2
    }

    foreach ($W32Entry in $W32AllocatorExpected.GetEnumerator()) {
        $W32Count = ([regex]::Matches(
            $W32SslText,
            [regex]::Escape($W32Entry.Key)
        )).Count

        if ($W32Count -ne $W32Entry.Value) {
            throw "Unexpected SSL allocator count for $($W32Entry.Key): $W32Count"
        }
    }

    $W32SslText = $W32SslText.Replace(
        'PyMem_FREE(self->npn_protocols);',
        'PyMem_Free(self->npn_protocols);'
    ).Replace(
        'PyMem_FREE(self->alpn_protocols);',
        'PyMem_Free(self->alpn_protocols);'
    )

    $W32AllocatorOldCount = ([regex]::Matches(
        $W32SslText,
        'PyMem_FREE\(self->(npn|alpn)_protocols\);'
    )).Count

    $W32AllocatorNewCount = ([regex]::Matches(
        $W32SslText,
        'PyMem_Free\(self->(npn|alpn)_protocols\);'
    )).Count

    if ($W32AllocatorOldCount -ne 0 -or $W32AllocatorNewCount -ne 4) {
        throw "SSL allocator verification failed: old=$W32AllocatorOldCount new=$W32AllocatorNewCount"
    }

    [IO.File]::WriteAllText(
        $W32SslC, $W32SslText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host '[PASS] CPython SSL NPN/ALPN allocator ownership corrected'
    $W32PythonInclude = Join-Path $bootstrapRoot 'include'
    $W32PythonLib = Join-Path $bootstrapLibs 'python27.lib'
    $W32SslLib = Join-Path $W32Source 'libssl.lib'
    $W32CryptoLib = Join-Path $W32Source 'libcrypto.lib'
    $W32OpenSslInclude = Join-Path $W32Source 'include'

    Assert-Dir $W32PythonInclude
    Assert-Dir $W32OpenSslInclude

    foreach ($File in @($W32PythonLib, $W32SslLib, $W32CryptoLib)) {
        Assert-File $File
    }

    $W32SslObj = Join-Path $W32PythonBuild '_ssl.obj'
    $W32HashObj = Join-Path $W32PythonBuild '_hashlib.obj'
    $W32SslPyd = Join-Path $W32PythonBuild '_ssl.pyd'
    $W32HashPyd = Join-Path $W32PythonBuild '_hashlib.pyd'

    Invoke-W32OpenSslStep 'python-ssl-compile' (
        'cl.exe /nologo /c /MD /W3 ' +
        '/I"' + $W32PythonInclude + '" ' +
        '/I"' + $W32OpenSslInclude + '" ' +
        '/Fo"' + $W32SslObj + '" ' +
        '"' + $W32SslC + '"'
    )

    Assert-File $W32SslObj

    Invoke-W32OpenSslStep 'python-hashlib-compile' (
        'cl.exe /nologo /c /MD /W3 ' +
        '/I"' + $W32PythonInclude + '" ' +
        '/I"' + $W32OpenSslInclude + '" ' +
        '/Fo"' + $W32HashObj + '" ' +
        '"' + $W32HashC + '"'
    )

    Assert-File $W32HashObj

    $W32LinkLibs = (
        '"' + $W32PythonLib + '" ' +
        '"' + $W32SslLib + '" ' +
        '"' + $W32CryptoLib + '" ' +
        'ws2_32.lib crypt32.lib advapi32.lib user32.lib gdi32.lib'
    )

    Invoke-W32OpenSslStep 'python-ssl-link' (
        'link.exe /NOLOGO /DLL /INCREMENTAL:NO ' +
        '/OUT:"' + $W32SslPyd + '" ' +
        '/EXPORT:init_ssl ' +
        '"' + $W32SslObj + '" ' +
        $W32LinkLibs
    )

    Invoke-W32OpenSslStep 'python-hashlib-link' (
        'link.exe /NOLOGO /DLL /INCREMENTAL:NO ' +
        '/OUT:"' + $W32HashPyd + '" ' +
        '/EXPORT:init_hashlib ' +
        '"' + $W32HashObj + '" ' +
        $W32LinkLibs
    )

    foreach ($File in @($W32SslPyd, $W32HashPyd)) {
        Assert-File $File
        if ((Get-Item -LiteralPath $File).Length -eq 0) {
            throw "Empty Python SSL extension: $File"
        }

        Write-Host "[PASS] Rebuilt Python extension: $File"
        Write-Host "SHA256: $((Get-FileHash $File -Algorithm SHA256).Hash)"
    }

    Write-Host '[PASS] CPython 2.7.18 SSL extensions built with MSVC 2022 x86'

    # W32: temporary guard until cryptography and runtime staging are integrated.
    # W32 / Isolated cryptography 3.3.2 build
    Write-Step 'Building patched cryptography 3.3.2 for Windows x86'

    $W32CryptoRoot = Join-Path $W32Work 'cryptography-build'
    $W32CryptoSite = Join-Path $W32CryptoRoot 'build-site'
    $W32CryptoDist = Join-Path $W32CryptoRoot 'dist'
    $W32CryptoSource = Join-Path $W32CryptoRoot 'cryptography-3.3.2'

    foreach ($Dir in @($W32CryptoRoot, $W32CryptoSite, $W32CryptoDist)) {
        New-Item -ItemType Directory -Path $Dir | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $W32CryptoWheels = @(
        'setuptools-44.1.1-py2.py3-none-any.whl',
        'wheel-0.37.1-py2.py3-none-any.whl',
        'cffi-1.15.1-cp27-cp27m-win32.whl',
        'pycparser-2.19-py2.py3-none-any.whl',
        'six-1.16.0-py2.py3-none-any.whl'
    )

    foreach ($Name in $W32CryptoWheels) {
        $Archive = Join-Path $BuiltWheels $Name
        Assert-File $Archive

        if ($Name -eq 'wheel-0.37.1-py2.py3-none-any.whl') {
            Assert-Sha256 $Archive `
                '03517DF9FD3339B0BE83A6AB9AA49A7D4DACC6B82A820D8F1AB5C3FA862A86CC'
        }

        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $W32CryptoSite)
        Write-Host "[PASS] Staged $Name"
    }

    & tar.exe -xzf $Cryptography33Source -C $W32CryptoRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Cryptography source extraction failed'
    }

    Assert-File (Join-Path $W32CryptoSource 'setup.py')

    foreach ($Name in @('openssl3-compat.patch', 'CVE-2023-49083.patch', 'CVE-2023-23931.patch', 'CVE-2026-26007-sect-guard.patch')) {
        $Patch = Join-Path $Crypto33PatchDir $Name
        Assert-File $Patch

        Push-Location $W32CryptoSource
        try {
            & git.exe apply --check $Patch
            if ($LASTEXITCODE -ne 0) {
                throw "Cryptography patch check failed: $Name"
            }

            & git.exe apply $Patch
            if ($LASTEXITCODE -ne 0) {
                throw "Cryptography patch application failed: $Name"
            }
        }
        finally {
            Pop-Location
        }

        Write-Host "[PASS] Applied $Name"
    }

    $W32CryptoCheck = Join-Path $W32CryptoRoot 'check-dependencies.py'

    $W32CryptoCheckCode = @(
        'import os'
        'import pkg_resources'
        'site = os.path.normcase(os.path.abspath(os.environ["PADIT_BUILD_SITE"]))'
        'expected = {"setuptools": "44.1.1", "wheel": "0.37.1", "cffi": "1.15.1", "pycparser": "2.19", "six": "1.16.0"}'
        'for name, version in sorted(expected.items()):'
        '    dist = pkg_resources.get_distribution(name)'
        '    assert dist.version == version, (name, dist.version)'
        '    assert os.path.normcase(os.path.abspath(dist.location)) == site, (name, dist.location)'
        '    __import__(name)'
        '    print("[PASS] %s==%s" % (name, version))'
    )

    [IO.File]::WriteAllLines(
        $W32CryptoCheck,
        $W32CryptoCheckCode,
        [Text.Encoding]::ASCII
    )

    $W32CryptoCmd = Join-Path $W32CryptoRoot 'build.cmd'
    $W32CryptoLog = Join-Path $W32CryptoRoot 'build.log'

    $W32CryptoCommands = @(
        '@echo off'
        'setlocal'
        "call `"$W32VcVars`" x86 >nul"
        'if errorlevel 1 exit /b 10'
        "set `"PYTHONPATH=$W32CryptoSite`""
        "set `"PADIT_BUILD_SITE=$W32CryptoSite`""
        'set "PYTHONNOUSERSITE=1"'
        'set "PIP_NO_INDEX=1"'
        'set "DISTUTILS_USE_SDK=1"'
        'set "MSSdk=1"'
        "set `"INCLUDE=$W32Source\include;%INCLUDE%`""
        "set `"LIB=$W32Source;%LIB%`""
        "set `"PATH=$W32Source;%PATH%`""
        "cd /d `"$W32CryptoSource`""
        "`"$BootstrapPython`" -s `"$W32CryptoCheck`" > `"$W32CryptoLog`" 2>&1"
        'if errorlevel 1 exit /b 20'
        "echo === BUILD_EXT === >> `"$W32CryptoLog`""
        "`"$BootstrapPython`" -s setup.py build_ext --inplace --force >> `"$W32CryptoLog`" 2>&1"
        'if errorlevel 1 exit /b 30'
        "echo === BDIST_WHEEL === >> `"$W32CryptoLog`""
        "`"$BootstrapPython`" -s setup.py bdist_wheel --dist-dir `"$W32CryptoDist`" >> `"$W32CryptoLog`" 2>&1"
        'if errorlevel 1 exit /b 40'
        "echo === BUILD SUCCESS === >> `"$W32CryptoLog`""
        'exit /b 0'
    )

    [IO.File]::WriteAllLines(
        $W32CryptoCmd,
        $W32CryptoCommands,
        [Text.Encoding]::ASCII
    )

    & cmd.exe /d /c "`"$W32CryptoCmd`""
    $W32CryptoExit = $LASTEXITCODE

    if (Test-Path -LiteralPath $W32CryptoLog) {
        Get-Content -LiteralPath $W32CryptoLog -Tail 20
    }

    if ($W32CryptoExit -ne 0) {
        throw "Cryptography W32 build failed: exit $W32CryptoExit; log: $W32CryptoLog"
    }

    $W32CryptoWheelsBuilt = @(
        Get-ChildItem -LiteralPath $W32CryptoDist -Filter '*.whl' -File
    )

    if ($W32CryptoWheelsBuilt.Count -ne 1 -or
        $W32CryptoWheelsBuilt[0].Name -ne 'cryptography-3.3.2-cp27-cp27m-win32.whl') {
        throw 'Unexpected cryptography wheel output'
    }

    $W32CryptoWheel = $W32CryptoWheelsBuilt[0].FullName
    $W32Zip = [IO.Compression.ZipFile]::OpenRead($W32CryptoWheel)

    try {
        $W32Entries = @($W32Zip.Entries | ForEach-Object { $_.FullName })

        foreach ($Required in @(
            'cryptography/hazmat/bindings/_openssl.pyd',
            'cryptography/hazmat/bindings/_padding.pyd'
        )) {
            if ($W32Entries -notcontains $Required) {
                throw "Cryptography wheel missing: $Required"
            }
        }
    }
    finally {
        $W32Zip.Dispose()
    }

    Write-Host "[PASS] Cryptography wheel: $W32CryptoWheel"
    Write-Host "SHA256: $((Get-FileHash $W32CryptoWheel -Algorithm SHA256).Hash)"

    # Temporary W32 guard remains in place until staging and runtime tests.
    Write-Host '[PASS] W32 native components built; proceeding to runtime assembly'
}

if ($OpenSsl35 -and $Force) {
    throw 'W32 mode does not permit -Force during integration'
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

if ($OpenSsl35) {
    Write-Step 'Installing rebuilt W32 cryptography 3.3.2'

    Assert-File $W32CryptoWheel

    Invoke-Checked $RuntimePython @(
        '-m', 'pip', 'install',
        '--no-cache-dir', '--no-index', '--no-deps',
        '--force-reinstall',
        $W32CryptoWheel
    )

    Write-Host '[PASS] W32 cryptography wheel installed'
}
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
# W28 - pyOpenSSL CVE-2026-27448 SNI callback security backport.
# ---------------------------------------------------------------------------
Write-Step 'Applying pyOpenSSL CVE-2026-27448 backport'

$PyOpenSSLDir = Join-Path $Output 'Lib\site-packages\OpenSSL'
$PyOpenSSLSite = Join-Path $Output 'Lib\site-packages'
$PyOpenSSLSSL = Join-Path $PyOpenSSLDir 'SSL.py'
$PyOpenSSLPatchDir = Join-Path $RepoRoot 'utils\patch-pyopenssl-19.0.0'
$PyOpenSSLPatch = Join-Path $PyOpenSSLPatchDir 'CVE-2026-27448.patch'
$PyOpenSSLTest = Join-Path $PyOpenSSLPatchDir 'test-CVE-2026-27448.py'

Assert-File $PyOpenSSLSSL
Assert-Sha256 $PyOpenSSLPatch '30AA14431D2F886AB8A4CAF421C8E4811938FD7B1C32D98EC5E9FFCCCAD171D0'
Assert-Sha256 $PyOpenSSLTest 'D5FE1693F07184DEB77BB451F6BF721F1E29D89BCFCEFB80176667CBEC5C85C0'

$PyOpenSSLVersion = & $RuntimePython -c 'import OpenSSL;print(OpenSSL.__version__)'
if ($LASTEXITCODE -ne 0 -or $PyOpenSSLVersion.Trim() -ne '19.0.0') {
    throw "Unexpected pyOpenSSL version: $PyOpenSSLVersion"
}

Push-Location $PyOpenSSLSite
try {
    & git apply --check -p1 $PyOpenSSLPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'pyOpenSSL CVE-2026-27448 patch check failed'
    }

    & git apply -p1 $PyOpenSSLPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'pyOpenSSL CVE-2026-27448 patch application failed'
    }
}
finally {
    Pop-Location
}

& $RuntimePython -m py_compile $PyOpenSSLSSL
if ($LASTEXITCODE -ne 0) {
    throw 'pyOpenSSL SSL.py compilation failed'
}


# ---------------------------------------------------------------------------
# W26 - Eventlet CVE-2025-58068 HTTP trailer handling security backport.
# ---------------------------------------------------------------------------
Write-Step 'Applying Eventlet CVE-2025-58068 backport'

$EventletDir = Join-Path $Output 'Lib\site-packages\eventlet'
$EventletWsgi = Join-Path $EventletDir 'wsgi.py'
$EventletSecurityDir = Join-Path $RepoRoot 'utils\patch-eventlet-0.33.3'
$EventletPatch58068 = Join-Path $EventletSecurityDir 'CVE-2025-58068.patch'
$EventletTest58068 = Join-Path $EventletSecurityDir 'test_CVE-2025-58068.py'

Assert-Dir $EventletDir
Assert-File $EventletWsgi

Assert-Sha256 $EventletPatch58068 '897E91E4E5C77FE8205408E4DACA9C9FC12DA7540F34F2C19F92875343EA151D'
Assert-Sha256 $EventletTest58068 'D3D48CFFCDEB41A01AF2B15822E6DDf5EF82CA17EB91173DE671D6557A1EC38F'

$EventletVersion = & $RuntimePython -c 'import eventlet;print(eventlet.__version__)'
if ($LASTEXITCODE -ne 0 -or $EventletVersion.Trim() -ne '0.33.3') {
    throw "Unexpected Eventlet version: $EventletVersion"
}

Push-Location $EventletDir
try {
    & git apply --check -p1 $EventletPatch58068
    if ($LASTEXITCODE -ne 0) {
        throw 'Eventlet CVE-2025-58068 patch check failed'
    }

    & git apply -p1 $EventletPatch58068
    if ($LASTEXITCODE -ne 0) {
        throw 'Eventlet CVE-2025-58068 patch application failed'
    }
}
finally {
    Pop-Location
}

& $RuntimePython -m py_compile $EventletWsgi
if ($LASTEXITCODE -ne 0) {
    throw 'Eventlet wsgi.py compilation failed'
}

& $RuntimePython $EventletTest58068
if ($LASTEXITCODE -ne 0) {
    throw 'Eventlet CVE-2025-58068 regression failed'
}

Write-Host '[PASS] W26 Eventlet CVE-2025-58068 security backport'

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

# W18: CVE-2026-114605 - limit DNS compression pointer traversal.
Write-Step 'Applying dnspython CVE-2026-114605 backport'

$DnsW18Dir = Join-Path $Output 'Lib\site-packages\dns'
$DnsW18Patch = Join-Path $RepoRoot 'utils\patch-dnspython-1.16.0\CVE-2026-114605.patch'
$DnsW18Test = Join-Path $RepoRoot 'utils\patch-dnspython-1.16.0\test_cve_2026_114605.py'

Assert-Dir $DnsW18Dir
Assert-File $DnsW18Patch
Assert-File $DnsW18Test

if ((Get-FileHash -LiteralPath $DnsW18Patch -Algorithm SHA256).Hash -ne
    '3FD7D9501CC7874943B98E1877E7713F898073E79B818329BB6CD984AFC0D559') {
    throw 'W18 dnspython patch SHA256 mismatch'
}
if ((Get-FileHash -LiteralPath $DnsW18Test -Algorithm SHA256).Hash -ne
    '6135449C996F6C858D544CC4A9A563B66FEBD0EBBF0AFB8BA49798D1B0987F6F') {
    throw 'W18 dnspython test SHA256 mismatch'
}

Push-Location $DnsW18Dir
try {
    & git apply --check -p1 $DnsW18Patch
    if ($LASTEXITCODE -ne 0) {
        throw 'W18 dnspython patch check failed'
    }

    & git apply -p1 $DnsW18Patch
    if ($LASTEXITCODE -ne 0) {
        throw 'W18 dnspython patch application failed'
    }
}
finally {
    Pop-Location
}

& $RuntimePython -m py_compile (Join-Path $DnsW18Dir 'name.py')
if ($LASTEXITCODE -ne 0) {
    throw 'W18 dnspython compilation failed'
}

& $RuntimePython $DnsW18Test
if ($LASTEXITCODE -ne 0) {
    throw 'W18 dnspython security regression failed'
}
Write-Host '[PASS] W18 dnspython CVE-2026-114605'

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
    'CVE-2026-97687.patch',
    'CVE-2025-50181.patch',
    'CVE-2026-44431.patch'
)

Assert-File $Urllib3Response
# W25 - Verify new urllib3 security patches and regression tests.
$W25Files = @{
    'CVE-2025-50181.patch' = '61B801A0221BBF0DF4A3212B73089D44B95615C4844A79DDA58D08FA8BB85FDD'
    'CVE-2026-44431.patch' = 'D633C43DFB96063B2C7BE9E996E531813C5DB40084CFDEC3F836F2840692944E'
    'tests\test_CVE-2025-50181.py' = '6517DC15CE5F4EBEC72888B2E6EF7EA2E3D76682D5C904B2B541EF7D349D8F7E'
    'tests\test_CVE-2026-44431.py' = 'D5E72443B5191B98172D496F2F8D56D67437A41A521657711227F4CAD53C3B39'
}

foreach ($Entry in $W25Files.GetEnumerator()) {
    $File = Join-Path $Urllib3PatchDir $Entry.Key
    Assert-File $File
    $Actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($Actual -ne $Entry.Value) {
        throw "W25 urllib3 SHA256 mismatch: $($Entry.Key)"
    }
}

Write-Host '[PASS] W25 urllib3 patch and test SHA256 verified'


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
    'test_CVE-2026-97687.py',
    'test_CVE-2025-50181.py',
    'test_CVE-2026-44431.py'
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
# Controlled certifi CA bundle - Mozilla 2026.10.19 / Python 2.7
# ---------------------------------------------------------------------------

Write-Step 'Installing controlled certifi CA bundle'

$CertifiSource = Join-Path $RepoRoot 'utils\patch-certifi-2021.10.8\cacert-2026.10.19.pem'
$CertifiTest = Join-Path $RepoRoot 'utils\patch-certifi-2021.10.8\test_certifi_bundle.py'
$CertifiExpectedHash = '50F79F98DAC192B20DBF73F35C56F0B0C557AB267FF5199D1117CC1180B70785'

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

# W17: secure pip's separate vendored certifi trust store.
$PipCertifiDir = Join-Path $Output 'Lib\site-packages\pip\_vendor\certifi'
$PipCertifiTarget = Join-Path $PipCertifiDir 'cacert.pem'
Assert-Dir $PipCertifiDir
Assert-File $PipCertifiTarget

Copy-Item -LiteralPath $CertifiSource -Destination $PipCertifiTarget -Force

$PipCertifiHash = (Get-FileHash -LiteralPath $PipCertifiTarget -Algorithm SHA256).Hash
if ($PipCertifiHash -ne $CertifiExpectedHash) {
    throw 'pip vendored certifi bundle SHA256 mismatch'
}
Write-Host '[PASS] Controlled pip vendored certifi 2026.10.19 bundle installed'

Write-Step 'Running certifi security regression tests'

& $RuntimePython $CertifiTest
if ($LASTEXITCODE -ne 0) {
    throw 'certifi security regression tests failed'
}

Write-Host '[PASS] Controlled certifi 2026.10.19 bundle installed and validated'
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

# ---------------------------------------------------------------------------
# W16 - soupsieve 1.9.6 security backport (Python 2.7 x86).
# ---------------------------------------------------------------------------
Write-Step 'Applying soupsieve 1.9.6 security backport'

$SoupDir = Join-Path $Output 'Lib\site-packages\soupsieve'
$SoupPatch = Join-Path $RepoRoot 'utils\patch-soupsieve-1.9.6\CVE-2026-49476-49477-85999-86000.patch'
$SoupTest = Join-Path $RepoRoot 'utils\patch-soupsieve-1.9.6\test_security.py'
$SoupStage = Join-Path $Output '_soupsieve_security_stage'
$SoupStagePackage = Join-Path $SoupStage 'soupsieve'
$SoupParser = Join-Path $SoupDir 'css_parser.py'

Assert-Dir $SoupDir
Assert-File $SoupParser
Assert-File $SoupPatch
Assert-File $SoupTest

Assert-Sha256 $SoupPatch 'DADE2C1F8539B7316C2436E9C1C0A9B803055A08CBB D538A8FB84262A88AC201'.Replace(' ', '')
Assert-Sha256 $SoupTest 'B144B07F1B449DD60517917354E3B9387ADA9A576DAC4352C5FCC98746AF8907'

$SoupVersion = & $RuntimePython -c 'import soupsieve; print(soupsieve.__version__)'
if ($LASTEXITCODE -ne 0 -or $SoupVersion.Trim() -ne '1.9.6') {
    throw "Unexpected soupsieve version: $SoupVersion"
}

if (Test-Path -LiteralPath $SoupStage) {
    throw "soupsieve stage already exists: $SoupStage"
}

New-Item -ItemType Directory -Path $SoupStage | Out-Null
Copy-Item -LiteralPath $SoupDir -Destination $SoupStagePackage -Recurse

Push-Location $SoupStage
try {
    & git apply --check --whitespace=nowarn -p1 $SoupPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'soupsieve patch validation failed'
    }

    & git apply --whitespace=nowarn -p1 $SoupPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'soupsieve patch application failed'
    }
}
finally {
    Pop-Location
}

$SoupPatched = Join-Path $SoupStagePackage 'css_parser.py'
Assert-File $SoupPatched

# Verify LF-normalized content against the validated Unix W16 parser.
$SoupNormalized = [IO.File]::ReadAllText($SoupPatched).Replace("`r`n", "`n")
$SoupNormalizedBytes = [Text.Encoding]::UTF8.GetBytes($SoupNormalized)
$SoupHasher = [Security.Cryptography.SHA256]::Create()
try {
    $SoupNormalizedHash = (
        [BitConverter]::ToString($SoupHasher.ComputeHash($SoupNormalizedBytes))
    ).Replace('-', '')
}
finally {
    $SoupHasher.Dispose()
}

if ($SoupNormalizedHash -ne '9FC72FB3B683704AE27404D66639B7A6960D0DCB27C268FD2FA1202EBABB06DC') {
    throw "soupsieve patched parser SHA256 mismatch: $SoupNormalizedHash"
}

Copy-Item -LiteralPath $SoupPatched -Destination $SoupParser -Force

# Confirm installed parser is byte-for-byte identical to the patched stage.
$SoupStageHash = (Get-FileHash -LiteralPath $SoupPatched -Algorithm SHA256).Hash
Assert-Sha256 $SoupParser $SoupStageHash
Write-Host '[PASS] Installed soupsieve parser SHA256 verified'

Remove-Item -LiteralPath $SoupStage -Recurse -Force

& $RuntimePython -m py_compile $SoupParser
if ($LASTEXITCODE -ne 0) {
    throw 'soupsieve patched parser compilation failed'
}

# Run the six regression tests without installing pytest.
$SoupNames = @(
    'test_cve_2026_49476_selector_limit',
    'test_cve_2026_49476_relative_limit',
    'test_cve_2026_49476_token_budget',
    'test_cve_2026_49477_unterminated_quotes',
    'test_cve_2026_85999_whitespace',
    'test_cve_2026_86000_identifier'
)

$SoupRunner = @'
import imp
import sys

module = imp.load_source('padit_soupsieve_security', sys.argv[1])
getattr(module, sys.argv[2])()
print('[PASS] ' + sys.argv[2])
'@

$SoupRunnerFile = Join-Path $Output '_soupsieve_security_runner.py'
[IO.File]::WriteAllText($SoupRunnerFile, $SoupRunner, [Text.Encoding]::ASCII)

try {
    foreach ($SoupName in $SoupNames) {
        $SoupProcess = New-Object System.Diagnostics.Process
        $SoupProcess.StartInfo.FileName = $RuntimePython
        $SoupProcess.StartInfo.Arguments = (
            '-u "{0}" "{1}" "{2}"' -f
            $SoupRunnerFile, $SoupTest, $SoupName
        )
        $SoupProcess.StartInfo.UseShellExecute = $false
        $SoupProcess.StartInfo.CreateNoWindow = $true
        $SoupLog = Join-Path $Output ("_soupsieve_test_" + $SoupName + ".log")
        if (Test-Path -LiteralPath $SoupLog) {
            throw "soupsieve test log already exists: $SoupLog"
        }
        $SoupProcess.StartInfo.RedirectStandardOutput = $true
        $SoupProcess.StartInfo.RedirectStandardError = $true

        try {
            if (-not $SoupProcess.Start()) {
                throw "soupsieve test process could not start: $SoupName"
            }

            if (-not $SoupProcess.WaitForExit(10000)) {
                $SoupProcess.Kill()
                $SoupProcess.WaitForExit()
                throw "soupsieve regression TIMEOUT: $SoupName"
            }

            $SoupStdout = $SoupProcess.StandardOutput.ReadToEnd()
            $SoupStderr = $SoupProcess.StandardError.ReadToEnd()
            [IO.File]::WriteAllText(
                $SoupLog,
                $SoupStdout + $SoupStderr,
                [Text.Encoding]::UTF8
            )

            if ($SoupProcess.ExitCode -ne 0) {
                Write-Host ($SoupStdout + $SoupStderr)
                throw "soupsieve regression failed: $SoupName"
            }

            Write-Host ($SoupStdout.Trim())
            Write-Host "[PASS] Windows soupsieve regression: $SoupName"
        }
        finally {
            $SoupProcess.Dispose()
        }
    }
}
finally {
    Remove-Item -LiteralPath $SoupRunnerFile -Force -ErrorAction SilentlyContinue
}

Write-Host '[PASS] W16 soupsieve 1.9.6 security backport'

# ---------------------------------------------------------------------------
# W20 - waitress 1.4.4 security backports (Python 2.7 x86).
# ---------------------------------------------------------------------------
Write-Step 'Applying waitress 1.4.4 security backports'

$WaitressDir = Join-Path $Output 'Lib\site-packages\waitress'
$WaitressPatch = Join-Path $RepoRoot 'utils\patch-waitress-1.4.4\CVE-2022-24761-CVE-2024-49769.patch'
$WaitressTest = Join-Path $RepoRoot 'utils\patch-waitress-1.4.4\test_security.py'
$WaitressStage = Join-Path $Output '_waitress_security_stage'
$WaitressStagePackage = Join-Path $WaitressStage 'waitress'

Assert-Dir $WaitressDir
Assert-File $WaitressPatch
Assert-File $WaitressTest

Assert-Sha256 $WaitressPatch '7C4144FD7A6506499AA42EC177080E28F6BF24198678545E92858543CF50731B'
Assert-Sha256 $WaitressTest '6D637D365173C9EC9E7444715501F00561E9FF8FF47C95C1725E8C05DAE05BA0'

$WaitressVersion = & $RuntimePython -c "import pkg_resources; print(pkg_resources.get_distribution('waitress').version)"
if ($LASTEXITCODE -ne 0 -or $WaitressVersion.Trim() -ne '1.4.4') {
    throw "Unexpected waitress version: $WaitressVersion"
}

if (Test-Path -LiteralPath $WaitressStage) {
    throw "waitress stage already exists: $WaitressStage"
}

New-Item -ItemType Directory -Path $WaitressStage | Out-Null
Copy-Item -LiteralPath $WaitressDir -Destination $WaitressStagePackage -Recurse

Push-Location $WaitressStage
try {
    & git apply --check --whitespace=nowarn -p1 $WaitressPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'waitress patch validation failed'
    }

    & git apply --whitespace=nowarn -p1 $WaitressPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'waitress patch application failed'
    }
}
finally {
    Pop-Location
}

$WaitressHashes = @{
    'parser'    = '0D8A2CDFE498965C76FD602C61219033C98F1AB7D938A66D37874C7D87BF41F3'
    'receiver'  = 'A37E9F6C6EE878A3D6E1363DA5BB6948969290B4FCEF01DB3054FB8FE62BC6E1'
    'rfc7230'   = 'F58AFB134931F2951A817BC091FF5B63D770E5A8CA8CE4E1BA1B90E7EA01CC71'
    'channel'   = 'B4E89D3BD7276FBB88153797BE5116E75C3ED823AA89811C6D7D9BFA795501A5'
    'wasyncore' = '3BA7CCE83AEB68F22D8AE9E3C809862672ECF1D6EFAA1697D4DBABDC12EEEBA0'
}

foreach ($Name in @('parser', 'receiver', 'rfc7230', 'channel', 'wasyncore')) {
    $FileName = "$Name.py"
    $StagedFile = Join-Path $WaitressStagePackage $FileName
    $InstalledFile = Join-Path $WaitressDir $FileName

    # Normalize CRLF to LF before comparing against the Unix reference.
    foreach ($File in @($StagedFile, $InstalledFile)) {
        if ($File -eq $InstalledFile) {
            Copy-Item -LiteralPath $StagedFile -Destination $InstalledFile -Force
        }

        $RawBytes = [IO.File]::ReadAllBytes($File)
        $NormalizedBytes = [Text.Encoding]::UTF8.GetBytes(
            ([Text.Encoding]::UTF8.GetString($RawBytes)).Replace("`r`n", "`n")
        )

        $Hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $Actual = (
                [BitConverter]::ToString($Hasher.ComputeHash($NormalizedBytes))
            ).Replace('-', '')
        }
        finally {
            $Hasher.Dispose()
        }

        if ($Actual -ne $WaitressHashes[$Name]) {
            throw "waitress normalized SHA256 mismatch: $File"
        }
    }

    foreach ($Extension in @('.pyc', '.pyo')) {
        $Cache = Join-Path $WaitressDir ($Name + $Extension)
        if (Test-Path -LiteralPath $Cache) {
            Remove-Item -LiteralPath $Cache -Force
        }
    }

    Write-Host "[PASS] waitress corrected module: $FileName"
}

Remove-Item -LiteralPath $WaitressStage -Recurse -Force

foreach ($Name in @('parser', 'receiver', 'rfc7230', 'channel', 'wasyncore')) {
    Invoke-Checked $RuntimePython @(
        '-m', 'py_compile',
        (Join-Path $WaitressDir ($Name + '.py'))
    )
}

Invoke-Checked $RuntimePython @($WaitressTest)
Write-Host '[PASS] W20 waitress 1.4.4 security backports'

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

# PADIT-COMPAT-PY27-OPENSSL35-003 / W32-H60
# Python 2.7 Windows CA loader passes concatenated DER to cadata.
# With the PADIT OpenSSL 3.5.9 extension this fails, while PEM works.
# Preserve Windows trust filtering and the original DER return value.
# Retirement: re-evaluate when migrating to a modern Python runtime.
if ($OpenSsl35) {
    $W32RuntimeSslPy = Join-Path $Output 'Lib\ssl.py'
    Assert-File $W32RuntimeSslPy

    $W32SslPyText = [IO.File]::ReadAllText($W32RuntimeSslPy)

    $W32SslPyEdits = @(
        @(
            '        certs = bytearray()',
            "        certs = bytearray()`n        pem_certs = []"
        ),
        @(
            '                        certs.extend(cert)',
            "                        certs.extend(cert)`n                        pem_certs.append(DER_cert_to_PEM_cert(cert))"
        ),
        @(
            '            self.load_verify_locations(cadata=certs)',
            "            self.load_verify_locations(cadata=''.join(pem_certs))"
        )
    )

    foreach ($W32Edit in $W32SslPyEdits) {
        $W32Old = $W32Edit[0]
        $W32New = $W32Edit[1]

        $W32Count = ([regex]::Matches(
            $W32SslPyText,
            [regex]::Escape($W32Old)
        )).Count

        if ($W32Count -ne 1) {
            throw "Unexpected ssl.py patch occurrence count: $W32Count for $W32Old"
        }

        $W32SslPyText = $W32SslPyText.Replace($W32Old, $W32New)
    }

    [IO.File]::WriteAllText(
        $W32RuntimeSslPy,
        $W32SslPyText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host '[PASS] Python 2.7 Windows CA DER-to-PEM compatibility integrated'
}


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

if ($OpenSsl35) {
    Write-Step 'Assembling OpenSSL 3.5.9 Windows x86 runtime'

    $W32RuntimeDlls = Join-Path $Output 'DLLs'
    $W32ModuleDir = Join-Path $Output 'ossl-modules'

    Assert-Dir $W32RuntimeDlls
    New-Item -ItemType Directory -Path $W32ModuleDir | Out-Null

    $W32Copies = @(
        @($W32SslPyd, (Join-Path $W32RuntimeDlls '_ssl.pyd')),
        @($W32HashPyd, (Join-Path $W32RuntimeDlls '_hashlib.pyd')),
        @((Join-Path $W32Source 'libcrypto-3.dll'), (Join-Path $Output 'libcrypto-3.dll')),
        @((Join-Path $W32Source 'libssl-3.dll'), (Join-Path $Output 'libssl-3.dll')),
        @((Join-Path $W32Source 'libcrypto-3.dll'), (Join-Path $W32RuntimeDlls 'libcrypto-3.dll')),
        @((Join-Path $W32Source 'libssl-3.dll'), (Join-Path $W32RuntimeDlls 'libssl-3.dll')),
        @((Join-Path $W32Source 'providers\legacy.dll'), (Join-Path $W32ModuleDir 'legacy.dll')),
        @((Join-Path $W32Source 'apps\openssl.exe'), (Join-Path $Output 'openssl.exe')),
        @((Join-Path $W32Source 'apps\openssl.cnf'), (Join-Path $Output 'openssl.cnf'))
    )

    foreach ($Pair in $W32Copies) {
        $SourceFile = $Pair[0]
        $DestinationFile = $Pair[1]

        Assert-File $SourceFile

        if ((Get-Item -LiteralPath $SourceFile).Length -eq 0) {
            throw "Empty W32 source artifact: $SourceFile"
        }

        Copy-Item -LiteralPath $SourceFile `
            -Destination $DestinationFile -Force

        Assert-File $DestinationFile

        $SourceHash = (Get-FileHash $SourceFile -Algorithm SHA256).Hash
        $TargetHash = (Get-FileHash $DestinationFile -Algorithm SHA256).Hash

        if ($SourceHash -ne $TargetHash) {
            throw "W32 runtime copy mismatch: $DestinationFile"
        }

        Write-Host "[PASS] W32 runtime artifact: $DestinationFile"
    }

    foreach ($OldDll in @('libeay32.dll', 'ssleay32.dll')) {
        if (Test-Path -LiteralPath (Join-Path $Output $OldDll)) {
            throw "Unexpected legacy OpenSSL DLL in W32 root: $OldDll"
        }
    }

    Write-Host '[PASS] OpenSSL 3.5.9 runtime artifacts assembled'
}
else {Write-Step "Adding controlled external WAPT OpenSSL baseline"

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



}

# ---------------------------------------------------------------------------
# W22 - RPyC 4.1.5 / CVE-2024-27758.
# ---------------------------------------------------------------------------
Write-Step 'Applying RPyC CVE-2024-27758 backport'

$RpycDir = Join-Path $Output 'Lib\site-packages\rpyc'
$RpycFile = Join-Path $RpycDir 'core\netref.py'
$RpycPatch = Join-Path $RepoRoot 'utils\patch-rpyc-4.1.5\CVE-2024-27758.patch'
$RpycTest = Join-Path $RepoRoot 'utils\patch-rpyc-4.1.5\test_security.py'

Assert-Dir $RpycDir
Assert-File $RpycFile
Assert-File $RpycPatch
Assert-File $RpycTest

if ((Get-FileHash -LiteralPath $RpycPatch -Algorithm SHA256).Hash -ne
    'BE30DDFB1C633F4A54A4F6DA575D01AC43452C94F769C6ADC894CF99D1433BE9') {
    throw 'W22 RPyC patch SHA256 mismatch'
}

if ((Get-FileHash -LiteralPath $RpycTest -Algorithm SHA256).Hash -ne
    'BDB5C9EFA2319594839C3A3B6B9250590AFAE152E59B578805B873A04E910F09') {
    throw 'W22 RPyC test SHA256 mismatch'
}

$RpycVersion = & $RuntimePython -c "import pkg_resources; print(pkg_resources.get_distribution('rpyc').version)"
if ($LASTEXITCODE -ne 0 -or $RpycVersion.Trim() -ne '4.1.5') {
    throw "Unexpected W22 RPyC version: $RpycVersion"
}

$RpycSite = Join-Path $Output 'Lib\site-packages'
Assert-Dir $RpycSite

Push-Location $RpycSite
try {
    & git apply --check -p1 $RpycPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'W22 RPyC patch check failed'
    }

    & git apply -p1 $RpycPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'W22 RPyC patch application failed'
    }
}
finally {
    Pop-Location
}

& $RuntimePython -m py_compile $RpycFile
if ($LASTEXITCODE -ne 0) {
    throw 'W22 RPyC Python compilation failed'
}

# Validate LF-normalized content without modifying the installed source.
$RpycBytes = [System.IO.File]::ReadAllBytes($RpycFile)
$RpycText = [System.Text.Encoding]::ASCII.GetString($RpycBytes)
$RpycNormalized = $RpycText.Replace("`r`n", "`n")
$RpycHashBytes = [System.Text.Encoding]::ASCII.GetBytes($RpycNormalized)
$RpycSHA = [System.Security.Cryptography.SHA256]::Create()
try {
    $RpycHash = [BitConverter]::ToString(
        $RpycSHA.ComputeHash($RpycHashBytes)
    ).Replace('-', '')
}
finally {
    $RpycSHA.Dispose()
}

if ($RpycHash -ne '92B477B86552E05875A133B8CFAD9A0069D69776009B39504C1A960F950B3321') {
    throw 'W22 RPyC normalized SHA256 mismatch'
}

Remove-Item -LiteralPath (Join-Path $RpycDir 'core\netref.pyc') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $RpycDir 'core\netref.pyo') -Force -ErrorAction SilentlyContinue

& $RuntimePython -B $RpycTest
if ($LASTEXITCODE -ne 0) {
    throw 'W22 RPyC security regression failed'
}

Write-Host '[PASS] W22 secured RPyC 4.1.5 installed'

# ---------------------------------------------------------------------------
# W23 - python-socketio 4.4.0 / CVE-2026-48804.
# Reuse the validated Bookworm server and Unix agent backport.
# ---------------------------------------------------------------------------

Write-Step "Applying W23 python-socketio CVE-2026-48804 security backport"

$W23SocketDir = Join-Path $Output 'Lib\site-packages\socketio'
$W23SocketFile = Join-Path $W23SocketDir 'server.py'
$W23SocketPatch = Join-Path $RepoRoot 'utils\patch-python-socketio-4.4.0\CVE-2026-48804.patch'
$W23SocketTest = Join-Path $RepoRoot 'utils\patch-python-socketio-4.4.0\test_security.py'

Assert-Dir $W23SocketDir
Assert-File $W23SocketFile
Assert-File $W23SocketPatch
Assert-File $W23SocketTest

$W23PatchHash = (Get-FileHash -LiteralPath $W23SocketPatch -Algorithm SHA256).Hash
if ($W23PatchHash -ne '5BC5F0CE38F7D748415A2264FB869D0A6B36325BF7B765673FA65160130983D7') {
    throw 'W23 Socket.IO security patch SHA256 mismatch'
}

& $RuntimePython -B -c "import pkg_resources; assert pkg_resources.get_distribution('python-socketio').version == '4.4.0'"
if ($LASTEXITCODE -ne 0) {
    throw 'Unexpected W23 python-socketio version'
}

Push-Location $W23SocketDir
try {
    & git apply --check $W23SocketPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'W23 Socket.IO security patch check failed'
    }

    & git apply $W23SocketPatch
    if ($LASTEXITCODE -ne 0) {
        throw 'W23 Socket.IO security patch application failed'
    }
}
finally {
    Pop-Location
}

Remove-Item -LiteralPath (Join-Path $W23SocketDir 'server.pyc') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $W23SocketDir 'server.pyo') -Force -ErrorAction SilentlyContinue

& $RuntimePython -B $W23SocketTest
if ($LASTEXITCODE -ne 0) {
    throw 'W23 Socket.IO security regression failed'
}

Write-Host '[PASS] W23 secured python-socketio 4.4.0 installed'

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

$OpenSSLExe = Join-Path $Output 'openssl.exe'
Assert-File $OpenSSLExe

$W28Temp = Join-Path $env:TEMP ('padit-W28-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $W28Temp | Out-Null

$PreviousOpenSSLConf = $env:OPENSSL_CONF
$PreviousPath = $env:PATH

try {
    $W28Config = Join-Path $W28Temp 'openssl.cnf'

    [System.IO.File]::WriteAllText(
        $W28Config,
        "[req]`ndistinguished_name = dn`nprompt = no`n[dn]`nCN = localhost`n"
    )

    $env:OPENSSL_CONF = $W28Config
    $env:PATH = "$Output;$PreviousPath"

    & $RuntimePython $PyOpenSSLTest
    if ($LASTEXITCODE -ne 0) {
        throw 'pyOpenSSL CVE-2026-27448 TLS regression failed'
    }
}
finally {
    $env:OPENSSL_CONF = $PreviousOpenSSLConf
    $env:PATH = $PreviousPath
    Remove-Item -LiteralPath $W28Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '[PASS] W28 pyOpenSSL CVE-2026-27448 security backport'

# W32-BH8-F3 autonomous acceptance
if ($OpenSsl35) {
    Write-Step 'Validating autonomous OpenSSL 3.5.9 Windows x86 runtime'

    $W32AcceptanceFile = Join-Path $W32Work 'acceptance.py'

    $W32AcceptanceLines = @(
        'from __future__ import print_function'
        'import ctypes, datetime, os, socket, ssl, sys, tempfile, threading'
        'import _ssl, _hashlib'
        'import cryptography'
        'from cryptography import x509'
        'from cryptography.hazmat.bindings import _openssl'
        'from cryptography.hazmat.backends.openssl.backend import backend'
        'from cryptography.hazmat.primitives import hashes, serialization'
        'from cryptography.hazmat.primitives.asymmetric import rsa, padding'
        'from cryptography.x509.oid import NameOID'
        'import cryptography.x509.verification'
        ''
        'root = os.path.normcase(os.path.abspath(sys.prefix))'
        'site = os.path.join(root, "Lib", "site-packages")'
        'assert sys.version.startswith("2.7.18")'
        'assert sys.maxsize == 2147483647'
        'for entry in sys.path:'
        '    assert "w28-pyopenssl" not in entry.lower(), entry'
        ''
        'def check_location(module, folder):'
        '    actual = os.path.normcase(os.path.abspath(module.__file__))'
        '    expected = os.path.normcase(os.path.abspath(folder))'
        '    assert actual.startswith(expected + os.sep), (actual, expected)'
        '    print("[PASS] Module:", actual)'
        ''
        'check_location(_ssl, os.path.join(root, "DLLs"))'
        'check_location(_hashlib, os.path.join(root, "DLLs"))'
        'check_location(_openssl, os.path.join(site, "cryptography"))'
        'assert cryptography.__version__ == "3.3.2"'
        'assert ssl.OPENSSL_VERSION.startswith("OpenSSL 3.5.9 ")'
        'assert backend.openssl_version_text().startswith("OpenSSL 3.5.9 ")'
        'print("[PASS] OpenSSL 3.5.9 Python and cryptography backends")'
        ''
        'kernel = ctypes.windll.kernel32'
        'for dll in ("libcrypto-3.dll", "libssl-3.dll"):'
        '    handle = kernel.GetModuleHandleA(dll)'
        '    assert handle, dll'
        '    buffer = ctypes.create_string_buffer(2048)'
        '    assert kernel.GetModuleFileNameA(handle, buffer, len(buffer))'
        '    actual = os.path.normcase(os.path.abspath(buffer.value))'
        '    assert actual.startswith(root + os.sep), (dll, actual)'
        '    print("[PASS] Runtime DLL:", actual)'
        ''
        'key = rsa.generate_private_key(65537, 2048, backend)'
        'message = b"PADIT-W32-ACCEPTANCE"'
        'signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())'
        'key.public_key().verify(signature, message, padding.PKCS1v15(), hashes.SHA256())'
        'print("[PASS] RSA SHA256 signature and verification")'
        ''
        'name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, u"localhost")])'
        'now = datetime.datetime.utcnow()'
        'cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)'
        '        .public_key(key.public_key()).serial_number(x509.random_serial_number())'
        '        .not_valid_before(now - datetime.timedelta(days=1))'
        '        .not_valid_after(now + datetime.timedelta(days=1))'
        '        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)'
        '        .sign(key, hashes.SHA256(), backend))'
        'pem = cert.public_bytes(serialization.Encoding.PEM)'
        'loaded = x509.load_pem_x509_certificate(pem, backend)'
        'assert loaded.fingerprint(hashes.SHA256()) == cert.fingerprint(hashes.SHA256())'
        'print("[PASS] X509 certificate and fingerprint")'
        ''
        'folder = tempfile.mkdtemp(prefix="padit-w32-")'
        'try:'
        '    certfile = os.path.join(folder, "cert.pem")'
        '    keyfile = os.path.join(folder, "key.pem")'
        '    with open(certfile, "wb") as f:'
        '        f.write(pem)'
        '    with open(keyfile, "wb") as f:'
        '        f.write(key.private_bytes(serialization.Encoding.PEM,'
        '            serialization.PrivateFormat.TraditionalOpenSSL,'
        '            serialization.NoEncryption()))'
        '    server = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)'
        '    server.load_cert_chain(certfile, keyfile)'
        '    client = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)'
        '    client.verify_mode = ssl.CERT_REQUIRED'
        '    client.load_verify_locations(cafile=certfile)'
        '    listener = socket.socket()'
        '    listener.settimeout(10)'
        '    listener.bind(("127.0.0.1", 0))'
        '    listener.listen(1)'
        '    port = listener.getsockname()[1]'
        '    result = {}'
        '    def serve():'
        '        try:'
        '            conn, addr = listener.accept()'
        '            conn.settimeout(10)'
        '            tls = server.wrap_socket(conn, server_side=True)'
        '            try:'
        '                assert tls.recv(1024) == b"PADIT-CLIENT"'
        '                tls.sendall(b"PADIT-SERVER")'
        '                result["server"] = "PASS"'
        '            finally:'
        '                tls.close()'
        '        except Exception as exc:'
        '            result["server"] = repr(exc)'
        '        finally:'
        '            listener.close()'
        '    thread = threading.Thread(target=serve)'
        '    thread.daemon = True'
        '    thread.start()'
        '    conn = socket.create_connection(("127.0.0.1", port), 10)'
        '    conn.settimeout(10)'
        '    try:'
        '        tls = client.wrap_socket(conn)'
        '    except:'
        '        conn.close()'
        '        raise'
        '    try:'
        '        tls.sendall(b"PADIT-CLIENT")'
        '        assert tls.recv(1024) == b"PADIT-SERVER"'
        '        assert tls.getpeercert()'
        '    finally:'
        '        tls.close()'
        '    thread.join(10)'
        '    assert not thread.is_alive()'
        '    assert result.get("server") == "PASS", result'
        '    print("[PASS] TLS 1.2 verified loopback")'
        'finally:'
        '    for filename in ("cert.pem", "key.pem"):'
        '        item = os.path.join(folder, filename)'
        '        if os.path.exists(item):'
        '            os.remove(item)'
        '    os.rmdir(folder)'
        ''
        'print("=== W32 OPENSSL 3.5.9 AUTONOMOUS ACCEPTANCE PASS ===")'
    )

    [IO.File]::WriteAllLines(
        $W32AcceptanceFile,
        $W32AcceptanceLines,
        [Text.Encoding]::ASCII
    )

    $W32OldPath = $env:PATH
    $W32OldConf = $env:OPENSSL_CONF
    $W32OldModules = $env:OPENSSL_MODULES
    $W32OldPythonPath = $env:PYTHONPATH

    try {
        $env:PATH = "$Output;$Output\DLLs;$W32OldPath"
        $env:OPENSSL_CONF = Join-Path $Output 'openssl.cnf'
        $env:OPENSSL_MODULES = Join-Path $Output 'ossl-modules'
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue

        Invoke-Checked (Join-Path $Output 'waptpython.exe') @(
            '-E', '-s', $W32AcceptanceFile
        )

        Invoke-Checked (Join-Path $Output 'openssl.exe') @(
            'version', '-a'
        )
    }
    finally {
        $env:PATH = $W32OldPath
        $env:OPENSSL_CONF = $W32OldConf
        $env:OPENSSL_MODULES = $W32OldModules

        if ($null -eq $W32OldPythonPath) {
            Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONPATH = $W32OldPythonPath
        }
    }

    Write-Host '[PASS] W32 autonomous runtime acceptance'
}
Write-Step "SUCCESS"
Write-Host "Autonomous PADIT 1.8.3 runtime assembled at:"
Write-Host "  $Output"
Write-Host ""
Write-Host "This script does not yet build Lazarus projects, populate the full product tree,"
Write-Host "compile the Inno Setup installer, or sign release artifacts."
