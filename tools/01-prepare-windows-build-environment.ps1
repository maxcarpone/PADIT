[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\padit-02-tools',
    [string]$BuildKit = 'C:\padit-01-kit',
    [string]$PythonRoot = (Join-Path $ToolsRoot 'Python27'),
    [string]$BuildPythonRoot = (Join-Path $ToolsRoot 'build-python2'),
    [string]$LazarusRoot = (Join-Path $ToolsRoot 'lazarus'),
    [switch]$OpenSsl35Toolchain = $true,
    [string]$GitRoot = (Join-Path $ToolsRoot 'Git'),
    [string]$InnoRoot = (Join-Path $ToolsRoot 'innosetup'),
    [string]$Vc9Root = (Join-Path $env:LOCALAPPDATA 'Programs\Common\Microsoft\Visual C++ for Python\9.0'),
    [string]$VcVars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat',
    [string]$Perl = 'C:\Strawberry\perl\bin\perl.exe',
    [string]$Nasm = 'C:\Program Files\NASM\nasm.exe',
    # Controlled offline recipes: Name, Installer, Sha256, Arguments, Probe.
    # Paths, hashes and silent options must come from validated VM inputs.
    [hashtable[]]$NativeToolInstallers = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:Path = (Join-Path $GitRoot 'cmd') + ';' + $env:Path

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

$GitInstaller = Join-Path $BuildKit 'git\Git-2.56.1-64-bit.exe'
$PythonInstaller = Join-Path $BuildKit 'python\python-2.7.18-x86.msi'
$VirtualenvWheel = Join-Path $BuildKit 'python\virtualenv-15.1.0-py2.py3-none-any.whl'
$BuiltWheels = Join-Path $BuildKit 'python\built-wheels'
$BuildGitPythonWheel = Join-Path $BuiltWheels 'GitPython-2.1.15-py2.py3-none-any.whl'
$BuildGitdb2Wheel = Join-Path $BuiltWheels 'gitdb2-2.0.6-py2.py3-none-any.whl'
$BuildSmmap2Wheel = Join-Path $BuiltWheels 'smmap2-3.0.1-py2-none-any.whl'
$BuildSmmapWheel = Join-Path $BuiltWheels 'smmap-3.0.5-py2.py3-none-any.whl'
$LazarusInstaller = Join-Path $BuildKit 'lazarus\lazarus-4.8-fpc-3.2.2-win32.exe'

$PythonExe = Join-Path $PythonRoot 'python.exe'
$BuildPythonExe = Join-Path $BuildPythonRoot 'Scripts\python.exe'
$LazbuildExe = Join-Path $LazarusRoot 'lazbuild.exe'
$FpcExe = Join-Path $LazarusRoot 'fpc\3.2.2\bin\i386-win32\fpc.exe'

Write-Step 'Validating controlled bootstrap inputs'

Assert-FileHash $GitInstaller `
    'C330C72E10B408CC39994BFEFDB63542B0D93D21699325C3E0BD874AF8A5A559'

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
    '81DA36A9AEAFEE55EAE29AAA636CCDB009F2BCEEE3215A87EC99F6F3F81B709E'

Write-Step 'Checking Git 2.56.1.windows.1'

$GitOk = $false

try {
    $GitVersion = (& git --version 2>$null).Trim()
    $GitOk = ($GitVersion -eq 'git version 2.56.1.windows.1')
} catch {
    $GitOk = $false
}

if (-not $GitOk) {
    Write-Host 'Installing controlled Git...'

    Invoke-CheckedProcess `
        $GitInstaller `
        @('/VERYSILENT','/NORESTART', "/DIR=`"$GitRoot`"")

    $env:Path = (Join-Path $GitRoot 'cmd') + ';' + $env:Path
}

$GitVersion = (& git --version).Trim()

