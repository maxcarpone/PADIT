[CmdletBinding()]
param(
    [string]$BuildKit = 'C:\wapt-build-kit',
    [string]$PythonRoot = 'C:\Python27',
    [string]$BuildPythonRoot = 'C:\wapt-build-python2',
    [string]$LazarusRoot = 'C:\lazarus'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Assert-FileHash {
    param(
        [string]$Path,
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Controlled input not found: $Path"
    }

    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash

    if ($Actual -ne $ExpectedSha256) {
        throw @"
SHA256 mismatch:
  File:     $Path
  Expected: $ExpectedSha256
  Actual:   $Actual
"@
    }

    Write-Host "[PASS] SHA256: $Path"
}

function Invoke-CheckedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $Process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -Wait `
        -PassThru

    if ($Process.ExitCode -ne 0) {
        throw "Command failed with exit code $($Process.ExitCode): $FilePath"
    }
}

$GitInstaller = Join-Path $BuildKit 'git\Git-2.55.0.5-64-bit.exe'
$PythonInstaller = Join-Path $BuildKit 'python\python-2.7.18-x86.msi'
$VirtualenvWheel = Join-Path $BuildKit 'python\virtualenv-15.1.0-py2.py3-none-any.whl'
$BuiltWheels = Join-Path $BuildKit 'python\built-wheels'
$BuildGitPythonWheel = Join-Path $BuiltWheels 'GitPython-2.1.15-py2.py3-none-any.whl'
$BuildGitdb2Wheel = Join-Path $BuiltWheels 'gitdb2-2.0.6-py2.py3-none-any.whl'
$BuildSmmap2Wheel = Join-Path $BuiltWheels 'smmap2-3.0.1-py2-none-any.whl'
$BuildSmmapWheel = Join-Path $BuiltWheels 'smmap-3.0.5-py2.py3-none-any.whl'
$LazarusInstaller = Join-Path $BuildKit 'lazarus\lazarus-1.8.2-fpc-3.0.4-win32.exe'

$PythonExe = Join-Path $PythonRoot 'python.exe'
$BuildPythonExe = Join-Path $BuildPythonRoot 'Scripts\python.exe'
$LazbuildExe = Join-Path $LazarusRoot 'lazbuild.exe'
$FpcExe = Join-Path $LazarusRoot 'fpc\3.0.4\bin\i386-win32\fpc.exe'

Write-Step 'Validating controlled bootstrap inputs'

Assert-FileHash $GitInstaller `
    'D065A4E23C3D9A6B5073D609B5BE0830227EC3CA053C083BA385061DDFAF94C6'

Assert-FileHash $PythonInstaller `
    'D901802E90026E9BAD76B8A81F8DD7E43C7D7E8269D9281C9E9DF7A9C40480A9'

Assert-FileHash $VirtualenvWheel `
    '39D88B533B422825D644087A21E78C45CF5AF0EF7A99A1FC9FBB7B481E5C85B0'

Assert-FileHash $BuildGitPythonWheel `
    '23B4DE99C5FC1564701301CEAD04E16AA3E47019034668327206D1B52E1E54F7'

Assert-FileHash $BuildGitdb2Wheel `
    '96BBB507D765A7F51EB802554A9CFE194A174582F772E0D89F4E87288C288B7B'

Assert-FileHash $BuildSmmap2Wheel `
    '6894F09ECB1C9B445B76506613B39233942EA387B4716C40552F43DCCEEC20E8'

Assert-FileHash $BuildSmmapWheel `
    '7BFCF367828031DC893530A29CB35EB8C8F2D7C8F2D0989354D75D24C8573714'

Assert-FileHash $LazarusInstaller `
    'B91517C673453F5AA355FFB3952E040433A8CDBBC5239BE72C869B60131B4166'

Write-Step 'Checking Git 2.55.0.windows.5'

$GitOk = $false

try {
    $GitVersion = (& git --version 2>$null).Trim()
    $GitOk = ($GitVersion -eq 'git version 2.55.0.windows.5')
} catch {
    $GitOk = $false
}

if (-not $GitOk) {
    Write-Host 'Installing controlled Git...'

    Invoke-CheckedProcess `
        $GitInstaller `
        @('/VERYSILENT','/NORESTART')

    $env:Path = 'C:\Program Files\Git\cmd;' + $env:Path
}

$GitVersion = (& git --version).Trim()

if ($GitVersion -ne 'git version 2.55.0.windows.5') {
    throw "Unexpected Git version: $GitVersion"
}

Write-Host "[PASS] $GitVersion"

Write-Step 'Checking CPython 2.7.18 x86'

$PythonOk = $false

if (Test-Path -LiteralPath $PythonExe -PathType Leaf) {
    $PythonVersion = (& $PythonExe -c "import platform,sys; print(sys.version_info[:3]); print(platform.architecture()[0])")

    if (($PythonVersion -contains '(2, 7, 18)') -and
        ($PythonVersion -contains '32bit')) {
        $PythonOk = $true
    }
}

if (-not $PythonOk) {
    Write-Host 'Installing controlled CPython 2.7.18 x86...'

    Invoke-CheckedProcess `
        'msiexec.exe' `
        @(
            '/i',
            $PythonInstaller,
            '/qn',
            '/norestart',
            "TARGETDIR=$PythonRoot"
        )
}

if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
    throw "Python executable not found after installation: $PythonExe"
}

$PythonCheck = (& $PythonExe -c "import platform,sys; print('%d.%d.%d' % sys.version_info[:3]); print(platform.architecture()[0])")

if (($PythonCheck[0] -ne '2.7.18') -or
    ($PythonCheck[1] -ne '32bit')) {
    throw "Unexpected bootstrap Python: $($PythonCheck -join ' / ')"
}

Write-Host '[PASS] CPython 2.7.18 x86'

Write-Step 'Checking virtualenv 15.1.0'

$VirtualenvOk = $false

try {
    $VirtualenvVersion = (& $PythonExe -m virtualenv --version 2>$null).Trim()
    $VirtualenvOk = ($VirtualenvVersion -eq '15.1.0')
} catch {
    $VirtualenvOk = $false
}

if (-not $VirtualenvOk) {
    Write-Host 'Installing controlled virtualenv 15.1.0 offline...'

    & $PythonExe -m pip install `
        --no-index `
        --no-deps `
        $VirtualenvWheel

    if ($LASTEXITCODE -ne 0) {
        throw "Offline virtualenv installation failed."
    }
}

