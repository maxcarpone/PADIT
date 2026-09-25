[CmdletBinding()]
param(
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
    -Password $CodePassword | Out-Null

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
