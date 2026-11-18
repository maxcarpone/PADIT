#requires -Version 5.1
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
    [string]$MsvcInstallPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
    [string]$VcVars = (Join-Path $MsvcInstallPath 'VC\Auxiliary\Build\vcvarsall.bat'),
    [string]$Perl = (Join-Path $ToolsRoot 'strawberry\perl\bin\perl.exe'),
    [string]$Nasm = (Join-Path $ToolsRoot 'nasm\nasm.exe'),
    [string]$PerlArchive,
    [string]$NasmArchive,
    # Operator-controlled local layout; no Microsoft hash or archive name assumed.
    [string]$MsvcLayout,
    [string]$MsvcBootstrapper,
    [string]$MsvcBootstrapperSha256,
    [string]$VsWhere = (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
    [string]$WindowsSdkRoot = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10')
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

# Require the pinned archives to validate portable release identity on reuse too.
$PerlHash = '6A081A811781C30ACA51DBC036AFD93092AF91E3297901F02C17043795A10690'
$NasmHash = '161D0BFAFF53C2F9E9F3E69FD0672323EBABAFD1268976A5CEC11BE92A19AEE7'
Assert-FileHash $PerlArchive $PerlHash
Assert-FileHash $NasmArchive $NasmHash


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

# Uninstall metadata identifies the installation and its declared version.
function Test-InnoRegistration {
    param([string]$Root)

    $ExpectedLocation = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root).TrimEnd('\')
    $UninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $Locations = @(
        @{ Hive = 'LocalMachine'; View = 'Registry64' }
        @{ Hive = 'LocalMachine'; View = 'Registry32' }
        @{ Hive = 'CurrentUser'; View = 'Default' }
    )
    $MatchingVersion = $false
    $OtherVersion = $false

    foreach ($Location in $Locations) {
        $BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Location.Hive, $Location.View)
        try {
            $UninstallKey = $BaseKey.OpenSubKey($UninstallPath)
            if ($null -eq $UninstallKey) { continue }
            try {
                foreach ($Name in $UninstallKey.GetSubKeyNames()) {
                    $Entry = $UninstallKey.OpenSubKey($Name)
                    if ($null -eq $Entry) { continue }
                    try {
                        if ($Entry.GetValue('DisplayName') -notmatch '^Inno Setup(?: \d|$)') { continue }
                        $InstallLocation = $Entry.GetValue('InstallLocation')
                        if ($InstallLocation -isnot [string] -or
                            $InstallLocation -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2})') { continue }
                        try {
                            $RegisteredLocation = [IO.Path]::GetFullPath($InstallLocation).TrimEnd('\')
                        }
                        catch [System.ArgumentException], [System.NotSupportedException], [System.IO.PathTooLongException] {
                            continue
                        }
                        if (-not [string]::Equals($RegisteredLocation, $ExpectedLocation, [StringComparison]::OrdinalIgnoreCase)) {
                            continue
                        }

                        $Version = $Entry.GetValue('DisplayVersion')
                        if ($Version -is [string] -and $Version -ceq '7.1.1') {
                            $MatchingVersion = $true
                        }
                        else {
                            $OtherVersion = $true
                        }
                    }
                    finally { $Entry.Dispose() }
                }
            }
            finally { $UninstallKey.Dispose() }
        }
        finally { $BaseKey.Dispose() }
    }

    if ($MatchingVersion -and $OtherVersion) {
        throw "Conflicting Inno Setup versions in Windows Uninstall for: $ExpectedLocation"
    }
    return $MatchingVersion
}

function Assert-InnoCompiler {
    param([string]$Root)

    $Iscc = Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)) 'ISCC.exe'
    if (-not (Test-Path -LiteralPath $Iscc -PathType Leaf)) {
        throw "Inno Setup compiler missing: $Iscc"
    }

    $Bytes = [IO.File]::ReadAllBytes($Iscc)
    if ($Bytes.Length -lt 0x40 -or [BitConverter]::ToUInt16($Bytes, 0) -ne 0x5A4D) {
        throw "Invalid ISCC executable header: $Iscc"
    }
    $PeOffset = [BitConverter]::ToInt32($Bytes, 0x3c)
    if ($PeOffset -lt 0x40 -or $PeOffset -gt ($Bytes.Length - 6) -or
        [BitConverter]::ToUInt32($Bytes, $PeOffset) -ne 0x00004550 -or
        [BitConverter]::ToUInt16($Bytes, $PeOffset + 4) -ne 0x8664) {
        throw "Inno Setup compiler must be an x64 PE executable: $Iscc"
    }

    $HelpOutput = & cmd.exe /d /c ('"' + $Iscc + '" /? 2>&1')
    if ($LASTEXITCODE -ne 0 -or ($HelpOutput -join [Environment]::NewLine) -notmatch '(?m)^Inno Setup 7 Command-Line Compiler\s*$') {
        throw "Inno Setup 7 compiler help failed (exit $LASTEXITCODE): $Iscc"
    }
}