$VirtualenvVersion = (& $PythonExe -m virtualenv --version).Trim()

if ($VirtualenvVersion -ne '15.1.0') {
    throw "Unexpected virtualenv version: $VirtualenvVersion"
}

Write-Host '[PASS] virtualenv 15.1.0'

Write-Step 'Preparing dedicated Python 2 build environment'

if (-not (Test-Path -LiteralPath $BuildPythonExe -PathType Leaf)) {
    if (Test-Path -LiteralPath $BuildPythonRoot) {
        throw "Build Python path exists but is not a valid virtualenv: $BuildPythonRoot"
    }

    & $PythonExe -m virtualenv --always-copy $BuildPythonRoot

    if ($LASTEXITCODE -ne 0) {
        throw 'Dedicated Python 2 build environment creation failed.'
    }
}

& $BuildPythonExe -m pip install `
    --no-index `
    --no-deps `
    $BuildGitPythonWheel `
    $BuildGitdb2Wheel `
    $BuildSmmap2Wheel `
    $BuildSmmapWheel

if ($LASTEXITCODE -ne 0) {
    throw 'Offline GitPython build dependency installation failed.'
}

$BuildPythonPackageState = (& $BuildPythonExe -c "import pkg_resources; print('|'.join([pkg_resources.get_distribution(x).version for x in ['GitPython','gitdb2','smmap2','smmap']]))").Trim()

if ($LASTEXITCODE -ne 0 -or $BuildPythonPackageState -ne '2.1.15|2.0.6|3.0.1|3.0.5') {
    throw "Unexpected dedicated build Python package state: $BuildPythonPackageState"
}

