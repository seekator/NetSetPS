#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    NetSetPS uninstaller.
.DESCRIPTION
    Removes NetSetPS from the system. Aborts early if the application is
    still running (files locked) instead of silently pretending success.
.PARAMETER InstallPath
    Where NetSetPS.ps1 was installed. Default: C:\Program Files\NetSetPS
.PARAMETER KeepProfiles
    Keep profiles.json / settings.json / log in C:\ProgramData\NetSetPS
.PARAMETER RevokeFromUser
    Remove specified user from Network Configuration Operators
    (legacy install variant).
.PARAMETER RemoveTokenPolicy
    Delete HKLM LocalAccountTokenFilterPolicy value (legacy install variant).
.PARAMETER Force
    Skip the running-app check and try to remove files anyway.
.EXAMPLE
    .\Uninstall.ps1
    .\Uninstall.ps1 -KeepProfiles
    .\Uninstall.ps1 -RevokeFromUser 'Danie' -RemoveTokenPolicy
.NOTES
    Author: Daniel Kaszper (digitlife.pl)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$InstallPath      = "$env:ProgramFiles\NetSetPS",
    [switch]$KeepProfiles,
    [string]$RevokeFromUser   = '',
    [switch]$RemoveTokenPolicy,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

Write-Host 'Uninstalling NetSetPS...' -ForegroundColor Cyan

# 0. Detect running instance before touching files
if (-not $Force) {
    $scriptPath = Join-Path $InstallPath 'NetSetPS.ps1'
    if (Test-Path $scriptPath) {
        $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*NetSetPS.ps1*" }
        if ($running) {
            Write-Host ''
            Write-Warning 'NetSetPS appears to be running:'
            $running | ForEach-Object { Write-Host "  PID $($_.ProcessId)  $($_.CommandLine)" -ForegroundColor Yellow }
            Write-Host ''
            Write-Host '  Close the app first (right-click tray icon -> Exit)' -ForegroundColor Yellow
            Write-Host '  or re-run with -Force to kill and continue.' -ForegroundColor Yellow
            throw 'Uninstall aborted. Running instance would prevent file removal.'
        }
    }
} else {
    # Force mode: kill any running NetSetPS processes
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*NetSetPS.ps1*" } |
        ForEach-Object {
            Write-Host "  Killing PID $($_.ProcessId) (Force mode)" -ForegroundColor Yellow
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Milliseconds 500
}

# 1. Scheduled tasks
foreach ($t in @('NetSetPS', 'NetSetPS-Autostart')) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Host "  [x] Removed task: $t" -ForegroundColor Green
    }
}

# 2. Shortcuts (public + legacy per-user paths)
foreach ($p in @(
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'NetSetPS.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'NetSetPS.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'NetSetPS.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'NetSetPS.lnk')
)) {
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host "  [x] Removed shortcut: $p" -ForegroundColor Green
    }
}

# 3. Application directory - only prints success if all files removed
if (Test-Path $InstallPath) {
    try {
        Remove-Item $InstallPath -Recurse -Force -ErrorAction Stop
        Write-Host "  [x] Removed: $InstallPath" -ForegroundColor Green
    } catch {
        Write-Warning "Could not fully remove $InstallPath - some files may still be in use: $_"
        if (Test-Path $InstallPath) {
            $left = Get-ChildItem $InstallPath -Recurse -File -ErrorAction SilentlyContinue
            if ($left) {
                Write-Host "  [!] Files still present:" -ForegroundColor Yellow
                $left | ForEach-Object { Write-Host "      $($_.FullName)" -ForegroundColor Yellow }
            }
        }
    }
}

# 4. User data
if (-not $KeepProfiles) {
    $dataDir = Join-Path $env:ProgramData 'NetSetPS'
    if (Test-Path $dataDir) {
        Remove-Item $dataDir -Recurse -Force
        Write-Host "  [x] Removed data: $dataDir" -ForegroundColor Green
    }
} else {
    Write-Host "  [i] Kept data in $env:ProgramData\NetSetPS" -ForegroundColor Yellow
}

# 5. Legacy NetConfigOps revoke
if ($RevokeFromUser) {
    try {
        $groupSid  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-556'
        $groupName = ($groupSid.Translate([System.Security.Principal.NTAccount])).Value.Split('\')[-1]
        Remove-LocalGroupMember -Group $groupName -Member $RevokeFromUser -ErrorAction Stop
        Write-Host "  [x] Removed '$RevokeFromUser' from '$groupName'." -ForegroundColor Green
        Write-Host "  [i] User must log off and back on for change to apply." -ForegroundColor Yellow
    } catch {
        Write-Warning "Could not remove '$RevokeFromUser' from NetConfigOps: $_"
    }
}

# 6. Legacy registry policy
if ($RemoveTokenPolicy) {
    $polKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $polName = 'LocalAccountTokenFilterPolicy'
    try {
        $existing = Get-ItemProperty -Path $polKey -Name $polName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-ItemProperty -Path $polKey -Name $polName -Force
            Write-Host "  [x] Removed LocalAccountTokenFilterPolicy from HKLM." -ForegroundColor Green
            Write-Host "  [i] Reboot required for LSA to re-read the policy state." -ForegroundColor Yellow
        } else {
            Write-Host "  [i] LocalAccountTokenFilterPolicy was not set - nothing to remove." -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Failed to remove token policy: $_"
    }
}

Write-Host 'Done.' -ForegroundColor Cyan