Write-Step 'Checking Inno Setup 7.1.1 x64'
$InnoInstaller = Join-Path $BuildKit 'inno-setup\innosetup-7.1.1-x64.exe'
Assert-FileHash $InnoInstaller '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
if (-not (Test-InnoRegistration $InnoRoot)) {
    Invoke-CheckedProcess $InnoInstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=`"$InnoRoot`"")
    if (-not (Test-InnoRegistration $InnoRoot)) {
        throw "Inno Setup 7.1.1 registration not found in Windows Uninstall for: $InnoRoot"
    }
}
Assert-InnoCompiler $InnoRoot
Write-Host '[PASS] Inno Setup 7.1.1 x64'

# Layout ownership and redistribution rights remain the operator's responsibility.
function Assert-MicrosoftBinary {
    param([string]$Path, [int]$Machine = 0)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing Microsoft binary: $Path" }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "Invalid Microsoft Authenticode signature: $Path"
    }
    if ($Machine) {
        $Bytes = [IO.File]::ReadAllBytes($Path)
        $Pe = [BitConverter]::ToInt32($Bytes, 0x3c)
        if ([BitConverter]::ToUInt16($Bytes, $Pe + 4) -ne $Machine) { throw "Wrong PE architecture: $Path" }
    }
}

function Test-Msvc {
    if (-not (Test-Path -LiteralPath $VsWhere -PathType Leaf) -or
        -not (Test-Path -LiteralPath $VcVars -PathType Leaf)) { return $false }
    Assert-MicrosoftBinary $VsWhere
    $Json = & $VsWhere -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.Windows11SDK.26100 -format json
    if ($LASTEXITCODE -ne 0) { return $false }
    $Instances = @($Json -join [Environment]::NewLine | ConvertFrom-Json)
    $Matching = @($Instances | Where-Object {
        [IO.Path]::GetFullPath((Join-Path $_.installationPath 'VC\Auxiliary\Build\vcvarsall.bat')) -ieq [IO.Path]::GetFullPath($VcVars)
    })
    if ($Matching.Count -eq 0) { return $false }
    # Pin SDK selection too: another installed SDK must not silently replace 26100.
    $SdkVersions = @(Get-ChildItem -LiteralPath (Join-Path $WindowsSdkRoot 'Include') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^10\.0\.26100\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
    if ($SdkVersions.Count -eq 0) { return $false }
    $SdkVersion = $SdkVersions[0].Name
    foreach ($Relative in @("Include\$SdkVersion\um\Windows.h", "Include\$SdkVersion\ucrt\stdio.h",
        "Lib\$SdkVersion\um\x86\kernel32.lib", "Lib\$SdkVersion\ucrt\x86\ucrt.lib")) {
        if (-not (Test-Path -LiteralPath (Join-Path $WindowsSdkRoot $Relative) -PathType Leaf)) { return $false }
    }
    $Command = 'call "' + $VcVars + '" x86 ' + $SdkVersions[0].Name + ' >nul && cl.exe /Bv 2>&1'
    $Banner = (& cmd.exe /d /s /c $Command) -join [Environment]::NewLine
    return ($Banner -match '19\.44\.35229(?:\D|$)' -and $Banner -match '(80x86|x86)')
}

Write-Step 'Preparing mandatory OpenSSL 3.5.9 native tools'
if (-not $OpenSsl35Toolchain) { throw 'OpenSSL 3.5.9 is mandatory; no OpenSSL 1.x fallback.' }
if (-not (Test-Msvc)) {
    if (-not $MsvcLayout -or -not $MsvcBootstrapper -or $MsvcBootstrapperSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'BLOCKED: supply a controlled local MSVC 2022 layout, its bootstrapper and independently validated SHA256.'
    }
    $LayoutFull = [IO.Path]::GetFullPath($MsvcLayout).TrimEnd('\')
    $BootstrapperFull = [IO.Path]::GetFullPath($MsvcBootstrapper)
    if (-not (Test-Path -LiteralPath $LayoutFull -PathType Container) -or
        -not $BootstrapperFull.StartsWith($LayoutFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Bootstrapper must belong to the controlled local layout.'
    }
    Assert-FileHash $BootstrapperFull $MsvcBootstrapperSha256
    Assert-MicrosoftBinary $BootstrapperFull
    # Verify the layout before installation. No online repair or download.
    Invoke-CheckedProcess $BootstrapperFull @('--layout', ('"' + $LayoutFull + '"'), '--verify', '--quiet', '--wait')
    $Process = Start-Process -FilePath $BootstrapperFull -ArgumentList @(
        '--quiet', '--wait', '--norestart', '--noWeb',
        '--installPath', ('"' + $MsvcInstallPath + '"'),
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    ) -Wait -PassThru
    if ($Process.ExitCode -eq 3010) { throw 'BLOCKED: MSVC requires a reboot; rerun 01 afterwards.' }
    if ($Process.ExitCode -ne 0) { throw "MSVC installation failed: $($Process.ExitCode)" }
    if (-not (Test-Msvc)) { throw 'BLOCKED: installed MSVC components/version do not match the required toolchain.' }
}
Write-Host '[PASS] MSVC 2022 19.44.35229 x86 and required components'

$SdkBins = @(Get-ChildItem -LiteralPath (Join-Path $WindowsSdkRoot 'bin') -Directory |
    Where-Object { $_.Name -match '^10\.0\.26100\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
if ($SdkBins.Count -eq 0) { throw 'BLOCKED: Windows SDK 26100 signing tools missing.' }
foreach ($Arch in @('x86','x64')) {
    $SdkSignTool = Join-Path $SdkBins[0].FullName "$Arch\signtool.exe"
    $Machine = 0x14c
    if ($Arch -eq 'x64') { $Machine = 0x8664 }
    Assert-MicrosoftBinary $SdkSignTool $Machine
    if ((Get-Item -LiteralPath $SdkSignTool).VersionInfo.ProductVersion -notmatch '^10\.0\.26100\.') {
        throw "Unexpected SDK SignTool version: $SdkSignTool"
    }
}
Write-Host "[PASS] Microsoft SDK SignTool x86/x64: $($SdkBins[0].FullName)"

function Find-7Zip {
    $Command = Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($Command) { return $Command.Source }

    foreach ($Root in @($env:ProgramW6432, $env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))) {
        if ($Root) {
            $Candidate = Join-Path $Root '7-Zip\7z.exe'
            if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
        }
    }
}

function Expand-ControlledPortable {
    param([string]$Archive, [string]$Hash, [string]$Destination)
    if (-not $Archive) { throw "BLOCKED: supply the validated portable archive for $Destination" }
    $Archive = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Archive)
    $Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    if (Test-Path -LiteralPath $Destination) {
        throw "BLOCKED: destination already exists with a nonconforming tool: $Destination"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Hold a read handle throughout validation and extraction.
    $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        Assert-FileHash $Archive $Hash
        $Stage = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.portable-' + [guid]::NewGuid().ToString('N'))
        $Targets = @{}
        foreach ($Entry in $Zip.Entries) {
            $RelativePath = $Entry.FullName.Replace('/', '\')
            if ($RelativePath.EndsWith('\')) { $RelativePath = $RelativePath.Substring(0, $RelativePath.Length - 1) }
            foreach ($Part in ($RelativePath -split '\\')) {
                if (-not $Part -or $Part -match '[<>:"|?*\x00-\x1f]|[ .]$' -or
                    $Part -match '^(?:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3]) *(?:\.|$)') {
                    throw "BLOCKED: unsafe ZIP path: $($Entry.FullName)"
                }
            }
            $Attributes = $Entry.ExternalAttributes
            if (($Attributes -band 0xF0000000) -eq 0xA0000000 -or ($Attributes -band 0x400)) {
                throw "BLOCKED: link or reparse point in ZIP: $($Entry.FullName)"
            }
            if ($Targets.ContainsKey($RelativePath)) {
                throw "BLOCKED: duplicate ZIP path: $($Entry.FullName)"
            }
            $Targets[$RelativePath] = $Entry
        }

        $SevenZip = Find-7Zip
        $Method = 'Expand-Archive (.NET)'
        if ($SevenZip) { $Method = "7-Zip ($SevenZip)" }
        Write-Host "[INFO] Extracting $Archive with $Method"
        $Timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            [IO.Directory]::CreateDirectory($Stage) | Out-Null
            if ($SevenZip) {
                & $SevenZip x -tzip -y -spd "-o$Stage" -- $Archive | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "7-Zip extraction failed with exit code $($LASTEXITCODE): $Archive"
                }
            }
            else {
                Expand-Archive -LiteralPath $Archive -DestinationPath $Stage
            }
        }
        finally {
            $Timer.Stop()
            Write-Host ('[INFO] Extraction with {0} took {1:F2} s' -f $Method, $Timer.Elapsed.TotalSeconds)
        }

        foreach ($RelativePath in $Targets.Keys) {
            $Entry = $Targets[$RelativePath]
            $Target = [IO.Path]::Combine($Stage, $RelativePath)
            if ($Entry.FullName -match '[/\\]$') {
                if (-not [IO.Directory]::Exists($Target)) {
                    throw "BLOCKED: missing extracted directory: $Target"
                }
            }
            else {
                $File = [IO.FileInfo]::new($Target)
                if (-not $File.Exists -or $File.Length -ne $Entry.Length) {
                    throw "BLOCKED: missing or incomplete extracted file: $Target"
                }
            }
        }
        # A failed extraction must never be reused from the final destination.
        [IO.Directory]::Move($Stage, $Destination)
    }
    finally { $Zip.Dispose() }
}
function Test-ArchiveExecutable {
    param([string]$Archive, [string]$Executable, [string]$Name)
    # The archive hash pins the full portable release (including Perl's .1 build).
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $Entries = @($Zip.Entries | Where-Object { $_.Name -ieq $Name })
        if ($Entries.Count -ne 1) { throw "BLOCKED: ambiguous executable in portable archive: $Archive" }
        $Stream = $Entries[0].Open()
        $Hasher = [Security.Cryptography.SHA256]::Create()
        try { $Hash = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-','') }
        finally { $Stream.Dispose(); $Hasher.Dispose() }
        return ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -eq $Hash)
    }
    finally { $Zip.Dispose() }
}
function Test-Perl {
    if (-not (Test-Path -LiteralPath $Perl -PathType Leaf)) { return $false }
    if (-not (Test-ArchiveExecutable $PerlArchive $Perl 'perl.exe')) { return $false }
    $Version = & $Perl -MConfig -e 'printf q{v%vd|%s},$^V,$Config{archname}'
    return ($LASTEXITCODE -eq 0 -and ($Version -join '') -match '^v5\.42\.3\|MSWin32-x64-')
}
function Test-Nasm {
    if (-not (Test-Path -LiteralPath $Nasm -PathType Leaf)) { return $false }
    if (-not (Test-ArchiveExecutable $NasmArchive $Nasm 'nasm.exe')) { return $false }
    $Version = & $Nasm -v
    $ExitCode = $LASTEXITCODE
    $Bytes = [IO.File]::ReadAllBytes($Nasm)
    $Pe = [BitConverter]::ToInt32($Bytes, 0x3c)
    return ($ExitCode -eq 0 -and ($Version -join '') -match '^NASM version 3\.02(?:\s|$)' -and
        [BitConverter]::ToUInt16($Bytes, $Pe + 4) -eq 0x8664)
}
if (-not (Test-Perl)) {
    $PerlRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Perl))
    Expand-ControlledPortable $PerlArchive $PerlHash $PerlRoot
}
if (-not (Test-Nasm)) {
    $NasmRoot = Split-Path -Parent $Nasm
    Expand-ControlledPortable $NasmArchive $NasmHash $NasmRoot
    # Official NASM ZIP may contain a versioned top-level directory.
    if (-not (Test-Path -LiteralPath $Nasm -PathType Leaf)) {
        $Candidates = @(Get-ChildItem -LiteralPath $NasmRoot -Recurse -File -Filter nasm.exe)
        if ($Candidates.Count -ne 1) { throw 'BLOCKED: ambiguous NASM portable archive layout.' }
        Get-ChildItem -LiteralPath $Candidates[0].DirectoryName | Copy-Item -Destination $NasmRoot -Recurse
    }
}
if (-not (Test-Perl)) { throw 'BLOCKED: Strawberry Perl 5.42.3.1 x64 portable validation failed.' }
if (-not (Test-Nasm)) { throw 'BLOCKED: NASM 3.02 x64 portable validation failed.' }
foreach ($Tool in @('tar.exe', 'git.exe')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { throw "Missing tool: $Tool" }
}
Write-Host "[PASS] Native tools prepared. Pass -VcVars '$VcVars' -Perl '$Perl' -Nasm '$Nasm' to 02."
Write-Host '[PASS] Tool probes completed; native compilation and runtime construction remain to be validated by 02.'