Write-Host '[PASS] Dedicated Python 2 build environment'

# ---------------------------------------------------------------------------
# Microsoft Visual C++ Compiler for Python 2.7 (VC9 x86)
# ---------------------------------------------------------------------------

Write-Step 'Checking Microsoft VC9 compiler for Python 2.7'

$VcInstaller = Join-Path $BuildKit 'windows-sdk\VCForPython27.msi'

Assert-FileHash $VcInstaller `
    '070474DB76A2E625513A5835DF4595DF9324D820F9CC97EAB2A596DCBC2F5CBF'

$VcRoot = Join-Path $env:LOCALAPPDATA `
    'Programs\Common\Microsoft\Visual C++ for Python\9.0'

$VcFiles = @(
    'vcvarsall.bat',
    'VC\bin\cl.exe',
    'VC\bin\link.exe',
    'VC\bin\lib.exe'
)

$VcComplete = $true

foreach ($File in $VcFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $VcRoot $File) -PathType Leaf)) {
        $VcComplete = $false
    }
}

if (-not $VcComplete) {
    Write-Host 'Installing controlled Microsoft VC9 compiler...'

    Invoke-CheckedProcess 'msiexec.exe' @(
        '/i',
        $VcInstaller,
        '/passive',
        '/norestart'
    )
}

foreach ($File in $VcFiles) {
    $Candidate = Join-Path $VcRoot $File

    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        throw "Microsoft VC9 component missing: $Candidate"
    }
}

$VcVars = Join-Path $VcRoot 'vcvarsall.bat'
$VcCommand = 'call "' + $VcVars + '" x86 >nul && cl.exe 2>&1'

$VcOutput = & cmd.exe /d /s /c $VcCommand 2>&1
$VcBanner = $VcOutput -join "`n"

if ($VcBanner -notmatch '32-bit C/C\+\+ Optimizing Compiler Version 15\.00\.30729\.01 for 80x86') {
    throw "Unexpected VC9 compiler version or architecture: $VcBanner"
}

Write-Host '[PASS] Microsoft VC9 15.00.30729.01 x86'

Write-Step 'Checking Lazarus 1.8.2 / FPC 3.0.4'

$LazarusOk = $false

if ((Test-Path -LiteralPath $LazbuildExe -PathType Leaf) -and
    (Test-Path -LiteralPath $FpcExe -PathType Leaf)) {

    $LazarusVersion = (& $LazbuildExe --version).Trim()
    $FpcVersion = (& $FpcExe -iV).Trim()

    if (($LazarusVersion -eq '1.8.2') -and
        ($FpcVersion -eq '3.0.4')) {
        $LazarusOk = $true
    }
}

if (-not $LazarusOk) {
    Write-Host 'Installing controlled Lazarus 1.8.2 / FPC 3.0.4...'

    Invoke-CheckedProcess `
        $LazarusInstaller `
        @(
            '/VERYSILENT',
            '/NORESTART',
            "/DIR=$LazarusRoot"
        )
}

$LazarusVersion = (& $LazbuildExe --version).Trim()
$FpcVersion = (& $FpcExe -iV).Trim()

if ($LazarusVersion -ne '1.8.2') {
    throw "Unexpected Lazarus version: $LazarusVersion"
}

if ($FpcVersion -ne '3.0.4') {
    throw "Unexpected FPC version: $FpcVersion"
}

Write-Host '[PASS] Lazarus 1.8.2'
Write-Host '[PASS] FPC 3.0.4'

Write-Step 'Windows build environment ready'

Write-Host ''
Write-Host '[PASS] Controlled Windows build prerequisites validated.'
Write-Host ''
Write-Host 'Git:             2.55.0.windows.5'
Write-Host 'Python:          2.7.18 x86'
Write-Host 'virtualenv:      15.1.0'
Write-Host "Build Python:     $BuildPythonRoot"
Write-Host 'Lazarus:         1.8.2'
Write-Host 'FPC:             3.0.4'
Write-Host 'VCForPython27:   9.0 (VC9 x86, 15.00.30729.01)'
Write-Host 'Global Inno:     not required'
