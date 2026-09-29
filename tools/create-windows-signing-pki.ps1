[CmdletBinding()]
param(
    [ValidateSet('Create', 'RenewCodeSigning')]
    [string]$Action = 'Create',

    [string]$PrivateDir = 'C:\private-wapt-signing',
    [string]$PublicDir  = 'C:\wapt-build-kit\signing\public',

    [string]$RootSubject = 'CN=Thouet Software Signing Root CA',
    [string]$CodeSubject = 'CN=Thouet Software Code Signing',

    [int]$RootYears = 10,
    [int]$CodeYears = 1
)

$ErrorActionPreference = 'Stop'

$RootDir = Join-Path $PrivateDir 'root'
$CodeDir = Join-Path $PrivateDir 'codesigning'

$RootCer = Join-Path $PublicDir  'Thouet-Software-Signing-Root-CA.cer'
$RootPfx = Join-Path $RootDir    'Thouet-Software-Signing-Root-CA.pfx'
$CodeCer = Join-Path $PublicDir  'Thouet-Software-Code-Signing.cer'
$CodePfx = Join-Path $CodeDir    'Thouet-Software-Code-Signing.pfx'

if ($Action -eq 'RenewCodeSigning') {
    Write-Host '=== WAPT Code Signing certificate renewal ==='
    Write-Host
    Write-Host 'This operation renews the Code Signing certificate.'
    Write-Host 'The existing Root CA is reused and is NOT renewed.'
    Write-Host

    if (-not (Test-Path $RootPfx)) {
        throw "Root CA PFX not found: $RootPfx"
    }

    if (-not (Test-Path $RootCer)) {
        throw "Root CA public certificate not found: $RootCer"
    }

    if (-not (Test-Path $CodePfx)) {
        throw "Current Code Signing PFX not found: $CodePfx"
    }

    if (-not (Test-Path $CodeCer)) {
        throw "Current Code Signing certificate not found: $CodeCer"
    }

    Write-Host 'Enter the password for the OFFLINE Root CA PFX.'
    $RootPassword = Read-Host -AsSecureString

    Write-Host
    Write-Host 'Enter a strong password for the NEW Code Signing PFX.'
    $CodePassword = Read-Host -AsSecureString

    $Root = $null
    $Code = $null
    $NewCodeCer = "$CodeCer.new"
    $NewCodePfx = "$CodePfx.new"

    try {
        Write-Host
        Write-Host 'Importing Root CA temporarily...'

        $Root = Import-PfxCertificate `
            -FilePath $RootPfx `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -Password $RootPassword

        $ExpectedRoot = New-Object `
            System.Security.Cryptography.X509Certificates.X509Certificate2($RootCer)

        if ($Root.Thumbprint -ne $ExpectedRoot.Thumbprint) {
            throw 'Root PFX does not match the public Root CA certificate.'
        }

        $CurrentCode = New-Object `
            System.Security.Cryptography.X509Certificates.X509Certificate2($CodeCer)

        if ($CurrentCode.Issuer -ne $Root.Subject) {
            throw 'Current Code Signing certificate was not issued by this Root CA.'
        }

        Write-Host 'Creating new Code Signing certificate...'

        $Code = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $CodeSubject `
            -FriendlyName 'Thouet Software Code Signing' `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -Signer $Root `
            -KeyAlgorithm RSA `
            -KeyLength 3072 `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears($CodeYears)

        Export-Certificate `
            -Cert $Code `
            -FilePath $NewCodeCer `
            -Type CERT | Out-Null

        Export-PfxCertificate `
            -Cert $Code `
            -FilePath $NewCodePfx `
            -Password $CodePassword `
            -ChainOption EndEntityCertOnly | Out-Null

        $ExportedCode = New-Object `
            System.Security.Cryptography.X509Certificates.X509Certificate2($NewCodeCer)

        if ($ExportedCode.Thumbprint -ne $Code.Thumbprint) {
            throw 'New Code Signing certificate validation failed.'
        }

        Write-Host 'New certificate validated. Rotating current certificate...'

        $ArchiveDir = Join-Path $CodeDir 'archive'
        New-Item -ItemType Directory -Force $ArchiveDir | Out-Null

        $PreviousCer = Join-Path $ArchiveDir 'previous.cer'
        $PreviousPfx = Join-Path $ArchiveDir 'previous.pfx'

        Copy-Item $CodeCer $PreviousCer -Force
        Copy-Item $CodePfx $PreviousPfx -Force

        try {
            Copy-Item $NewCodeCer $CodeCer -Force
            Copy-Item $NewCodePfx $CodePfx -Force
        }
        catch {
            Copy-Item $PreviousCer $CodeCer -Force
            Copy-Item $PreviousPfx $CodePfx -Force
            throw
        }

        Write-Host
        $Code |
            Select-Object Subject,Issuer,Thumbprint,NotBefore,NotAfter |
            Format-List

        Write-Host 'Rotation policy: current + one previous generation.'
        Write-Host "Previous generation: $ArchiveDir"
        Write-Host
        Write-Host '[PASS] Code Signing certificate renewed.'
    }
    finally {
        if ($Code) {
            Remove-Item "Cert:\CurrentUser\My\$($Code.Thumbprint)" `
                -ErrorAction SilentlyContinue
        }

        if ($Root) {
            Remove-Item "Cert:\CurrentUser\My\$($Root.Thumbprint)" `
                -ErrorAction SilentlyContinue
        }

        Remove-Item $NewCodeCer,$NewCodePfx `
            -Force -ErrorAction SilentlyContinue
    }

    return
}

