[CmdletBinding()]
param(
    [string]$ToolsRoot = 'C:\padit-02-tools',
    [string]$SourceRoot,
    [string]$BuildKit = 'C:\padit-01-kit',
    [string]$Runtime = 'C:\padit-03-runtime',
    [string]$BuildPython = (Join-Path $ToolsRoot 'build-python2\Scripts\python.exe'),
    [string]$Output = 'C:\padit-04-product',
    [string]$Worktree,
    [string]$Lazarus = (Join-Path $ToolsRoot 'lazarus'),
    [string]$LazarusPcp = (Join-Path $ToolsRoot 'lazarus-pcp'),
    [string]$InnoRoot = (Join-Path $ToolsRoot 'innosetup'),
    [string]$WindowsSdkRoot = (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits\10'),
    [ValidateSet('x86','x64')][string]$SignToolArchitecture = 'x86',
    [string]$SignKey,
    [string]$SignKeyPasswordFile,
    [switch]$Force
)

if (-not $SourceRoot) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}

if (-not $Worktree) { $Worktree = $SourceRoot }
if ([IO.Path]::GetFullPath($Worktree) -ine [IO.Path]::GetFullPath($SourceRoot)) {
    throw 'SourceRoot and Worktree must identify the same existing source directory.'
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))) {
    throw 'Product compilation requires a .git file or directory at SourceRoot.'
}
$ErrorActionPreference = 'Stop'
$env:Path = (Join-Path $ToolsRoot 'Git\cmd') + ';' + $env:Path

function Assert-File {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file missing: $Path"
    }

    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) {
            throw "SHA256 mismatch: $Path`nExpected: $Sha256`nActual:   $actual"
        }
    }
}

function Assert-Directory {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory missing: $Path"
    }
}

