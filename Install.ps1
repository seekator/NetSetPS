#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    NetSetPS installer - UAC-per-launch, DLL-optimized, AV-friendly.
.DESCRIPTION
    Installs NetSetPS with a shortcut that triggers a UAC prompt on every
    launch. Uses execution policy AllSigned (requires signed script), a
    pre-compiled native DLL (no runtime csc.exe), and a minimized window
    style (not hidden) - all to reduce false positives from behavioral AV
    engines like Bitdefender Advanced Threat Defense.

    Legacy cleanup step removes any stale configuration from previous
    install variants.
.PARAMETER InstallPath
    Where to place the files. Default: C:\Program Files\NetSetPS
.PARAMETER RevokeFromUser
    Legacy: user to remove from Network Configuration Operators
    (from a previous install variant). Empty = skip.
.PARAMETER SkipSignCheck
    Do not warn if NetSetPS.ps1 is unsigned. Use for development.
.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -RevokeFromUser 'Danie'
.NOTES
    Author: Daniel Kaszper (digitlife.pl)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$InstallPath    = "$env:ProgramFiles\NetSetPS",
    [string]$RevokeFromUser = '',
    [switch]$SkipSignCheck
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# 1. Cleanup previous configuration
# ------------------------------------------------------------------
Write-Host "[1/4] Cleaning previous configuration" -ForegroundColor Cyan

foreach ($t in @('NetSetPS', 'NetSetPS-Autostart')) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Host "     Removed task: $t" -ForegroundColor Green
    }
}

foreach ($p in @(
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'NetSetPS.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'NetSetPS.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'NetSetPS.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'NetSetPS.lnk')
)) {
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host "     Removed shortcut: $p" -ForegroundColor Green
    }
}

$polKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$polName = 'LocalAccountTokenFilterPolicy'
try {
    $existing = Get-ItemProperty -Path $polKey -Name $polName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-ItemProperty -Path $polKey -Name $polName -Force
        Write-Host "     Removed HKLM registry: LocalAccountTokenFilterPolicy" -ForegroundColor Green
    }
} catch {
    Write-Warning "Failed to remove registry policy: $_"
}