if ($Action -ne 'Create') {
    throw "Unsupported action: $Action"
}

Write-Host '=== WAPT private signing PKI creation ==='
Write-Host
Write-Host 'This operation creates a NEW signing identity.'
Write-Host 'It must not be used for normal builds or certificate renewal.'
Write-Host

# Refuse to overwrite an existing PKI.
$ExistingFiles = @(
    $RootCer,
    $RootPfx,
    $CodeCer,
    $CodePfx
) | Where-Object { Test-Path $_ }

if ($ExistingFiles) {
    Write-Host 'Existing PKI material detected:' -ForegroundColor Yellow
    $ExistingFiles | ForEach-Object { Write-Host "  $_" }
    throw 'Refusing to overwrite existing signing PKI.'
}

New-Item -ItemType Directory -Force `
    $RootDir,
    $CodeDir,
    $PublicDir | Out-Null

# Passwords are deliberately requested interactively.
# They are never written by this script to disk.
Write-Host 'Enter a strong password for the OFFLINE Root CA PFX.'
$RootPassword = Read-Host -AsSecureString

Write-Host
Write-Host 'Enter a strong password for the Code Signing PFX.'
$CodePassword = Read-Host -AsSecureString

Write-Host
Write-Host 'Creating Root CA...'

$Root = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $RootSubject `
    -FriendlyName 'Thouet Software Signing Root CA' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA `
    -KeyLength 4096 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -KeyUsage CertSign,CRLSign `
    -TextExtension @(
        '2.5.29.19={critical}{text}ca=1&pathlength=0'
    ) `
    -NotAfter (Get-Date).AddYears($RootYears)

Write-Host 'Creating Code Signing certificate...'

$Code = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $CodeSubject `
    -FriendlyName 'Thouet Software Code Signing' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -Signer $Root `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears($CodeYears)

Write-Host 'Exporting public certificates...'

Export-Certificate `
    -Cert $Root `
    -FilePath $RootCer `
    -Type CERT | Out-Null

Export-Certificate `
    -Cert $Code `
    -FilePath $CodeCer `
    -Type CERT | Out-Null

Write-Host 'Exporting private PFX files...'

Export-PfxCertificate `
    -Cert $Root `
    -FilePath $RootPfx `
    -Password $RootPassword | Out-Null

Export-PfxCertificate `
    -Cert $Code `
    -FilePath $CodePfx `
    -Password $CodePassword `
    -ChainOption EndEntityCertOnly | Out-Null

Write-Host 'Removing generated private keys from the Windows certificate store...'

$RootInfo = $Root |
    Select-Object Subject,Issuer,Thumbprint,HasPrivateKey,NotBefore,NotAfter

$CodeInfo = $Code |
    Select-Object Subject,Issuer,Thumbprint,HasPrivateKey,NotBefore,NotAfter

Remove-Item "Cert:\CurrentUser\My\$($Code.Thumbprint)"
Remove-Item "Cert:\CurrentUser\My\$($Root.Thumbprint)"

Write-Host
Write-Host '=== Generated certificates ==='

$RootInfo | Format-List
$CodeInfo | Format-List

Write-Host '=== Generated files ==='

Get-Item $RootCer,$RootPfx,$CodeCer,$CodePfx |
    Select-Object FullName,Length,LastWriteTime |
    Format-Table -AutoSize

Write-Host
Write-Host 'IMPORTANT:'
Write-Host '  Root PFX must be archived offline after validation.'
Write-Host '  Root PFX must never be included in Git or the build kit.'
Write-Host '  Code Signing PFX is the only private key required for normal builds.'
Write-Host
Write-Host '[PASS] Initial signing PKI created.'