function Assert-SafeDisposablePath {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string[]]$ProtectedPaths
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')

    if ([IO.Path]::GetPathRoot($fullPath).TrimEnd('\') -eq $fullPath) {
        throw "Refusing to use drive root as disposable path: $fullPath"
    }

    foreach ($protected in $ProtectedPaths) {
        $protectedFull = [IO.Path]::GetFullPath($protected).TrimEnd('\')

        $fullPrefix = $fullPath + '\'
        $protectedPrefix = $protectedFull + '\'

        if (
            $fullPath -ieq $protectedFull -or
            $fullPrefix.StartsWith($protectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $protectedPrefix.StartsWith($fullPrefix, [StringComparison]::OrdinalIgnoreCase)
        ) {
            throw "Disposable path overlaps protected path: $fullPath <-> $protectedFull"
        }
    }
}

$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$BuildKit   = [IO.Path]::GetFullPath($BuildKit)
$Runtime     = [IO.Path]::GetFullPath($Runtime)
$BuildPython = [IO.Path]::GetFullPath($BuildPython)
$Output      = [IO.Path]::GetFullPath($Output)
$Worktree   = [IO.Path]::GetFullPath($Worktree)
$Lazarus    = [IO.Path]::GetFullPath($Lazarus)
$LazarusPcp = [IO.Path]::GetFullPath($LazarusPcp)

$ProtectedPaths = @(
    $SourceRoot,
    $BuildKit,
    $Runtime,
    $InnoRoot,
    $BuildPython,
    $Lazarus
)

Assert-SafeDisposablePath -Path $Output     -ProtectedPaths $ProtectedPaths
Assert-SafeDisposablePath -Path $LazarusPcp -ProtectedPaths $ProtectedPaths

Assert-SafeDisposablePath -Path $Output `
    -ProtectedPaths @($Worktree, $LazarusPcp)


Assert-SafeDisposablePath -Path $LazarusPcp `
    -ProtectedPaths @($Output, $Worktree)

Write-Host "PADIT Windows product assembly"
Write-Host "Source : $SourceRoot"
Write-Host "Kit    : $BuildKit"
Write-Host "Runtime: $Runtime"
Write-Host "Build Python: $BuildPython"
Write-Host "Output : $Output"
Write-Host "Worktree: $Worktree"
Write-Host "Lazarus : $Lazarus"
Write-Host "PCP     : $LazarusPcp"
Write-Host ""

# ----------------------------------------------------------------------
# Controlled inputs
# ----------------------------------------------------------------------

$Vc90 = Join-Path $BuildKit 'runtime\vc90-crt'
$Tools = Join-Path $BuildKit 'runtime\tools'
$Nssm = Join-Path $BuildKit 'runtime\nssm'

$SigningPublic = Join-Path $BuildKit 'signing\public'
$SigningRootCer = Join-Path $SigningPublic 'Thouet-Software-Signing-Root-CA.cer'
Assert-Directory $SourceRoot
Assert-Directory $BuildKit
Assert-Directory $Runtime
Assert-File $BuildPython
Assert-File (Join-Path $Lazarus 'lazbuild.exe')
Assert-File (Join-Path $Runtime 'waptpython.exe')

Assert-File (Join-Path $Vc90 'msvcr90.dll') `
    '8E7FE1A1F3550C479FFD86A77BC9D10686D47F8727025BB891D8F4F0259354C8'

Assert-File (Join-Path $Vc90 'msvcp90.dll') `
    '06918CF99AD26CD6CF106881C0D5BDB212DC0BAC4549805C9F5906E3D03D152C'

Assert-File (Join-Path $Vc90 'msvcm90.dll') `
    '7A74DA389FBD10A710C294C2E914DC6F18E05F028F07958A2FA53AC44F0E4B90'

Assert-File (Join-Path $Vc90 'Microsoft.VC90.CRT.manifest') `
    '0C838C4262F99F27495A7C2A1BF4EC8F482D1C9BC2493C3C19B9360F1A06B8EB'

Assert-File (Join-Path $Tools 'dmidecode.exe') `
    '7E14292571834665F0788C1BDE495421F704FAB74679127CBE35AF65714587F2'

Assert-File (Join-Path $Nssm 'win32\nssm.exe') `
    'BCE355F89B95D9F7C7441563D03A6CE6CD429DB865920F66561C0D90D1E0E285'

Assert-File (Join-Path $Nssm 'win64\nssm.exe') `
    '2900F26D2ED74F4D5DB77CBCCBD4F2185FCCE2625A1BE724120984AC2418989B'

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

    $HelpOutput = & cmd.exe /d /s /c ('""' + $Iscc + '" /? 2>&1"')
    if ($LASTEXITCODE -ne 0 -or ($HelpOutput -join [Environment]::NewLine) -notmatch '(?m)^Inno Setup 7 Command-Line Compiler\s*$') {
        throw "Inno Setup 7 compiler help failed (exit $LASTEXITCODE): $Iscc"
    }
}

if (-not (Test-InnoRegistration $InnoRoot)) {
    throw "Run 01 first: Inno Setup 7.1.1 registration not found in Windows Uninstall for: $InnoRoot"
}
Assert-InnoCompiler $InnoRoot
Assert-File $SigningRootCer `
    '5BB7881D601856F1EE55C7A7B88E988751751779DEE1AB08D21DD319B1690E7A'

Write-Host "[PASS] Controlled Authenticode Root CA certificate validated."


# Use the SDK installation directly. No kit-maintained Microsoft binary hashes.
$SdkBins = @(Get-ChildItem -LiteralPath (Join-Path $WindowsSdkRoot 'bin') -Directory |
    Where-Object { $_.Name -match '^10\.0\.26100\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
if ($SdkBins.Count -eq 0) { throw 'Run 01 first: Windows SDK 26100 is required.' }
$SignTool = Join-Path $SdkBins[0].FullName "$SignToolArchitecture\signtool.exe"
Assert-File $SignTool
$SdkSignature = Get-AuthenticodeSignature -LiteralPath $SignTool
if ($SdkSignature.Status -ne 'Valid' -or $SdkSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
    throw "Invalid Microsoft Authenticode signature: $SignTool"
}
if ((Get-Item -LiteralPath $SignTool).VersionInfo.ProductVersion -notmatch '^10\.0\.26100\.') {
    throw "Unexpected SDK SignTool version: $SignTool"
}
$SignToolBytes = [IO.File]::ReadAllBytes($SignTool)
$SignToolPe = [BitConverter]::ToInt32($SignToolBytes, 0x3c)
$SignToolMachine = 0x14c
if ($SignToolArchitecture -eq 'x64') { $SignToolMachine = 0x8664 }
if ([BitConverter]::ToUInt16($SignToolBytes, $SignToolPe + 4) -ne $SignToolMachine) {
    throw "Wrong SDK SignTool architecture: $SignTool"
}
$SignToolHash = (Get-FileHash -LiteralPath $SignTool -Algorithm SHA256).Hash
Write-Host "[PASS] Microsoft Windows SDK 26100 SignTool validated: $SignTool"
# Runtime must be autonomous and already validated.
Assert-File (Join-Path $Runtime 'waptpython.exe')
Assert-File (Join-Path $Runtime 'waptpythonw.exe')
Assert-File (Join-Path $Runtime 'python27.dll')
Assert-File (Join-Path $Runtime 'pythoncom27.dll')
Assert-File (Join-Path $Runtime 'pythoncomloader27.dll')
Assert-File (Join-Path $Runtime 'pywintypes27.dll')
$OpenSsl3Runtime = Test-Path -LiteralPath (Join-Path $Runtime 'libcrypto-3.dll') -PathType Leaf

if ($OpenSsl3Runtime) {
    foreach ($Name in @('libcrypto-3.dll', 'libssl-3.dll', 'openssl.cnf', 'ossl-modules\legacy.dll', 'DLLs\_ssl.pyd', 'DLLs\_hashlib.pyd')) {
        Assert-File (Join-Path $Runtime $Name)
    }
    foreach ($Name in @('libeay32.dll', 'ssleay32.dll')) {
        if (Test-Path -LiteralPath (Join-Path $Runtime $Name)) {
            throw "Mixed OpenSSL runtime: $Name"
        }
    }
    Write-Host '[PASS] OpenSSL 3 packaging inputs'
}
else {
    throw 'BLOCKED: OpenSSL 3.5.9 runtime required; validate 02. OpenSSL 1.x is unsupported.'
}
Assert-File (Join-Path $Runtime 'openssl.exe')
$PreviousRuntimePath = $env:PATH
try {
    $env:PATH = "$Runtime;$Runtime\DLLs;$PreviousRuntimePath"
    $RuntimeSslVersion = & (Join-Path $Runtime 'waptpython.exe') -c 'import ssl; print(ssl.OPENSSL_VERSION)'
}
finally {
    $env:PATH = $PreviousRuntimePath
}
if ($LASTEXITCODE -ne 0 -or ($RuntimeSslVersion -join '') -notmatch '^OpenSSL 3\.5\.9(?:\s|$)') {
    throw "BLOCKED: runtime must load OpenSSL 3.5.9: $RuntimeSslVersion"
}
Assert-Directory (Join-Path $Runtime 'DLLs')
Assert-Directory (Join-Path $Runtime 'Lib')
Assert-Directory (Join-Path $Runtime 'Scripts')

Assert-Directory (Join-Path $Runtime 'libs')

$runtimeLibFiles = Get-ChildItem -LiteralPath (Join-Path $Runtime 'libs') -File
if ($runtimeLibFiles.Count -ne 19) {
    throw "Invalid runtime libs directory: expected 19 files, found $($runtimeLibFiles.Count)"
}

# Required Git-controlled product sources.
Assert-Directory (Join-Path $SourceRoot 'waptservice')
Assert-Directory (Join-Path $SourceRoot 'templates')
Assert-Directory (Join-Path $SourceRoot 'languages')
Assert-Directory (Join-Path $SourceRoot 'waptupgrade')
Assert-Directory (Join-Path $SourceRoot 'waptsetup')

Assert-File (Join-Path $SourceRoot 'COPYING.txt')
Assert-File (Join-Path $SourceRoot 'cache\icons\unknown.png')
Assert-File (Join-Path $SourceRoot 'waptsetup\waptsetup.iss')
Assert-File (Join-Path $SourceRoot 'waptsetup\common.iss')
Assert-File (Join-Path $SourceRoot 'waptsetup\wapt.iss')
Assert-File (Join-Path $SourceRoot 'waptsetup\services.iss')

# Git-controlled root resources required by the installer.
Assert-File (Join-Path $SourceRoot 'tranquilit.bmp')
Assert-File (Join-Path $SourceRoot 'wapt.ico')
Assert-File (Join-Path $SourceRoot 'waptdevutils.py')
Assert-File (Join-Path $SourceRoot 'create_version_full.py')

# Additional Git-controlled Inno Setup sources.
Assert-File (Join-Path $SourceRoot 'waptsetup\waptagent.iss')
Assert-File (Join-Path $SourceRoot 'waptsetup\waptserversetup.iss')
Assert-File (Join-Path $SourceRoot 'waptsetup\waptstarter.iss')

# Git-controlled installer languages.

Write-Host ""
Write-Host "[PASS] All controlled product-assembly inputs are present and validated."

# ----------------------------------------------------------------------
# Resolve exact Git source revision
# ----------------------------------------------------------------------

Write-Host "Resolving Git source revision..."

$SourceCommit = (& git -C $SourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "Unable to resolve Git HEAD from $SourceRoot"
}

$BuildNumber = (& git -C $SourceRoot rev-list --count HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $BuildNumber -notmatch '^\d+$') {
    throw "Unable to determine natural Git build number"
}

Write-Host "Source commit : $SourceCommit"
Write-Host "Build number  : $BuildNumber"

$CommunitySubmodules = @(
    'submodules\pltis_bgrabitmap',
    'submodules\pltis_bgracontrols',
    'submodules\pltis_bgracontrolsfx',
    'submodules\pltis_dcpcrypt',
    'submodules\pltis_indy',
    'submodules\pltis_lazarus-exception-logger',
    'submodules\pltis_lclextensions',
    'submodules\pltis_luipack',
    'submodules\pltis_python4delphi',
    'submodules\pltis_sogrid',
    'submodules\pltis_superobject',
    'submodules\pltis_synapse',
    'submodules\pltis_utils',
    'submodules\pltis_virtualtrees',
    'submodules\pltis_virtualtreesextra',
    'submodules\pltis_visualcontrols'
)

Write-Host ""
Write-Host "Verifying Community submodule gitlinks..."

foreach ($submodule in $CommunitySubmodules) {
    $gitPath = $submodule -replace '\\', '/'

    $expectedCommit = (& git -C $Worktree rev-parse "HEAD:$gitPath").Trim()
    if ($LASTEXITCODE -ne 0 -or $expectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Unable to resolve expected gitlink: $submodule"
    }

    $actualCommit = (& git -C (Join-Path $Worktree $submodule) rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Unable to resolve submodule HEAD: $submodule"
    }

    if ($actualCommit -ne $expectedCommit) {
        throw "Submodule gitlink mismatch: $submodule`nExpected: $expectedCommit`nActual:   $actualCommit"
    }
}

Write-Host "[PASS] Community submodule gitlinks verified: 16/16"

# A matching gitlink is not sufficient: the index and working tree
# must also contain the expected checked-out files.
foreach ($submodule in $CommunitySubmodules) {
    $submodulePath = Join-Path $Worktree $submodule
    $changes = @(git -C $submodulePath status --porcelain --untracked-files=no)

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect submodule status: $submodule"
    }

    if ($changes.Count -ne 0) {
        throw "Community submodule is not clean: $submodule"
    }
}

Write-Host "[PASS] Community submodule working trees clean: 16/16"

# ----------------------------------------------------------------------
# Prepare isolated Lazarus primary config path
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Preparing isolated Lazarus PCP..."

if (Test-Path -LiteralPath $LazarusPcp) {
    if (-not (Test-Path -LiteralPath $LazarusPcp -PathType Container)) {
        throw "Invalid Lazarus PCP path: $LazarusPcp"
    }

    if ($Force) {
        Remove-Item -LiteralPath $LazarusPcp -Recurse -Force
        New-Item -ItemType Directory -Path $LazarusPcp | Out-Null
        Write-Host "[PASS] Lazarus PCP recreated."
    }
    else {
        Write-Host "[PASS] Existing Lazarus PCP reused."
    }
}
else {
    New-Item -ItemType Directory -Path $LazarusPcp | Out-Null
    Write-Host "[PASS] Lazarus PCP created."
}

if (-not (Test-Path -LiteralPath $LazarusPcp -PathType Container)) {
    throw "Unable to create Lazarus PCP: $LazarusPcp"
}

Write-Host "[PASS] Isolated Lazarus PCP created."

$LazarusPackages = @(
    'submodules\pltis_dcpcrypt\dcpcrypt_laz.lpk',
    'submodules\pltis_indy\Lib\indylaz.lpk',
    'submodules\pltis_utils\pltis_utils.lpk',
    'submodules\pltis_superobject\pltis_superobject.lpk',
    'submodules\pltis_synapse\laz_synapse.lpk',
    'submodules\pltis_python4delphi\Packages\FPC\p4dlaz.lpk',
    'submodules\pltis_lazarus-exception-logger\ExceptionLogger.lpk',
    'submodules\pltis_lclextensions\lclextensions_package.lpk',
    'submodules\pltis_virtualtrees\pltis_virtualtrees.lpk',
    'submodules\pltis_virtualtreesextra\pltis_virtualtreesextra.lpk',
    'submodules\pltis_sogrid\pltis_sogrid.lpk',
    'submodules\pltis_bgrabitmap\bgrabitmap\bgrabitmappack.lpk',
    'submodules\pltis_bgracontrols\bgracontrols.lpk',
    'submodules\pltis_bgracontrolsfx\bgracontrolsfx.lpk',
    'submodules\pltis_luipack\luicomponents\luicomponents.lpk',
    'submodules\pltis_luipack\luicontrols\luicontrols.lpk',
    'wapt-get\pltis_wapt.lpk'
)

if ($LazarusPackages.Count -ne 17) {
    throw "Unexpected Lazarus package count: expected 17, found $($LazarusPackages.Count)"
}

foreach ($package in $LazarusPackages) {
    Assert-File (Join-Path $Worktree $package)
}

Write-Host "[PASS] Lazarus package files validated: 17/17"

# ----------------------------------------------------------------------
# Register Lazarus packages in isolated PCP
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Registering Lazarus packages..."

$LazbuildExe = Join-Path $Lazarus 'lazbuild.exe'

# Select FPC shipped with the requested Lazarus installation.
$FpcInstallations = @(Get-ChildItem (Join-Path $Lazarus 'fpc') -Directory)

if ($FpcInstallations.Count -ne 1) {
    throw "Expected exactly one FPC installation under $Lazarus"
}

$FpcCompiler = Join-Path $FpcInstallations[0].FullName 'bin\i386-win32\fpc.exe'

Assert-File $FpcCompiler

$FpcVersion = (& $FpcCompiler -iV).Trim()

if ($FpcVersion -ne '3.2.2') {
    throw "Unsupported FPC version: $FpcVersion. Required: 3.2.2 x86."
}

$LazarusVersionOutput = & $LazbuildExe --version 2>&1
$LazarusVersionText = ($LazarusVersionOutput | Out-String).Trim()

if ($LASTEXITCODE -ne 0 -or $LazarusVersionText -notmatch '\b4\.8(?:\.\d+)?\b') {
    throw "Unsupported Lazarus version: $LazarusVersionText. Required: Lazarus 4.8."
}

Write-Host "[PASS] Lazarus 4.8 / FPC 3.2.2 x86 validated."

if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine FPC version"
}

Write-Host "Selected FPC: $FpcVersion"
Write-Host "Compiler    : $FpcCompiler"

foreach ($package in $LazarusPackages) {
    $packagePath = Join-Path $Worktree $package

    & $LazbuildExe `
        "--primary-config-path=$LazarusPcp" `
        "--lazarusdir=$Lazarus" `
        "--compiler=$FpcCompiler" `
        '--add-package-link' `
        "$packagePath"

    if ($LASTEXITCODE -ne 0) {
        throw "Lazarus package registration failed: $package"
    }
}

Write-Host "[PASS] Lazarus packages registered: 17/17"

# Pin the selected compiler explicitly: older Lazarus versions may
# fail to resolve Lazarusdir macros and fall back to FPC from PATH.
$PcpEnvironment = Join-Path $LazarusPcp 'environmentoptions.xml'
Assert-File $PcpEnvironment

[xml]$PcpXml = Get-Content -LiteralPath $PcpEnvironment
$CompilerNode = $PcpXml.SelectSingleNode('//CompilerFilename')

if ($null -eq $CompilerNode) {
    throw "FPC compiler configuration missing from PCP: $PcpEnvironment"
}

$CompilerNode.SetAttribute('Value', $FpcCompiler)
$PcpXml.Save($PcpEnvironment)

[xml]$PcpVerify = Get-Content -LiteralPath $PcpEnvironment
$ActualCompiler = $PcpVerify.SelectSingleNode('//CompilerFilename').GetAttribute('Value')

if ($ActualCompiler -ine $FpcCompiler) {
    throw "PCP compiler mismatch: $ActualCompiler"
}

Write-Host "[PASS] PCP compiler pinned: $ActualCompiler"

# ----------------------------------------------------------------------
# Lazarus Community build targets
# ----------------------------------------------------------------------

$LazarusProjects = @(
    'wapt-get\waptget.lpi',
    'wapt-get\WaptGuiHelper.lpi',
    'waptdeploy\waptdeploy.lpi',
    'wapttray\wapttray.lpi',
    'waptconsole\waptconsole.lpi',
    'waptexit\waptexit.lpi',
    'waptself\waptself.lpi',
    'waptmessage\waptmessage.lpi',
    'waptsetup\waptsetuputil\waptsetuputil.lpi'
)

if ($LazarusProjects.Count -ne 9) {
    throw "Unexpected Lazarus project count: expected 9, found $($LazarusProjects.Count)"
}

foreach ($project in $LazarusProjects) {
    Assert-File (Join-Path $Worktree $project)
}

Write-Host "[PASS] Lazarus project files validated: 9/9"

# ----------------------------------------------------------------------
# Build Lazarus Community targets
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Building Lazarus Community targets..."

$LazbuildPy = Join-Path $Worktree 'lazbuild.py'

Assert-File $BuildPython
Assert-File $LazbuildPy

$LazarusSignArgs = @()

if ($SignKey) {

    if (-not $SignKeyPasswordFile) {
        throw "Signing password file is required when signing is enabled."
    }

    Assert-File $SignTool
    Assert-File $SignKey
    Assert-File $SignKeyPasswordFile

    $LazarusSignArgs = @(
        '-k', $SignKey,
        '-w', $SignKeyPasswordFile,
        '--sign-tool', $SignTool
    )

    Write-Host "[PASS] Authenticode signing inputs validated."
}

$LazarusLogRoot = Join-Path $LazarusPcp 'padit-lazarus-logs'
New-Item -ItemType Directory -Path $LazarusLogRoot -Force | Out-Null

$LazarusSummary = @()

foreach ($project in $LazarusProjects) {
    $projectPath = Join-Path $Worktree $project
    $projectName = $project -replace '[\\/:*?"<>|]', '_'
    $logPath = Join-Path $LazarusLogRoot "$projectName.log"

    Write-Host ""
    Write-Host "[BUILD] $project"
    Write-Host "[LOG]   $logPath"

    $ProjectTimer = [Diagnostics.Stopwatch]::StartNew()
    $BuildExitCode = $null

    $Writer = New-Object IO.StreamWriter(
        $logPath,
        $false,
        (New-Object Text.UTF8Encoding($false))
    )
    $Writer.AutoFlush = $true

    $PreviousPreference = $ErrorActionPreference
    $ProjectDirectory = Split-Path -Parent $projectPath

    Push-Location -LiteralPath $ProjectDirectory
    try {
        # PowerShell 5.1 can represent native stderr as ErrorRecord.
        # Keep these messages in the log without interrupting the build.
        $ErrorActionPreference = 'Continue'

        & $BuildPython '-u' $LazbuildPy `
            '-l' $LazbuildExe `
            '-p' $LazarusPcp `
            '-e' 'community' `
            @LazarusSignArgs `
            $projectPath 2>&1 |
            ForEach-Object {
                $Line = [string]$_

                # Complete log, including filtered messages.
                $Writer.WriteLine($Line)

                # Selected diagnostics and progress in real time.
                if ($Line -match '(?i)Warning:|Error:|Fatal:|Compiling .*\.lpr|Linking |lines compiled') {
                    Write-Host "[LIVE] $Line"
                }
            }

        $BuildExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousPreference
        $Writer.Dispose()
        $ProjectTimer.Stop()
        Pop-Location
    }

    $DiagnosticCounts = @{}

    foreach ($Severity in @('Fatal', 'Error', 'Warning', 'Hint', 'Note')) {
        $DiagnosticCounts[$Severity] = @(
            Select-String -LiteralPath $logPath `
                -Pattern "(?i)\b$Severity\s*:"
        ).Count
    }

    $LazarusSummary += [PSCustomObject]@{
        Project  = $project
        ExitCode = $BuildExitCode
        Fatal    = $DiagnosticCounts['Fatal']
        Error    = $DiagnosticCounts['Error']
        Warning  = $DiagnosticCounts['Warning']
        Hint     = $DiagnosticCounts['Hint']
        Note     = $DiagnosticCounts['Note']
        Seconds  = [math]::Round($ProjectTimer.Elapsed.TotalSeconds, 2)
    }

    $LazarusSummary |
        Export-Csv -LiteralPath (Join-Path $LazarusLogRoot 'summary.csv') `
            -NoTypeInformation -Encoding UTF8

    Write-Host (
        "[DIAG] Fatal={0} Error={1} Warning={2} Hint={3} Note={4}" -f `
        $DiagnosticCounts['Fatal'],
        $DiagnosticCounts['Error'],
        $DiagnosticCounts['Warning'],
        $DiagnosticCounts['Hint'],
        $DiagnosticCounts['Note']
    )

    Write-Host (
        "[TIMING] {0} : {1:N2} seconds" -f `
        $project, $ProjectTimer.Elapsed.TotalSeconds
    )

    if ($null -eq $BuildExitCode -or $BuildExitCode -ne 0) {
        Write-Host "=== LAST LAZARUS OUTPUT ==="
        Get-Content -LiteralPath $logPath -Tail 30
        throw "Lazarus build failed: $project (exit $BuildExitCode)"
    }
}

Write-Host "[PASS] Lazarus diagnostic summary: $LazarusLogRoot"

Write-Host "[PASS] Lazarus Community builds completed: 9/9"

# ----------------------------------------------------------------------
# Validate Lazarus build artifacts
# ----------------------------------------------------------------------

$LazarusArtifacts = @(
    'wapt-get.exe',
    'waptguihelper.pyd',
    'waptdeploy.exe',
    'wapttray.exe',
    'waptconsole.exe',
    'waptexit.exe',
    'waptself.exe',
    'waptmessage.exe',
    'waptsetuputil.dll'
)

if ($LazarusArtifacts.Count -ne 9) {
    throw "Unexpected Lazarus artifact count: expected 9, found $($LazarusArtifacts.Count)"
}

foreach ($artifact in $LazarusArtifacts) {
    Assert-File (Join-Path $Worktree $artifact)
}

Write-Host "[PASS] Lazarus build artifacts validated: 9/9"

Write-Host ""
Write-Host "Verifying Lazarus artifact metadata..."

$ExpectedFileVersion = "1.8.3.$BuildNumber"
$ExpectedProductVersion = '1.8.3'
$ExpectedProductName = 'PADIT Community Edition'

foreach ($artifact in $LazarusArtifacts) {
    $artifactPath = Join-Path $Worktree $artifact
    $versionInfo = (Get-Item -LiteralPath $artifactPath).VersionInfo

    if ($versionInfo.FileVersion -ne $ExpectedFileVersion) {
        throw "FileVersion mismatch: $artifact`nExpected: $ExpectedFileVersion`nActual:   $($versionInfo.FileVersion)"
    }

    if ($versionInfo.ProductVersion -ne $ExpectedProductVersion) {
        throw "ProductVersion mismatch: $artifact`nExpected: $ExpectedProductVersion`nActual:   $($versionInfo.ProductVersion)"
    }

    if ($versionInfo.ProductName -ne $ExpectedProductName) {
        throw "ProductName mismatch: $artifact`nExpected: $ExpectedProductName`nActual:   $($versionInfo.ProductName)"
    }
}

Write-Host "[PASS] Lazarus artifact metadata validated: 9/9"
Write-Host "       FileVersion    : $ExpectedFileVersion"
Write-Host "       ProductVersion : $ExpectedProductVersion"
Write-Host "       ProductName    : $ExpectedProductName"

# ----------------------------------------------------------------------
# Use exact worktree revision for all Git-controlled product content
# ----------------------------------------------------------------------

$ProductSource = $Worktree

if ((& git -C $ProductSource rev-parse HEAD).Trim() -ne $SourceCommit) {
    throw "Product source is not at expected commit: $SourceCommit"
}

Write-Host "[PASS] Product Git source locked to isolated worktree: $SourceCommit"

# ----------------------------------------------------------------------
# Assemble product tree
# ----------------------------------------------------------------------

if (Test-Path -LiteralPath $Output) {
    if (-not (Test-Path -LiteralPath $Output -PathType Container)) {
        throw "Invalid product output path: $Output"
    }

    if ($Force) {
        Write-Host "Removing existing product tree..."
        Remove-Item -LiteralPath $Output -Recurse -Force
        New-Item -ItemType Directory -Path $Output | Out-Null
    }
    else {
        Write-Host "[PASS] Existing product directory reused: $Output"
    }
}
else {
    Write-Host "Creating product tree: $Output"
    New-Item -ItemType Directory -Path $Output | Out-Null
}

# Start from the validated autonomous Python runtime.
Write-Host "Copying autonomous Python runtime..."
Copy-Item -Path (Join-Path $Runtime '*') `
          -Destination $Output `
          -Recurse -Force

# Synchronize keyfinder with the current product sources.
# The autonomous runtime may contain an older keyfinder.py/pyc.
Write-Host "Installing Git-controlled keyfinder..."

$KeyfinderSource = Join-Path $Worktree 'keyfinder.py'
$KeyfinderTarget = Join-Path $Output 'keyfinder.py'
$KeyfinderPyc = Join-Path $Output 'keyfinder.pyc'

Assert-File $KeyfinderSource

Copy-Item -LiteralPath $KeyfinderSource `
    -Destination $KeyfinderTarget -Force

# Never ship the cached bytecode of an older keyfinder.
if (Test-Path -LiteralPath $KeyfinderPyc) {
    Remove-Item -LiteralPath $KeyfinderPyc -Force
}

& $BuildPython -c `
    'import py_compile,sys; py_compile.compile(sys.argv[1],cfile=sys.argv[2],doraise=True)' `
    $KeyfinderTarget $KeyfinderPyc

if ($LASTEXITCODE -ne 0) {
    throw "keyfinder.py bytecode compilation failed."
}

Assert-File $KeyfinderPyc

$SourceHash = (Get-FileHash -LiteralPath $KeyfinderSource -Algorithm SHA256).Hash
$TargetHash = (Get-FileHash -LiteralPath $KeyfinderTarget -Algorithm SHA256).Hash

if ($SourceHash -ne $TargetHash) {
    throw "keyfinder.py source mismatch after product assembly."
}

Write-Host "[PASS] Git-controlled keyfinder.py and Python 2.7 bytecode installed."
# Controlled external binaries.
Write-Host "Installing controlled external binaries..."

Copy-Item (Join-Path $Vc90 'msvcr90.dll') $Output
Copy-Item (Join-Path $Vc90 'msvcp90.dll') $Output
Copy-Item (Join-Path $Vc90 'msvcm90.dll') $Output
Copy-Item (Join-Path $Vc90 'Microsoft.VC90.CRT.manifest') $Output

Copy-Item (Join-Path $Tools 'dmidecode.exe') $Output

# Install the controlled public Authenticode Root CA certificate in the
# product tree. It is retained as public signing material for WAPT and
# does not establish trust in the Windows certificate store.
$ProductSigningPublic = Join-Path $Output 'signing\public'
$ProductSigningRootCer = Join-Path $ProductSigningPublic 'Thouet-Software-Signing-Root-CA.cer'

New-Item -ItemType Directory -Path $ProductSigningPublic -Force | Out-Null

Copy-Item `
    -LiteralPath $SigningRootCer `
    -Destination $ProductSigningRootCer `
    -Force

Assert-File $ProductSigningRootCer `
    '5BB7881D601856F1EE55C7A7B88E988751751779DEE1AB08D21DD319B1690E7A'

Write-Host "[PASS] Controlled Authenticode Root CA certificate installed in product."

# Install the controlled SignTool required by CreateWaptSetup()
# to Authenticode-sign dynamically generated waptagent.exe.
$UtilsTarget = Join-Path $Output 'utils'
$ProductSignTool = Join-Path $UtilsTarget 'signtool.exe'

New-Item -ItemType Directory -Path $UtilsTarget -Force | Out-Null

Copy-Item `
    -LiteralPath $SignTool `
    -Destination $ProductSignTool `
    -Force

Assert-File $ProductSignTool

$ProductSignToolHash = (
    Get-FileHash -LiteralPath $ProductSignTool -Algorithm SHA256
).Hash

if ($ProductSignToolHash -ne $SignToolHash) {
    throw "Product signtool.exe SHA256 mismatch."
}

$ProductSdkSignature = Get-AuthenticodeSignature -LiteralPath $ProductSignTool
if ($ProductSdkSignature.Status -ne 'Valid' -or
    $ProductSdkSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
    throw 'Invalid Microsoft Authenticode signature on copied SDK SignTool.'
}
Write-Host "[PASS] SDK SignTool copied and validated for dynamic agent signing."

# Product source trees required by Inno Setup.
Write-Host "Copying Git-controlled product trees..."

foreach ($dir in @(
    'templates',
    'languages',
    'waptupgrade',
    'waptservice'
)) {
    Copy-Item `
        -LiteralPath (Join-Path $ProductSource $dir) `
        -Destination $Output `
        -Recurse -Force
}

# Replace NSSM with the controlled build-kit copies.
Write-Host "Installing controlled NSSM binaries..."

$Nssm32Target = Join-Path $Output 'waptservice\win32'
$Nssm64Target = Join-Path $Output 'waptservice\win64'

New-Item -ItemType Directory -Path $Nssm32Target -Force | Out-Null
New-Item -ItemType Directory -Path $Nssm64Target -Force | Out-Null

Copy-Item (Join-Path $Nssm 'win32\nssm.exe') `
          (Join-Path $Nssm32Target 'nssm.exe') -Force

Copy-Item (Join-Path $Nssm 'win64\nssm.exe') `
          (Join-Path $Nssm64Target 'nssm.exe') -Force

# Individual Git-controlled files required by wapt.iss.
foreach ($file in @(
    'COPYING.txt',
    'tranquilit.bmp',
    'wapt.ico',
    'waptdevutils.py',
    'cache\icons\unknown.png',
    'wapt-get.exe.manifest',
    'waptconsole.exe.manifest',
    'wapt-scanpackages.bat',
    'wapt-scanpackages.py',
    'wapt-signpackages.bat',
    'wapt-signpackages.py',
    'runwaptservice.bat',
    'wapt.psproj',
    'devwapt.bat',
    'waptpyscripter.bat',
    'wapt-get.ini.tmpl'
)) {
    $src = Join-Path $ProductSource $file
    Assert-File $src

    $dst = Join-Path $Output $file
    $dstDir = Split-Path -Parent $dst

    if ($dstDir -and -not (Test-Path $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $src -Destination $dst -Force
}

# ----------------------------------------------------------------------
# Git-controlled Inno Setup scripts
# ----------------------------------------------------------------------

Write-Host "Copying Git-controlled Inno Setup scripts..."

$WaptSetupTarget = Join-Path $Output 'waptsetup'
New-Item -ItemType Directory -Path $WaptSetupTarget -Force | Out-Null

$InnoScripts = @(
    'common.iss',
    'services.iss',
    'wapt.iss',
    'waptagent.iss',
    'waptserversetup.iss',
    'waptsetup.iss',
    'waptstarter.iss'
)

foreach ($file in $InnoScripts) {
    $src = Join-Path $ProductSource "waptsetup\$file"
    Assert-File $src
    Copy-Item -LiteralPath $src -Destination (Join-Path $WaptSetupTarget $file) -Force
}

$innoScriptFiles = Get-ChildItem -LiteralPath $WaptSetupTarget -File -Filter '*.iss'
if ($innoScriptFiles.Count -ne 7) {
    throw "Unexpected Inno script count: expected 7, found $($innoScriptFiles.Count)"
}

Write-Host "Git-controlled Inno scripts: 7/7 PASS"

# ----------------------------------------------------------------------
# Reconstruct controlled Inno Setup tree
# ----------------------------------------------------------------------

Write-Host "Reconstructing controlled Inno Setup 7.1.1 x64 tree..."

$InnoTarget = Join-Path $Output 'waptsetup\innosetup'

New-Item -ItemType Directory -Path $InnoTarget -Force | Out-Null

& {
    $RequiredRoot = @(
        'Default.isl',
        'ISCC.exe',
        'ISCmplr.dll',
        'ISCmplr.dll.issig',
        'ISPP.dll',
        'ISPP.dll.issig',
        'ISPPBuiltins.iss',
        'Setup.e32',
        'Setup.e32.issig',
        'SetupLdr.e32',
        'SetupLdr.e32.issig',
        'license.txt'
    )

    foreach ($name in $RequiredRoot) {
        Assert-File (Join-Path $InnoRoot $name)
    }

    foreach ($name in @('French.isl', 'German.isl')) {
        Assert-File (Join-Path $InnoRoot "Languages\$name")
    }

    $SourceFiles = @(
        Get-ChildItem -LiteralPath $InnoRoot -Recurse -File
    )

    $SourceSignatures = @(
        $SourceFiles | Where-Object { $_.Extension -eq '.issig' }
    )

    if ($SourceSignatures.Count -lt 20) {
        throw "Incomplete Inno 7 distribution: $($SourceSignatures.Count) .issig files"
    }

    # Exclude IDE, documentation and Inno Setup's own uninstall files.
    # Keep all compiler engines, libraries, languages and .issig files.
    $InnoExclude = @(
        'ISIDE.exe',
        'ISetup.chm',
        'ISetup-dark.chm',
        'whatsnew.htm',
        'isfaq.url',
        'unins000.exe',
        'unins000.dat',
        'unins000.msg'
    )

    $InnoEntries = @(
        Get-ChildItem -LiteralPath $InnoRoot -Force
    )

    $InnoExcluded = @(
        $InnoEntries | Where-Object { $_.Name -in $InnoExclude }
    )

    if ($InnoExcluded.Count -ne $InnoExclude.Count) {
        throw "Unexpected Inno exclusion count: $($InnoExcluded.Count)"
    }

    $InnoEntries |
        Where-Object { $_.Name -notin $InnoExclude } |
        Copy-Item -Destination $InnoTarget -Recurse -Force

    $TargetFiles = @(
        Get-ChildItem -LiteralPath $InnoTarget -Recurse -File
    )

    if ($TargetFiles.Count -ne ($SourceFiles.Count - $InnoExclude.Count)) {
        throw "Inno 7 file count mismatch: $($SourceFiles.Count) / $($TargetFiles.Count)"
    }

    foreach ($name in $RequiredRoot) {
        Assert-File (Join-Path $InnoTarget $name)
    }

    foreach ($name in @('French.isl', 'German.isl')) {
        Assert-File (Join-Path $InnoTarget "Languages\$name")
    }

    foreach ($SourceFile in $SourceFiles) {
        $Relative = $SourceFile.FullName.Substring($InnoRoot.TrimEnd('\').Length + 1)
        if ($Relative -in $InnoExclude) { continue }
        $TargetFile = Join-Path $InnoTarget $Relative
        Assert-File $TargetFile
        if ((Get-FileHash -LiteralPath $SourceFile.FullName -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $TargetFile -Algorithm SHA256).Hash) {
            throw "Inno copy mismatch: $Relative"
        }
    }
    $TargetSignatures = @(Get-ChildItem -LiteralPath $InnoTarget -Recurse -File -Filter '*.issig')
    if ($TargetSignatures.Count -ne $SourceSignatures.Count) { throw 'Inno .issig inventory mismatch' }
    Write-Host "[PASS] Inno Setup 7.1.1 distribution copied: $($TargetFiles.Count) files"
    Write-Host "[PASS] Inno component signatures: $($SourceSignatures.Count)"
    Write-Host "[PASS] Inno languages: French / German"
}
# ----------------------------------------------------------------------
# Install freshly built Lazarus artifacts
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Installing freshly built Lazarus artifacts..."

foreach ($artifact in $LazarusArtifacts) {
    $src = Join-Path $Worktree $artifact
    Assert-File $src

    $dst = Join-Path $Output $artifact
    $dstDir = Split-Path -Parent $dst

    if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $src -Destination $dst -Force

    $sourceHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash

    if ($sourceHash -ne $destinationHash) {
        throw "Lazarus artifact hash mismatch after copy: $artifact"
    }
}

Write-Host "[PASS] Fresh Lazarus artifacts installed: 9/9"
# W32-H58-Q: Verify embedded Lazarus Authenticode signatures.
# A signed installer must never embed unsigned Lazarus executables.
$RequiredSignedExecutables = @(
    $LazarusArtifacts | Where-Object { $_ -like '*.exe' }
)

if ($RequiredSignedExecutables.Count -ne 7 -or
    $RequiredSignedExecutables -notcontains 'waptconsole.exe') {
    throw 'Unexpected mandatory Lazarus executable inventory'
}

Write-Host ""
Write-Host "Validating embedded Lazarus Authenticode signatures..."

foreach ($exeName in $RequiredSignedExecutables) {
    $exePath = Join-Path $Output $exeName
    Assert-File $exePath

    $signature = Get-AuthenticodeSignature -LiteralPath $exePath

    if ($signature.Status -eq 'Valid') {
        Write-Host "[PASS] Authenticode: $exeName"
    }
    elseif ($SignKey) {
        throw "Signed product build refused: $exeName has Authenticode status $($signature.Status)"
    }
    else {
        Write-Warning "Unsigned product build: $exeName has Authenticode status $($signature.Status)"
    }
}

Write-Host '[PASS] Lazarus Authenticode build guard completed.'


# ----------------------------------------------------------------------
# Generate canonical version-full
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Generating canonical version-full..."

$CreateVersionFull = Join-Path $Worktree 'create_version_full.py'
Assert-File $CreateVersionFull

Push-Location $Worktree
try {
    & $BuildPython $CreateVersionFull

    if ($LASTEXITCODE -ne 0) {
        throw "create_version_full.py failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$GeneratedVersionFull = Join-Path $Worktree 'version-full'
Assert-File $GeneratedVersionFull

$VersionFull = (Get-Content -LiteralPath $GeneratedVersionFull -Raw).Trim()

if ($VersionFull -ne $ExpectedFileVersion) {
    throw "version-full mismatch.`nExpected: $ExpectedFileVersion`nActual:   $VersionFull"
}

Copy-Item `
    -LiteralPath $GeneratedVersionFull `
    -Destination (Join-Path $Output 'version-full') `
    -Force

Write-Host "[PASS] version-full generated: $VersionFull"

# ----------------------------------------------------------------------
# Generate canonical revision.txt
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Generating canonical revision.txt..."

$ExpectedRevision = $SourceCommit.Substring(0, 8)
$RevisionTarget = Join-Path $Output 'revision.txt'

[IO.File]::WriteAllText(
    $RevisionTarget,
    $ExpectedRevision,
    [Text.Encoding]::ASCII
)

Assert-File $RevisionTarget

$ActualRevision = (Get-Content -LiteralPath $RevisionTarget -Raw).Trim()

if ($ActualRevision -ne $ExpectedRevision) {
    throw "revision.txt mismatch.`nExpected: $ExpectedRevision`nActual:   $ActualRevision"
}

Write-Host "[PASS] revision.txt generated: $ActualRevision"

# ----------------------------------------------------------------------
# Build unsigned Community setup
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Building unsigned PADIT Community setup..."

$IsccExe = Join-Path $Output 'waptsetup\innosetup\ISCC.exe'
$SetupIss = Join-Path $Output 'waptsetup\waptsetup.iss'
$SetupExe = Join-Path $Output 'waptsetup\waptsetup.exe'

Assert-File $IsccExe
Assert-File $SetupIss

Push-Location $Output
try {
    & $IsccExe '--define=waptcommunity' '.\waptsetup\waptsetup.iss'

    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Assert-File $SetupExe

Write-Host "[PASS] Unsigned PADIT Community setup built."

# ----------------------------------------------------------------------
# Sign final Community setup
# ----------------------------------------------------------------------

if ($SignKey) {
    Write-Host ""
    Write-Host "Signing final PADIT Community setup..."

    $SignPassword = [IO.File]::ReadAllText($SignKeyPasswordFile).TrimEnd("`r", "`n")

    try {
        & $SignTool `
            'sign' `
            '/f' $SignKey `
            '/p' $SignPassword `
            '/fd' 'SHA256' `
            '/tr' 'http://timestamp.sectigo.com/rfc3161' `
            '/td' 'SHA256' `
            $SetupExe

        if ($LASTEXITCODE -ne 0) {
            throw "Setup Authenticode signing failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        $SignPassword = $null
    }

    $SetupSignature = Get-AuthenticodeSignature -LiteralPath $SetupExe

    if ($SetupSignature.Status -ne 'Valid') {
        throw "Invalid Authenticode signature on final setup: $($SetupSignature.Status)"
    }

    Write-Host "[PASS] Final PADIT Community setup signed and validated."
}

# ----------------------------------------------------------------------
# Validate final Community setup
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Validating final PADIT Community setup..."

$SetupItem = Get-Item -LiteralPath $SetupExe
$SetupVersionInfo = $SetupItem.VersionInfo

if ($SetupItem.Length -le 0) {
    throw "Generated setup is empty: $SetupExe"
}

if ($setupVersionInfo.FileVersion.Trim() -ne $ExpectedFileVersion) {
    throw "Setup VersionInfo mismatch.`nExpected: $ExpectedFileVersion`nActual:   $($SetupVersionInfo.FileVersion)"
}
if ($SetupVersionInfo.ProductVersion.Trim() -ne $ExpectedFileVersion) {
    throw "Setup ProductVersion mismatch.`nExpected: $ExpectedFileVersion`nActual:   $($SetupVersionInfo.ProductVersion)"
}

if ($SetupVersionInfo.ProductName.Trim() -ne 'PADITSetup') {
    throw "Setup ProductName mismatch.`nExpected: PADITSetup`nActual:   $($SetupVersionInfo.ProductName)"
}

$SetupHash = (Get-FileHash -LiteralPath $SetupExe -Algorithm SHA256).Hash

Write-Host "[PASS] Final PADIT Community setup validated."
Write-Host "       FileVersion    : $($SetupVersionInfo.FileVersion)"
Write-Host "       ProductVersion : $($SetupVersionInfo.ProductVersion)"
Write-Host "       ProductName    : $($SetupVersionInfo.ProductName)"
Write-Host "       Size           : $($SetupItem.Length) bytes"
Write-Host "       SHA256         : $SetupHash"

Write-Host ""
Write-Host "[PASS] Base Windows product tree assembled."
