#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a self-signed code-signing certificate and signs NetSetPS files.
.DESCRIPTION
    - Finds existing 'CN=NetSetPS Self-Signed' cert or creates a new one
    - Installs the cert to Cert:\CurrentUser\Root so Windows accepts signatures
    - Signs NetSetPS.ps1 and NetSetPS.Native.dll from the specified directory
    - Verifies the resulting Authenticode signatures

    First run prompts for Trusted Root install (Windows security dialog).
    Subsequent runs reuse the existing cert.

    Run this AFTER Build-Native.ps1 and (if signing installed files) as admin.
.PARAMETER TargetDir
    Directory containing NetSetPS.ps1 and NetSetPS.Native.dll.
    Default: $PSScriptRoot (the folder Sign.ps1 lives in).
.PARAMETER Subject
    Certificate subject. Default: 'CN=NetSetPS Self-Signed'
.EXAMPLE
    .\Sign.ps1
    .\Sign.ps1 -TargetDir 'C:\Program Files\NetSetPS'
.NOTES
    Author: Daniel Kaszper (digitlife.pl)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$TargetDir = $PSScriptRoot,
    [string]$Subject   = 'CN=NetSetPS Self-Signed'
)

$ErrorActionPreference = 'Stop'

# 1. Find or create certificate
$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) } |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "Creating new self-signed certificate..." -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -Type CodeSigningCert `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(5)
    Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "Using existing certificate. Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
}

# 2. Ensure it is in Trusted Root of CurrentUser
$inRoot = Get-ChildItem Cert:\CurrentUser\Root |
    Where-Object { $_.Thumbprint -eq $cert.Thumbprint }

if (-not $inRoot) {
    Write-Host "Installing certificate to Trusted Root (Windows security dialog will appear)..." -ForegroundColor Cyan
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
    $store.Open('ReadWrite')
    $store.Add($cert)
    $store.Close()
    Write-Host "  Installed." -ForegroundColor Green
} else {
    Write-Host "Certificate already in Trusted Root." -ForegroundColor Green
}

# 3. Sign target files
$targets = @('NetSetPS.ps1', 'NetSetPS.Native.dll', 'Install.ps1', 'Uninstall.ps1', 'Build-Native.ps1', 'Sign.ps1')
foreach ($file in $targets) {
    $path = Join-Path $TargetDir $file
    if (-not (Test-Path $path)) {
        Write-Host "  Skip: $file (not in $TargetDir)" -ForegroundColor DarkGray
        continue
    }
    try {
        $sig = Set-AuthenticodeSignature -FilePath $path -Certificate $cert -ErrorAction Stop
        $color = if ($sig.Status -eq 'Valid') { 'Green' } else { 'Yellow' }
        Write-Host ("  Signed: {0,-24} Status: {1}" -f $file, $sig.Status) -ForegroundColor $color
    } catch {
        Write-Warning "Failed to sign $file`: $_"
    }
}

Write-Host ''
Write-Host 'Signing complete.' -ForegroundColor Cyan
Write-Host 'Note: signatures are valid only for the exact byte content at signing time.'
Write-Host 'Editing any signed file invalidates its signature. Re-run Sign.ps1 after edits.'