if (-not $RevokeFromUser) {
    Write-Host ''
    Write-Host '     Was any user added to "Network Configuration Operators" previously?' -ForegroundColor Yellow
    Write-Host '     Enter username to revoke (or press ENTER to skip):' -ForegroundColor Yellow
    $RevokeFromUser = Read-Host '     User'
}
if ($RevokeFromUser) {
    try {
        $groupSid  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-556'
        $groupName = ($groupSid.Translate([System.Security.Principal.NTAccount])).Value.Split('\')[-1]
        Remove-LocalGroupMember -Group $groupName -Member $RevokeFromUser -ErrorAction Stop
        Write-Host "     Removed '$RevokeFromUser' from '$groupName'." -ForegroundColor Green
    } catch {
        Write-Host "     '$RevokeFromUser' was not a NetConfigOps member (nothing to remove)." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------
# 2. Sanity checks on source files
# ------------------------------------------------------------------
Write-Host "[2/4] Verifying source files" -ForegroundColor Cyan

$sourceScript = Join-Path $PSScriptRoot 'NetSetPS.ps1'
$sourceDll    = Join-Path $PSScriptRoot 'NetSetPS.Native.dll'

if (-not (Test-Path $sourceScript)) {
    throw "NetSetPS.ps1 not found in $PSScriptRoot"
}
if (-not (Test-Path $sourceDll)) {
    Write-Warning "NetSetPS.Native.dll not found. Run Build-Native.ps1 first."
    Write-Warning "Without the DLL, the script falls back to inline Add-Type (AV-noisy)."
    $ans = Read-Host '     Continue without DLL? (y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') {
        throw 'Install aborted. Run Build-Native.ps1 and try again.'
    }
    $hasDll = $false
} else {
    $hasDll = $true
    Write-Host "     Found: NetSetPS.Native.dll" -ForegroundColor Green
}

if (-not $SkipSignCheck) {
    # Wrap in try/catch: PowerShell 7.6.0 has a bug where
    # Microsoft.PowerShell.Security module fails to load due to an error in
    # Security.types.ps1xml. This makes Get-AuthenticodeSignature unavailable
    # even to test. We treat a load failure the same as "signature unknown"
    # and let the user decide whether to proceed.
    $sigStatus = $null
    try {
        $sig = Get-AuthenticodeSignature -FilePath $sourceScript -ErrorAction Stop
        $sigStatus = $sig.Status
    } catch {
        Write-Warning "Could not verify signature (Get-AuthenticodeSignature unavailable): $_"
        Write-Warning "This is often a PowerShell 7.6.x bug. Try running Install.ps1 from"
        Write-Warning "Windows PowerShell 5.1 (powershell.exe) instead of pwsh.exe."
    }

    if ($sigStatus -eq 'Valid') {
        Write-Host "     NetSetPS.ps1 signature: Valid" -ForegroundColor Green
    } elseif ($sigStatus -eq $null) {
        Write-Warning "Signature status unknown (see errors above). Continuing without check."
    } else {
        Write-Warning "NetSetPS.ps1 signature status: $sigStatus"
        Write-Warning "The shortcut uses ExecutionPolicy AllSigned - unsigned script will not run."
        Write-Warning "Run Sign.ps1 to sign the files, then re-run Install.ps1."
        $ans = Read-Host '     Continue anyway? (y/N)'
        if ($ans -ne 'y' -and $ans -ne 'Y') {
            throw 'Install aborted. Run Sign.ps1 and try again.'
        }
    }
}

# ------------------------------------------------------------------
# 3. Install to Program Files
# ------------------------------------------------------------------
Write-Host "[3/4] Installing to: $InstallPath" -ForegroundColor Cyan

if (-not (Test-Path $InstallPath)) {
    New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
}

Copy-Item -Path $sourceScript -Destination (Join-Path $InstallPath 'NetSetPS.ps1') -Force
Write-Host "     Copied: NetSetPS.ps1" -ForegroundColor Green

if ($hasDll) {
    Copy-Item -Path $sourceDll -Destination (Join-Path $InstallPath 'NetSetPS.Native.dll') -Force
    Write-Host "     Copied: NetSetPS.Native.dll" -ForegroundColor Green
}

$targetScript = Join-Path $InstallPath 'NetSetPS.ps1'

# ------------------------------------------------------------------
# 4. Create shortcuts with RunAs flag, AV-friendly arguments
# ------------------------------------------------------------------
Write-Host "[4/4] Creating shortcuts" -ForegroundColor Cyan

# AV-friendliness choices in the argument string:
#   -ExecutionPolicy AllSigned  -> stricter than Bypass; AV sees this as good hygiene
#   -WindowStyle Minimized      -> PS console briefly appears in taskbar, then hidden
#                                  by the script's WPF window; NOT flagged as fileless
#                                  fingerprint like -WindowStyle Hidden
#   -NoLogo                     -> cosmetic; no PowerShell banner
# -NoProfile is intentionally omitted because it's a minor AV fingerprint.
$desktopPath  = [Environment]::GetFolderPath('CommonDesktopDirectory')
$startMenuDir = [Environment]::GetFolderPath('CommonPrograms')
$shortcutPath = Join-Path $desktopPath 'NetSetPS.lnk'
$startMenu    = Join-Path $startMenuDir 'NetSetPS.lnk'

$wsh = New-Object -ComObject WScript.Shell
foreach ($lnkPath in @($shortcutPath, $startMenu)) {
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments        = "-ExecutionPolicy AllSigned -WindowStyle Minimized -NoLogo -File `"$targetScript`""
    $sc.WorkingDirectory = $InstallPath
    $sc.IconLocation     = "$env:SystemRoot\System32\ncpa.cpl,0"
    $sc.WindowStyle      = 7  # minimized launch of the shortcut itself
    $sc.Description      = 'NetSetPS'
    $sc.Save()

    # Byte 21, bit 0x20 = RunAsUser LinkFlag. Triggers UAC prompt on double-click.
    $bytes = [System.IO.File]::ReadAllBytes($lnkPath)
    $bytes[21] = $bytes[21] -bor 0x20
    [System.IO.File]::WriteAllBytes($lnkPath, $bytes)
}

Write-Host "     Public desktop:    $shortcutPath" -ForegroundColor Green
Write-Host "     Public start menu: $startMenu" -ForegroundColor Green
Write-Host "     RunAs flag set on both shortcuts." -ForegroundColor Green

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host ''
Write-Host '=============================================' -ForegroundColor Yellow
Write-Host ' INSTALL COMPLETE' -ForegroundColor Yellow
Write-Host '=============================================' -ForegroundColor Yellow
Write-Host " Install dir:   $InstallPath"
Write-Host " Data / logs:   $env:ProgramData\NetSetPS\"
Write-Host " Shortcut opts: ExecutionPolicy=AllSigned, WindowStyle=Minimized"
Write-Host " Native code:   $(if ($hasDll) { 'DLL (pre-compiled, no csc.exe)' } else { 'inline Add-Type (fallback, AV-noisy)' })"
Write-Host ''
Write-Host ' HOW IT WORKS:' -ForegroundColor Yellow
Write-Host '   - Double-click NetSetPS on the public desktop.'
Write-Host '   - Windows shows UAC prompt for admin credentials.'
Write-Host '   - PowerShell console briefly flashes in taskbar (Minimized),'
Write-Host '     then the WPF window / tray icon appears.'
Write-Host '   - Close the app to end the process. Next launch = new UAC prompt.'
Write-Host ''
Write-Host ' IF BITDEFENDER (OR ANOTHER AV) STILL FLAGS THE APP:' -ForegroundColor Yellow
Write-Host '   Add these to Bitdefender Protection > Advanced Threat Defense > Exceptions:'
Write-Host "     $InstallPath\NetSetPS.ps1"
Write-Host "     $InstallPath\NetSetPS.Native.dll"
Write-Host "     $env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Host ''