if ($GitVersion -ne 'git version 2.56.1.windows.1') {
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

$BuildPythonPackageState = & $BuildPythonExe -c "import pkg_resources; names=['GitPython','gitdb2','smmap2','smmap']; installed=dict((d.key,d.version) for d in pkg_resources.working_set); print('|'.join(installed.get(n.lower(),'missing') for n in names))"
if ($LASTEXITCODE -ne 0 -or ($BuildPythonPackageState -join '').Trim() -ne '2.1.15|2.0.6|3.0.1|3.0.5') {
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


$VcRoot = $Vc9Root

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

$Vc9Vars = Join-Path $VcRoot 'vcvarsall.bat'
$VcCommand = 'call "' + $Vc9Vars + '" x86 >nul && cl.exe 2>&1'

$VcOutput = & cmd.exe /d /s /c $VcCommand 2>&1
$VcBanner = $VcOutput -join "`n"

if ($VcBanner -notmatch '32-bit C/C\+\+ Optimizing Compiler Version 15\.00\.30729\.01 for 80x86') {
    throw "Unexpected VC9 compiler version or architecture: $VcBanner"
}

Write-Host '[PASS] Microsoft VC9 15.00.30729.01 x86'

Write-Step 'Checking Lazarus 4.8 / FPC 3.2.2'

$LazarusOk = $false

if ((Test-Path -LiteralPath $LazbuildExe -PathType Leaf) -and
    (Test-Path -LiteralPath $FpcExe -PathType Leaf)) {

    $LazarusVersion = (& $LazbuildExe --version).Trim()
    $FpcVersion = (& $FpcExe -iV).Trim()

    if (($LazarusVersion -eq '4.8') -and
        ($FpcVersion -eq '3.2.2')) {
        $LazarusOk = $true
    }
}

if (-not $LazarusOk) {
    Write-Host 'Installing controlled Lazarus 4.8 / FPC 3.2.2...'

    Invoke-CheckedProcess `
        $LazarusInstaller `
        @(
            '/VERYSILENT',
            '/NORESTART',
            "/DIR=`"$LazarusRoot`""
        )
}

$LazarusVersion = (& $LazbuildExe --version).Trim()
$FpcVersion = (& $FpcExe -iV).Trim()

if ($LazarusVersion -ne '4.8') {
    throw "Unexpected Lazarus version: $LazarusVersion"
}

if ($FpcVersion -ne '3.2.2') {
    throw "Unexpected FPC version: $FpcVersion"
}

Write-Host '[PASS] Lazarus 4.8'
Write-Host '[PASS] FPC 3.2.2'

Write-Step 'Installing controlled Windows SDK signing tools'
$SignToolSource = Join-Path $BuildKit 'windows-sdk\signtool'
$SignToolRoot = Join-Path $ToolsRoot 'signtool'
$SignToolFiles = @{
    'appxsip.dll'                                            = 'A7F956DC76B0330B557BE3882B66D49F75ED366A7A9AE4C5F9BB72E410C44F73'
    'cert2spc.exe'                                           = '607D2F55A06D79243FAFA5CAF60493EDAE38D68F96C8652F69389A812CC30C38'
    'dgssexwithfilehandlelib.dll'                            = '47BC33DA68E98E0618FE17C0BB002E3AC746491EA9DEE3A691736009D5F71596'
    'makecat.exe'                                            = '39AF5BE7A9CFF87A6C861661B7ACFBD5FB68A14C4AC68F6DD736E3775B5A3244'
    'makecat.exe.manifest'                                   = '459D995E14CF420836EC7566B60C3B134215F7ACD2C9B3B48A0B268A37FDC1F4'
    'Microsoft.Windows.Build.Appx.AppxPackaging.dll.manifest'= 'B50D228857D9CD6509854FEACDC153A78804BE4312BF699298DBF6A5BD846DDD'
    'Microsoft.Windows.Build.Appx.AppxSip.dll.manifest'      = 'BF9DADC2A05E46F479F8BDC4EBDA515682449CFE04794AFB9B8A9CF12EDF7F4E'
    'Microsoft.Windows.Build.Appx.OpcServices.dll.manifest'  = '7BABCE6A576B434C71B93797AC6968963A9C23FEEA56D8D45FAEEAA8175907EC'
    'Microsoft.Windows.Build.Signing.mssign32.dll.manifest'  = 'E0C65F5B5F5AE116ABBB566DC7DDF95B666FC9A7F327AFA67502100954D8D713'
    'Microsoft.Windows.Build.Signing.wintrust.dll.manifest'  = '9A6E1A316F4148EAACE69326F5F99A6A7AC4E9B58B5C22082F6603DD964BFAD9'
    'mssign32.dll'                                           = '8E8667AB09456006D9D0582DDA340F2C887B1F1D8D33FB8B89A49533CDC768F9'
    'opcservices.dll'                                        = '4B46756E8278B02E3F0C33EE4ED65C15C14ECDEA0012BDB570DE43EB72172AC9'
    'signtool.exe'                                           = '92A5751C292C7D3C41619CA0F0A28D1121CF55EF55D75DCCE394BF01F0194193'
    'signtool.exe.manifest'                                  = 'C1A768E47B3D054EEE0D8AB9027EBA122A52BF6A058AE1C02E4DDCB96CF4B09F'
    'wintrust.dll'                                           = '82DA576E1D3701666296E24B69F0AF11D0B96592348DF8EE7A5F8FC9F4513EE2'
    'wintrust.dll.ini'                                       = 'CA458C3FF25D27A7C61674EE9547F13FC70C7208583CBFBA75CA39B4098FA21C'
}
foreach ($File in $SignToolFiles.GetEnumerator()) {
    $Source = Join-Path $SignToolSource $File.Key
    $Target = Join-Path $SignToolRoot $File.Key
    Assert-FileHash $Source $File.Value
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ne $File.Value) {
        New-Item -ItemType Directory -Path $SignToolRoot -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
    Assert-FileHash $Target $File.Value
}

Write-Step 'Checking Inno Setup 7.1.1 x64'
$InnoInstaller = Join-Path $BuildKit 'inno-setup\innosetup-7.1.1-x64.exe'
Assert-FileHash $InnoInstaller '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
$Iscc = Join-Path $InnoRoot 'ISCC.exe'
$InnoOk = (Test-Path -LiteralPath $Iscc -PathType Leaf) -and
    ((Get-Item -LiteralPath $Iscc).VersionInfo.ProductVersion -match '^7\.1\.1(?:\D|$)')
if (-not $InnoOk) {
    Invoke-CheckedProcess $InnoInstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=`"$InnoRoot`"")
}
if (-not (Test-Path -LiteralPath $Iscc -PathType Leaf) -or
    (Get-Item -LiteralPath $Iscc).VersionInfo.ProductVersion -notmatch '^7\.1\.1(?:\D|$)') {
    throw 'Inno Setup 7.1.1 validation failed'
}
$InnoBytes = [IO.File]::ReadAllBytes($Iscc)
$InnoPe = [BitConverter]::ToInt32($InnoBytes, 0x3c)
if ([BitConverter]::ToUInt16($InnoBytes, $InnoPe + 4) -ne 0x8664) {
    throw 'Inno Setup compiler must be x64'
}
Write-Host '[PASS] Inno Setup 7.1.1 x64'

Write-Step 'Preparing mandatory OpenSSL 3.5.9 native tools'
if (-not $OpenSsl35Toolchain) {
    throw 'OpenSSL 3.5.9 toolchain is mandatory; OpenSSL 1.x fallback removed.'
}
foreach ($Recipe in $NativeToolInstallers) {
    if (-not (Test-Path -LiteralPath $Recipe.Probe -PathType Leaf)) {
        Assert-FileHash $Recipe.Installer $Recipe.Sha256
        Invoke-CheckedProcess $Recipe.Installer $Recipe.Arguments
        if (-not (Test-Path -LiteralPath $Recipe.Probe -PathType Leaf)) {
            throw "Native tool installation failed: $($Recipe.Name)"
        }
    }
}
foreach ($Tool in @($VcVars, $Perl, $Nasm)) {
    if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
        throw "BLOCKED: OpenSSL 3.5.9 prerequisite missing: $Tool. Supply a controlled offline NativeToolInstallers recipe to 01."
    }
}
$VcBanner = (& cmd.exe /d /s /c ('call "' + $VcVars + '" x86 >nul && cl.exe /Bv 2>&1')) -join "`n"
if ($VcBanner -notmatch '19\.44\.35229' -or $VcBanner -notmatch '(80x86|x86)') {
    throw "Unexpected MSVC 2022 x86 compiler: $VcBanner"
}
& $Perl -v
if ($LASTEXITCODE -ne 0) { throw 'Perl validation failed' }
& $Nasm -v
if ($LASTEXITCODE -ne 0) { throw 'NASM validation failed' }
foreach ($Tool in @('tar.exe', 'git.exe')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { throw "Missing tool: $Tool" }
}
Write-Host '[PASS] Windows build tools validated. Runtime construction remains to be validated by 02.'
