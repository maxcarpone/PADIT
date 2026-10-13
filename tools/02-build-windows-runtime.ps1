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

# Controlled inputs
# ---------------------------------------------------------------------------

$BuiltWheels = Join-Path $BuildKit "python\built-wheels"
$PaditBins   = Join-Path $BuildKit "python\padit-binaries"
$OpenSslZip  = Join-Path $BuildKit "runtime\openssl\openssl-1.0.2u-i386-win32.zip"

$Python27Dll = Join-Path $PaditBins "python27.dll"
$PythonCom   = Join-Path $PaditBins "pywin32-228\pythoncom27.dll"
$PythonComL  = Join-Path $PaditBins "pywin32-228\pythoncomloader27.dll"
$PyWinTypes  = Join-Path $PaditBins "pywin32-228\pywintypes27.dll"
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
Assert-Sha256 $PyWinTypes  "C4DB872FF7D301186516882EA06422AEE29E1C11B44A4D382ADDD5B801207818"
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

Write-Step "Applying urllib3 1.26.20 security backports"

$Urllib3Dir = Join-Path $Output 'Lib\site-packages\urllib3'
$Urllib3Response = Join-Path $Urllib3Dir 'response.py'
$Urllib3PatchDir = Join-Path $RepoRoot 'utils\patch-urllib3-1.26.20'

$Urllib3Patches = @(
    'CVE-2026-97689.patch',
    'CVE-2025-66418.patch',
    'CVE-2025-66471.patch'
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
    'unconsumed_tail'
)) {
    if (-not $Urllib3Text.Contains($Marker)) {
        throw "Missing urllib3 protection marker: $Marker"
    }
}

Write-Host '[PASS] urllib3 backports applied and syntax verified'

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
Copy-Checked $PyWinTypes  (Join-Path $Output "pywintypes27.dll") "C4DB872FF7D301186516882EA06422AEE29E1C11B44A4D382ADDD5B801207818"

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
print("WAPT core: OK")
print("WAPT 1.8.3 AUTONOMOUS RUNTIME: PASS")
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
