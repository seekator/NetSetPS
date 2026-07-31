#Requires -Version 5.1
<#
.SYNOPSIS
    Builds NetSetPS.Native.dll from inline C# P/Invoke definitions.
.DESCRIPTION
    Compiles Win32 API wrappers used by NetSetPS.ps1 (icon extraction,
    foreground window control) to a pre-built DLL. Loading this DLL at
    runtime is faster than Add-Type with C# source and avoids spawning
    csc.exe / cvtres.exe child processes, which behavioral AV engines
    (Bitdefender ATD, Kaspersky System Watcher, Windows Defender ML)
    fingerprint as fileless-malware indicators.

    Run this ONCE per new PowerShell / .NET Framework major version.
    The resulting DLL goes into the repo folder next to NetSetPS.ps1
    and is copied to the install directory by Install.ps1.
.PARAMETER OutputPath
    Where to write the DLL. Default: $PSScriptRoot\NetSetPS.Native.dll
.PARAMETER Sign
    Also sign the DLL with a code-signing cert if 'CN=NetSetPS Self-Signed'
    exists in Cert:\CurrentUser\My.
.EXAMPLE
    .\Build-Native.ps1
    .\Build-Native.ps1 -Sign
.NOTES
    Author: Daniel Kaszper (digitlife.pl)
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "$PSScriptRoot\NetSetPS.Native.dll",
    [switch]$Sign
)

$ErrorActionPreference = 'Stop'

Write-Host "Building $OutputPath" -ForegroundColor Cyan

# Remove old artifact if present (Add-Type refuses to overwrite in some cases)
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Force
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace NetSetPS
{
    public static class Native
    {
        [DllImport("shell32.dll", CharSet = CharSet.Auto)]
        public static extern uint ExtractIconEx(
            string lpszFile, int nIconIndex,
            IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        // SW_HIDE = 0
        public const int SW_HIDE = 0;
    }
}
'@ -OutputAssembly $OutputPath -OutputType Library

if (-not (Test-Path $OutputPath)) {
    throw "Compilation succeeded but DLL not found at $OutputPath"
}

$size = (Get-Item $OutputPath).Length
Write-Host "OK. Built: $OutputPath ($size bytes)" -ForegroundColor Green

# Optional signing (only if a NetSetPS self-signed cert already exists)
if ($Sign) {
    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq 'CN=NetSetPS Self-Signed' -and $_.NotAfter -gt (Get-Date) } |
        Select-Object -First 1
    if (-not $cert) {
        Write-Warning "No 'CN=NetSetPS Self-Signed' cert found. Run Sign.ps1 first or skip -Sign."
    } else {
        $sig = Set-AuthenticodeSignature -FilePath $OutputPath -Certificate $cert
        Write-Host "Signed. Status: $($sig.Status)" -ForegroundColor $(
            if ($sig.Status -eq 'Valid') { 'Green' } else { 'Yellow' }
        )
    }
}
