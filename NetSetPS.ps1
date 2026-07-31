#Requires -Version 5.1
<#
.SYNOPSIS
    NetSetPS - a NetSetMan equivalent written in PowerShell + WPF.
.DESCRIPTION
    Manages network profiles for a selected adapter (IP/mask/GW/DNS, DHCP).
    Run via the shortcut invoking the scheduled task (see Install.ps1),
    to avoid the UAC prompt on every start.
.NOTES
    Author: Daniel Kaszper (digitlife.pl)
#>

[CmdletBinding()]
param(
    [switch]$StartMinimized
)

$ErrorActionPreference = 'Stop'

# --- Assemble WPF ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Paths ---
$Script:AppDir       = Join-Path $env:ProgramData 'NetSetPS'
$Script:ProfilesFile = Join-Path $Script:AppDir 'profiles.json'
$Script:SettingsFile = Join-Path $Script:AppDir 'settings.json'
$Script:LogFile      = Join-Path $Script:AppDir 'netsetps.log'

if (-not (Test-Path $Script:AppDir)) {
    New-Item -Path $Script:AppDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch {}
}

# Perf logger - measures elapsed time of a scriptblock and logs it.
# Used during startup to identify slow initialization steps.
function Measure-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Script
    } finally {
        $sw.Stop()
        Write-Log ("PERF {0}: {1}ms" -f $Name, $sw.ElapsedMilliseconds) 'PERF'
    }
}

# Cache for slow queries - refreshed manually via Reset-*Cache functions
$Script:AutostartCache = @{ Value = $null; StampSec = 0 }

Write-Log "Application start. User=$env:USERNAME, Elevated=$([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

# ============================================================
#   FUNCTIONS - PROFILES
# ============================================================
function Load-Profiles {
    if (Test-Path $Script:ProfilesFile) {
        try {
            $raw = Get-Content $Script:ProfilesFile -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
            $data = $raw | ConvertFrom-Json
            if ($null -eq $data) { return @() }
            # Ensure array
            return @($data)
        } catch {
            Write-Log "Error reading profiles: $_" 'ERROR'
            return @()
        }
    }
    return @()
}

function Save-Profiles {
    param([array]$Profiles)
    try {
        ($Profiles | ConvertTo-Json -Depth 6) | Set-Content -Path $Script:ProfilesFile -Encoding UTF8
        Write-Log "Saved profiles: $($Profiles.Count) items"
    } catch {
        Write-Log "Error saving profiles: $_" 'ERROR'
        throw
    }
}

# ============================================================
#   FUNCTIONS - SETTINGS AND THEME
# ============================================================
function Load-Settings {
    $defaults = [PSCustomObject]@{
        Theme       = 'Light'
        LastAdapter = ''
    }
    if (Test-Path $Script:SettingsFile) {
        try {
            $s = Get-Content $Script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not ($s.PSObject.Properties.Name -contains 'Theme')) {
                $s | Add-Member -NotePropertyName Theme -NotePropertyValue 'Light' -Force
            }
            if (-not ($s.PSObject.Properties.Name -contains 'LastAdapter')) {
                $s | Add-Member -NotePropertyName LastAdapter -NotePropertyValue '' -Force
            }
            return $s
        } catch {
            Write-Log "Error reading settings, using defaults: $_" 'WARN'
        }
    }
    return $defaults
}

function Save-Settings {
    param($Settings)
    try {
        ($Settings | ConvertTo-Json) | Set-Content -Path $Script:SettingsFile -Encoding UTF8
    } catch {
        Write-Log "Error saving settings: $_" 'ERROR'
    }
}

function Get-ThemePalette {
    param([string]$Theme)
    if ($Theme -eq 'Dark') {
        return @{
            BgWindow    = '#1E1E1E'
            BgGroup     = '#252526'
            BgControl   = '#333337'
            BgListItem  = '#2D2D30'
            FgText      = '#F1F1F1'
            FgLabel     = '#CCCCCC'
            BorderClr   = '#3F3F46'
            BgAccent    = '#0E639C'
            FgAccent    = '#FFFFFF'
            BgStatus    = '#007ACC'
        }
    }
    # Light (default)
    return @{
        BgWindow    = '#F3F3F3'
        BgGroup     = '#FAFAFA'
        BgControl   = '#FFFFFF'
        BgListItem  = '#FFFFFF'
        FgText      = '#000000'
        FgLabel     = '#333333'
        BorderClr   = '#CCCCCC'
        BgAccent    = '#0078D4'
        FgAccent    = '#FFFFFF'
        BgStatus    = '#007ACC'
    }
}

function Apply-Theme {
    param(
        [Parameter(Mandatory)]$TargetWindow,
        [Parameter(Mandatory)][string]$Theme
    )
    $palette = Get-ThemePalette -Theme $Theme
    # IMPORTANT: do not use indexer $Resources[$key] = $brush, because PS wraps
    # the value in PSObject and DynamicResource later cannot cast it
    # to Brush -> exception in ShowDialog. We use Remove() + Add().
    # Key copy because we modify the collection in the loop.
    foreach ($key in @($palette.Keys)) {
        try {
            $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
            $brush = [System.Windows.Media.SolidColorBrush]::new($color)
            $brush.Freeze()

            if ($TargetWindow.Resources.Contains($key)) {
                $TargetWindow.Resources.Remove($key)
            }
            [void]$TargetWindow.Resources.Add($key, $brush)
        } catch {
            Write-Log "Error setting color $key = $($palette[$key]): $_" 'WARN'
        }
    }
}

# ============================================================
#   FUNCTIONS - IMPORT / EXPORT
# ============================================================
function Export-ProfilesToFile {
    if (-not $Script:Profiles -or $Script:Profiles.Count -eq 0) {
        [System.Windows.MessageBox]::Show('No profiles to export.', 'Info', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = "JSON (*.json)|*.json|Wszystkie pliki (*.*)|*.*"
    $dlg.FileName = "netsetman-profiles-$(Get-Date -Format 'yyyy-MM-dd').json"
    $dlg.Title    = 'Export profiles'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog() -eq $true) {
        try {
            ($Script:Profiles | ConvertTo-Json -Depth 6) | Set-Content -Path $dlg.FileName -Encoding UTF8
            Write-Log "Export OK: $($dlg.FileName) ($($Script:Profiles.Count) items)"
            $controls.tbStatusBar.Text = "Exported $($Script:Profiles.Count) profiles to: $($dlg.FileName)"
        } catch {
            Write-Log "Export error: $_" 'ERROR'
            [System.Windows.MessageBox]::Show("Export error: $_", 'Error', 'OK', 'Error') | Out-Null
        }
    }
}

function Import-ProfilesFromFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "JSON (*.json)|*.json|Wszystkie pliki (*.*)|*.*"
    $dlg.Title  = 'Import profiles'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog() -ne $true) { return }

    try {
        $raw = Get-Content $dlg.FileName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            [System.Windows.MessageBox]::Show('File is empty.', 'Info', 'OK', 'Information') | Out-Null
            return
        }
        $imported = @($raw | ConvertFrom-Json)
        if ($imported.Count -eq 0) {
            [System.Windows.MessageBox]::Show('No profiles in file.', 'Info', 'OK', 'Information') | Out-Null
            return
        }

        # Minimal validation
        $valid = @($imported | Where-Object { $_.Name -and $_.PSObject.Properties['UseDHCP'] })
        if ($valid.Count -ne $imported.Count) {
            $skipMalformed = $imported.Count - $valid.Count
            Write-Log "Import: skipped $skipMalformed invalid entries" 'WARN'
        }
        if ($valid.Count -eq 0) {
            [System.Windows.MessageBox]::Show('No profile in the file has required fields (Name, UseDHCP).', 'Error', 'OK', 'Warning') | Out-Null
            return
        }

        # Duplicate handling strategy
        $existingNames = @($Script:Profiles | ForEach-Object { $_.Name })
        $conflicts = @($valid | Where-Object { $existingNames -contains $_.Name })

        $mode = 'Add'
        if ($conflicts.Count -gt 0) {
            $msg = "The file has $($valid.Count) profiles, including $($conflicts.Count) with names you already have.`n`n" +
                   "YES     -> overwrite existing`n" +
                   "NO      -> skip duplicates (add only new)`n" +
                   "CANCEL  -> abort import"
            $r = [System.Windows.MessageBox]::Show($msg, 'Name conflict', 'YesNoCancel', 'Question')
            if ($r -eq 'Cancel') { return }
            $mode = if ($r -eq 'Yes') { 'Overwrite' } else { 'Skip' }
        }

        $added = 0; $overwritten = 0; $skipped = 0
        foreach ($p in $valid) {
            $exists = $Script:Profiles | Where-Object { $_.Name -eq $p.Name }
            if ($exists) {
                if ($mode -eq 'Overwrite') {
                    $Script:Profiles = @($Script:Profiles | Where-Object { $_.Name -ne $p.Name }) + $p
                    $overwritten++
                } else {
                    $skipped++
                }
            } else {
                $Script:Profiles = @($Script:Profiles) + $p
                $added++
            }
        }

        Save-Profiles -Profiles $Script:Profiles
        Refresh-ProfilesList
        $summary = "Import: added=$added, overwritten=$overwritten, skipped=$skipped."
        Write-Log "$summary Source=$($dlg.FileName)"
        $controls.tbStatusBar.Text = $summary
    } catch {
        Write-Log "Import error: $_" 'ERROR'
        [System.Windows.MessageBox]::Show("Import error: $_", 'Error', 'OK', 'Error') | Out-Null
    }
}

# ============================================================
#   FUNCTIONS - NETWORK ADAPTER
# ============================================================
function Get-AdapterList {
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.HardwareInterface -eq $true -or $_.Virtual -eq $true } |
        Sort-Object -Property Status, Name |
        ForEach-Object {
            [PSCustomObject]@{
                Name        = $_.Name
                Description = $_.InterfaceDescription
                Status      = $_.Status
                MAC         = $_.MacAddress
                ifIndex     = $_.ifIndex
                Display     = "{0}  [{1}]  ({2})" -f $_.Name, $_.Status, $_.InterfaceDescription
            }
        }
}

function Get-AdapterConfig {
    param([string]$Name)
    $adapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    if (-not $adapter) { return $null }
    $idx = $adapter.ifIndex

    $ip = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
    $gw = (Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object DestinationPrefix -eq '0.0.0.0/0' | Select-Object -First 1).NextHop
    $dns = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $iface = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Name         = $adapter.Name
        Description  = $adapter.InterfaceDescription
        Status       = $adapter.Status
        MAC          = $adapter.MacAddress
        LinkSpeed    = $adapter.LinkSpeed
        DHCP         = if ($iface) { $iface.Dhcp } else { 'Unknown' }
        IPAddress    = if ($ip) { $ip.IPAddress } else { '(none)' }
        PrefixLength = if ($ip) { $ip.PrefixLength } else { '' }
        SubnetMask   = if ($ip) { Convert-PrefixToMask $ip.PrefixLength } else { '' }
        Gateway      = if ($gw) { $gw } else { '(none)' }
        DNS1         = if ($dns.Count -ge 1) { $dns[0] } else { '' }
        DNS2         = if ($dns.Count -ge 2) { $dns[1] } else { '' }
        AllDNS       = ($dns -join ', ')
    }
}

function Convert-PrefixToMask {
    param([int]$Prefix)
    if ($Prefix -lt 0 -or $Prefix -gt 32) { return '' }
    $bin = ('1' * $Prefix).PadRight(32, '0')
    $octets = for ($i = 0; $i -lt 4; $i++) {
        [Convert]::ToInt32($bin.Substring($i*8, 8), 2)
    }
    return ($octets -join '.')
}

function Convert-MaskToPrefix {
    param([string]$Mask)
    try {
        $octets = $Mask.Split('.') | ForEach-Object { [int]$_ }
        if ($octets.Count -ne 4) { return $null }
        $bin = ($octets | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        if ($bin -notmatch '^1*0*$') { return $null }
        return ($bin -replace '0', '').Length
    } catch { return $null }
}

function Test-IPv4 {
    param([string]$IP)
    if ([string]::IsNullOrWhiteSpace($IP)) { return $false }
    return ($IP -match '^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$')
}

# ============================================================
#   FUNCTIONS - APPLY PROFILE
# ============================================================
function Invoke-Netsh {
    # Wrapper that runs netsh and throws on failure. Captures both stdout+stderr.
    # PowerShell's & operator handles argument boundaries correctly, including
    # adapter names with spaces (they arrive as one arg to netsh.exe).
    param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    $out = & netsh.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $joined = ($Arguments -join ' ')
        throw "netsh $joined failed (exit $LASTEXITCODE): $out"
    }
    return $out
}

function Apply-Profile {
    # NOTE: This function uses netsh instead of PowerShell's *-Net* cmdlets.
    # Reason: the Net* cmdlets go through the CIM/WMI provider which requires
    # BUILTIN\Administrators. netsh interface ipv4 respects the older per-group
    # permissions model, so members of Network Configuration Operators
    # (SID S-1-5-32-556) can run it without full admin rights and without UAC.
    # This is what makes the "click from a standard user account" workflow work.
    param(
        [Parameter(Mandatory)][PSCustomObject]$Profile,
        [Parameter(Mandatory)][string]$AdapterName
    )
    Write-Log "Applying profile '$($Profile.Name)' to adapter '$AdapterName'"

    if ($Profile.UseDHCP) {
        # DHCP for IP + DNS. netsh 'set address source=dhcp' clears static IP,
        # mask, and gateway atomically.
        Invoke-Netsh 'interface' 'ipv4' 'set' 'address' "name=$AdapterName" 'source=dhcp' | Out-Null
        Invoke-Netsh 'interface' 'ipv4' 'set' 'dnsservers' "name=$AdapterName" 'source=dhcp' | Out-Null

        # Force lease renewal so we get a fresh address right away.
        & ipconfig.exe /renew "$AdapterName" 2>&1 | Out-Null
        Write-Log "Set DHCP on adapter '$AdapterName'"
    } else {
        # Static: netsh needs a dotted subnet mask, not a CIDR prefix.
        $mask = Convert-PrefixToMask ([int]$Profile.PrefixLength)
        if (-not $mask) {
            throw "Invalid prefix length: $($Profile.PrefixLength)"
        }

        # set address ... static <ip> <mask> [<gw>]. Setting static IP also
        # implicitly disables DHCP on the interface. Gateway is optional
        # (netsh accepts the argument being omitted).
        $addrArgs = @('interface', 'ipv4', 'set', 'address', "name=$AdapterName", 'static', $Profile.IPAddress, $mask)
        if ($Profile.Gateway) { $addrArgs += $Profile.Gateway }
        Invoke-Netsh @addrArgs | Out-Null

        # DNS: 'set dnsservers static <ip> primary validate=no' resets the list
        # to a single primary. Then optional secondary via 'add ... index=2'.
        # validate=no skips netsh's ping test - important when moving between
        # networks where the new DNS isn't reachable yet from the OLD address.
        if ($Profile.DNS1) {
            Invoke-Netsh 'interface' 'ipv4' 'set' 'dnsservers' "name=$AdapterName" 'static' $Profile.DNS1 'primary' 'validate=no' | Out-Null
            if ($Profile.DNS2) {
                Invoke-Netsh 'interface' 'ipv4' 'add' 'dnsservers' "name=$AdapterName" $Profile.DNS2 'index=2' 'validate=no' | Out-Null
            }
        } else {
            # No DNS in profile - fall back to DHCP-assigned DNS
            Invoke-Netsh 'interface' 'ipv4' 'set' 'dnsservers' "name=$AdapterName" 'source=dhcp' | Out-Null
        }
        Write-Log "Set static IP $($Profile.IPAddress)/$($Profile.PrefixLength) GW=$($Profile.Gateway) DNS=$($Profile.DNS1),$($Profile.DNS2) on '$AdapterName'"
    }

    # Clear DNS cache so next lookups hit fresh data.
    & ipconfig.exe /flushdns 2>&1 | Out-Null
}

# ============================================================
#   FUNCTIONS - SYSTEM TRAY
# ============================================================

# Native P/Invoke - Win32 APIs for tray icon extraction and foreground fix.
# Loads a pre-compiled DLL instead of Add-Type with C# source. This avoids
# spawning csc.exe and cvtres.exe as child processes at runtime, which is a
# fingerprint that behavioral AV (Bitdefender ATD, Kaspersky System Watcher)
# associates with fileless malware. Pre-compiled once via Build-Native.ps1.
if (-not ('NetSetPS.Native' -as [Type])) {
    $nativeDll = Join-Path $PSScriptRoot 'NetSetPS.Native.dll'
    if (Test-Path $nativeDll) {
        Add-Type -Path $nativeDll
    } else {
        # Fallback: compile in-memory. Slower and AV-noisy but works if
        # someone runs the script without building the DLL first.
        Write-Log "NetSetPS.Native.dll not found - falling back to inline Add-Type." 'WARN'
        Add-Type -Namespace 'NetSetPS' -Name 'Native' -MemberDefinition @'
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
'@
    }
}

# Hide the PowerShell console window that was started by the shortcut.
# The shortcut uses -WindowStyle Minimized (not Hidden) to keep AV happy,
# so a minimized console window sits in the taskbar next to our WPF window.
# We hide it here from within the script - AV does not see this as a
# suspicious command-line pattern, but the user gets the desired effect.
try {
    $consoleHandle = [NetSetPS.Native]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][NetSetPS.Native]::ShowWindow($consoleHandle, 0)  # 0 = SW_HIDE
    }
} catch {
    # Older DLL without GetConsoleWindow - not critical, ignore
    Write-Log "Could not hide console: $_" 'WARN'
}

$Script:AutostartTaskName = 'NetSetPS-Autostart'

function Get-TrayIcon {
    # Grab a small network icon from netshell.dll (index 0 = generic connection icon)
    $path = Join-Path $env:SystemRoot 'System32\netshell.dll'
    $small = New-Object IntPtr[] 1
    $large = New-Object IntPtr[] 1
    try {
        [NetSetPS.Native]::ExtractIconEx($path, 0, $large, $small, 1) | Out-Null
        if ($small[0] -ne [IntPtr]::Zero) {
            # FromHandle does NOT copy - Icon owns the handle for its lifetime
            $icon = [System.Drawing.Icon]::FromHandle($small[0])
            # Release large icon handle if we got one
            if ($large[0] -ne [IntPtr]::Zero) {
                [NetSetPS.Native]::DestroyIcon($large[0]) | Out-Null
            }
            return $icon
        }
    } catch {
        Write-Log "Failed to extract tray icon: $_" 'WARN'
    }
    # Fallback: application default
    return [System.Drawing.SystemIcons]::Application
}

function Test-ProfileMatches {
    param($Profile, $Config)
    if (-not $Profile -or -not $Config) { return $false }

    if ($Profile.UseDHCP) {
        return ($Config.DHCP -eq 'Enabled')
    }

    if ($Config.DHCP -ne 'Disabled') { return $false }
    if ($Profile.IPAddress -ne $Config.IPAddress) { return $false }
    if ([int]$Profile.PrefixLength -ne [int]$Config.PrefixLength) { return $false }
    # Gateway - '(none)' from config means no gateway
    $cfgGw = if ($Config.Gateway -eq '(none)') { '' } else { $Config.Gateway }
    if (($Profile.Gateway -as [string]) -ne ($cfgGw -as [string])) { return $false }
    # DNS comparison - order-sensitive
    $pDns = @($Profile.DNS1, $Profile.DNS2) | Where-Object { $_ }
    $cDns = @($Config.DNS1, $Config.DNS2) | Where-Object { $_ }
    if (($pDns -join ',') -ne ($cDns -join ',')) { return $false }
    return $true
}

function Test-AutostartEnabled {
    # Get-ScheduledTask is a 2-3 second CIM call on cold cache and it fires
    # on every tray menu open. We cache the result for 60 seconds (unless
    # Enable/Disable-Autostart invalidates it, which happens immediately).
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($null -ne $Script:AutostartCache.Value -and ($now - $Script:AutostartCache.StampSec) -lt 60) {
        return $Script:AutostartCache.Value
    }
    $t = Get-ScheduledTask -TaskName $Script:AutostartTaskName -ErrorAction SilentlyContinue
    $Script:AutostartCache.Value    = ($null -ne $t)
    $Script:AutostartCache.StampSec = $now
    return $Script:AutostartCache.Value
}

function Reset-AutostartCache {
    $Script:AutostartCache.Value    = $null
    $Script:AutostartCache.StampSec = 0
}

function Enable-Autostart {
    try {
        $scriptPath = $PSCommandPath
        if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -StartMinimized"

        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

        $principal = New-ScheduledTaskPrincipal `
            -UserId $env:USERNAME `
            -LogonType Interactive `
            -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
            -MultipleInstances IgnoreNew `
            -StartWhenAvailable

        Register-ScheduledTask `
            -TaskName $Script:AutostartTaskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Force `
            -Description 'NetSetPS - autostart at logon' | Out-Null

        Reset-AutostartCache
        Write-Log "Autostart enabled"
        return $true
    } catch {
        Write-Log "Error enabling autostart: $_" 'ERROR'
        [System.Windows.MessageBox]::Show("Failed to enable autostart: $_", 'Error', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Disable-Autostart {
    try {
        if (Get-ScheduledTask -TaskName $Script:AutostartTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $Script:AutostartTaskName -Confirm:$false
        }
        Reset-AutostartCache
        Write-Log "Autostart disabled"
        return $true
    } catch {
        Write-Log "Error disabling autostart: $_" 'ERROR'
        return $false
    }
}

function Show-MainWindow {
    if (-not $window) { return }
    $window.Dispatcher.Invoke([Action]{
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $window.WindowState = [System.Windows.WindowState]::Normal
        }
        $window.Show()
        $window.Activate()
        $window.Topmost = $true
        $window.Topmost = $false  # trick to bring to foreground
        Refresh-Adapters
        Refresh-CurrentConfig
        Refresh-ProfilesList
    })
}

function Apply-ProfileFromTray {
    param($Profile, $AdapterName)
    try {
        Apply-Profile -Profile $Profile -AdapterName $AdapterName
        Start-Sleep -Milliseconds 400
        $Script:NotifyIcon.ShowBalloonTip(
            2000,
            'NetSetPS',
            "Applied '$($Profile.Name)' to $AdapterName",
            [System.Windows.Forms.ToolTipIcon]::Info)
        if ($window.IsVisible) {
            $window.Dispatcher.Invoke([Action]{ Refresh-CurrentConfig })
        }
    } catch {
        Write-Log "Error applying from tray: $_" 'ERROR'
        $Script:NotifyIcon.ShowBalloonTip(
            3000,
            'NetSetPS - Error',
            "Failed to apply '$($Profile.Name)': $_",
            [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Build-TrayMenu {
    $Script:ContextMenu.Items.Clear()

    # Header (disabled bold)
    $header = $Script:ContextMenu.Items.Add('NetSetPS')
    $header.Enabled = $false
    $header.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    [void]$Script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Determine current adapter (from settings; fallback to first Up adapter)
    $adapterName = $Script:Settings.LastAdapter
    if (-not $adapterName) {
        $all = @(Get-AdapterList)
        if ($all.Count -gt 0) {
            $upOnes = @($all | Where-Object { $_.Status -eq 'Up' })
            $pick = if ($upOnes.Count -gt 0) { $upOnes[0] } else { $all[0] }
            $adapterName = $pick.Name
            $Script:Settings.LastAdapter = $adapterName
            Save-Settings -Settings $Script:Settings
        }
    }

    $currentLabel = if ($adapterName) { "Current adapter: $adapterName" } else { 'No adapter available' }
    $current = $Script:ContextMenu.Items.Add($currentLabel)
    $current.Enabled = $false

    [void]$Script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Apply profile submenu
    $applyRoot = New-Object System.Windows.Forms.ToolStripMenuItem 'Apply profile'
    if ($adapterName -and $Script:Profiles.Count -gt 0) {
        $currentCfg = Get-AdapterConfig -Name $adapterName
        foreach ($p in $Script:Profiles) {
            $isActive = $currentCfg -and (Test-ProfileMatches -Profile $p -Config $currentCfg)
            # '● ' prefix for the active profile, blank spaces for others (visual alignment)
            $prefix = if ($isActive) { [char]0x25CF, ' ' -join '' } else { '   ' }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem ($prefix + $p.Name)
            $item.Tag = @{ Profile = $p; Adapter = $adapterName }
            $item.Add_Click({
                param($sender, $e)
                $ctx = $sender.Tag
                Apply-ProfileFromTray -Profile $ctx.Profile -AdapterName $ctx.Adapter
            })
            [void]$applyRoot.DropDownItems.Add($item)
        }
    } elseif (-not $adapterName) {
        $applyRoot.Enabled = $false
    } else {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem '(no profiles)'
        $none.Enabled = $false
        [void]$applyRoot.DropDownItems.Add($none)
    }
    [void]$Script:ContextMenu.Items.Add($applyRoot)

    # Change adapter submenu
    $adapterRoot = New-Object System.Windows.Forms.ToolStripMenuItem 'Change adapter'
    foreach ($a in Get-AdapterList) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem "$($a.Name)  [$($a.Status)]"
        $item.Tag = $a.Name
        if ($a.Name -eq $adapterName) { $item.Checked = $true }
        $item.Add_Click({
            param($sender, $e)
            $newName = $sender.Tag
            $Script:Settings.LastAdapter = $newName
            Save-Settings -Settings $Script:Settings
            # Sync main window ComboBox if visible
            if ($window.IsVisible) {
                $window.Dispatcher.Invoke([Action]{
                    for ($i = 0; $i -lt $controls.cbAdapter.Items.Count; $i++) {
                        if ($controls.cbAdapter.Items[$i].Tag.Name -eq $newName) {
                            $controls.cbAdapter.SelectedIndex = $i
                            break
                        }
                    }
                })
            }
        })
        [void]$adapterRoot.DropDownItems.Add($item)
    }
    [void]$Script:ContextMenu.Items.Add($adapterRoot)

    [void]$Script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Show / Hide window
    if ($window.IsVisible) {
        $vis = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide window'
        $vis.Add_Click({ $window.Dispatcher.Invoke([Action]{ $window.Hide() }) })
    } else {
        $vis = New-Object System.Windows.Forms.ToolStripMenuItem 'Show window'
        $vis.Add_Click({ Show-MainWindow })
    }
    [void]$Script:ContextMenu.Items.Add($vis)

    [void]$Script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Start with Windows toggle
    $autostart = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
    $autostart.Checked = Test-AutostartEnabled
    $autostart.Add_Click({
        param($sender, $e)
        if ($sender.Checked) {
            if (Disable-Autostart) {
                $Script:NotifyIcon.ShowBalloonTip(1500, 'NetSetPS', 'Autostart disabled', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } else {
            if (Enable-Autostart) {
                $Script:NotifyIcon.ShowBalloonTip(1500, 'NetSetPS', 'Autostart enabled', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    })
    [void]$Script:ContextMenu.Items.Add($autostart)

    [void]$Script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Exit
    $exit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $exit.Add_Click({
        $window.Dispatcher.Invoke([Action]{ $window.Close() })
    })
    [void]$Script:ContextMenu.Items.Add($exit)
}

function Initialize-Tray {
    $Script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $Script:NotifyIcon.Icon = Get-TrayIcon
    $Script:NotifyIcon.Text = 'NetSetPS'
    $Script:NotifyIcon.Visible = $true

    $Script:ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    # NOTE: intentionally NOT setting $NotifyIcon.ContextMenuStrip = $ContextMenu.
    # The WinForms auto-display path has a well-known bug (Raymond Chen, 2014):
    # the first right-click misses activation because there is no focused window
    # to receive the menu message. We show it manually in MouseUp after calling
    # SetForegroundWindow on our window's handle.

    # Force the WPF window handle to exist even before ShowDialog, so we can
    # pass it to SetForegroundWindow.
    $wih = New-Object System.Windows.Interop.WindowInteropHelper $window
    $wih.EnsureHandle() | Out-Null
    $Script:WindowHandle = $wih.Handle

    # Rebuild menu each time it opens (adapters/profiles/state may have changed)
    $Script:ContextMenu.Add_Opening({ Build-TrayMenu })

    # Right-click: manual show with foreground-window fix
    $Script:NotifyIcon.Add_MouseUp({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            [NetSetPS.Native]::SetForegroundWindow($Script:WindowHandle) | Out-Null
            $Script:ContextMenu.Show([System.Windows.Forms.Cursor]::Position)
        }
    })

    # Double-click on tray icon = show window
    $Script:NotifyIcon.Add_MouseDoubleClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Show-MainWindow
        }
    })
}

# ============================================================
#   XAML - MAIN WINDOW
# ============================================================
[xml]$XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NetSetPS" Height="700" Width="880"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource BgWindow}">
    <Window.Resources>
        <!-- Default brushes (Light) - swapped in code by Apply-Theme -->
        <SolidColorBrush x:Key="BgWindow"   Color="#F3F3F3"/>
        <SolidColorBrush x:Key="BgGroup"    Color="#FAFAFA"/>
        <SolidColorBrush x:Key="BgControl"  Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BgListItem" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="FgText"     Color="#000000"/>
        <SolidColorBrush x:Key="FgLabel"    Color="#333333"/>
        <SolidColorBrush x:Key="BorderClr"  Color="#CCCCCC"/>
        <SolidColorBrush x:Key="BgAccent"   Color="#0078D4"/>
        <SolidColorBrush x:Key="FgAccent"   Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BgStatus"   Color="#007ACC"/>

        <Style TargetType="Button">
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Margin" Value="3"/>
            <Setter Property="MinWidth" Value="90"/>
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Margin" Value="6"/>
            <Setter Property="Padding" Value="6"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Background" Value="{DynamicResource BgGroup}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Foreground" Value="{DynamicResource FgLabel}"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
            <Setter Property="CaretBrush" Value="{DynamicResource FgText}"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="24"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.ColumnSpan="2"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}"/>
                            <ToggleButton Grid.ColumnSpan="2" Background="Transparent" BorderThickness="0"
                                          IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          Focusable="False" ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="Transparent"/>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Grid.Column="0"
                                              Margin="{TemplateBinding Padding}"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Left"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              IsHitTestVisible="False"
                                              TextElement.Foreground="{TemplateBinding Foreground}"/>
                            <Path Grid.Column="1" Data="M 0,0 L 4,4 L 8,0 Z"
                                  Fill="{TemplateBinding Foreground}"
                                  HorizontalAlignment="Center" VerticalAlignment="Center"
                                  IsHitTestVisible="False"/>
                            <Popup IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Slide">
                                <Border Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}"
                                        BorderThickness="1"
                                        MinWidth="{TemplateBinding ActualWidth}"
                                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <ScrollViewer>
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBorder"
                                Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource BgAccent}"/>
                                <Setter Property="Foreground" Value="{DynamicResource FgAccent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Background" Value="{DynamicResource BgListItem}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="LbiBorder"
                                Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="LbiBorder" Property="Background" Value="{DynamicResource BgAccent}"/>
                                <Setter Property="Foreground" Value="{DynamicResource FgAccent}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="LbiBorder" Property="Background" Value="{DynamicResource BgAccent}"/>
                                <Setter Property="Foreground" Value="{DynamicResource FgAccent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
        </Style>
        <Style TargetType="StatusBar">
            <Setter Property="Background" Value="{DynamicResource BgGroup}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
        </Style>
    </Window.Resources>

    <Grid Margin="8">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Adapter selection -->
        <GroupBox Grid.Row="0" Header="Network adapter">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ComboBox x:Name="cbAdapter" Height="26" VerticalContentAlignment="Center" FontWeight="Normal"/>
                <Button x:Name="btnRefresh" Grid.Column="1" Content="Refresh" Width="90"/>
            </Grid>
        </GroupBox>

        <!-- Current configuration -->
        <GroupBox Grid.Row="1" Header="Current configuration">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                </Grid.RowDefinitions>

                <Label Grid.Row="0" Grid.Column="0" Content="Status:"/>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="tbStatus" VerticalAlignment="Center"/>
                <Label Grid.Row="0" Grid.Column="2" Content="DHCP:"/>
                <TextBlock Grid.Row="0" Grid.Column="3" x:Name="tbDhcp" VerticalAlignment="Center"/>

                <Label Grid.Row="1" Grid.Column="0" Content="IP address:"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="tbIP" VerticalAlignment="Center"/>
                <Label Grid.Row="1" Grid.Column="2" Content="Subnet mask:"/>
                <TextBlock Grid.Row="1" Grid.Column="3" x:Name="tbMask" VerticalAlignment="Center"/>

                <Label Grid.Row="2" Grid.Column="0" Content="Gateway:"/>
                <TextBlock Grid.Row="2" Grid.Column="1" x:Name="tbGw" VerticalAlignment="Center"/>
                <Label Grid.Row="2" Grid.Column="2" Content="Prefix:"/>
                <TextBlock Grid.Row="2" Grid.Column="3" x:Name="tbPrefix" VerticalAlignment="Center"/>

                <Label Grid.Row="3" Grid.Column="0" Content="DNS:"/>
                <TextBlock Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="3" x:Name="tbDns" VerticalAlignment="Center" TextWrapping="Wrap"/>

                <Label Grid.Row="4" Grid.Column="0" Content="MAC:"/>
                <TextBlock Grid.Row="4" Grid.Column="1" x:Name="tbMac" VerticalAlignment="Center"/>
                <Label Grid.Row="4" Grid.Column="2" Content="Speed:"/>
                <TextBlock Grid.Row="4" Grid.Column="3" x:Name="tbSpeed" VerticalAlignment="Center"/>
            </Grid>
        </GroupBox>

        <!-- Profiles -->
        <GroupBox Grid.Row="2" Header="Profiles">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ListBox x:Name="lbProfiles" FontWeight="Normal"/>
                <StackPanel Grid.Column="1" Orientation="Vertical" Margin="6,0,0,0">
                    <Button x:Name="btnApply" Content="Apply" Background="{DynamicResource BgAccent}" Foreground="{DynamicResource FgAccent}" FontWeight="Bold"/>
                    <Separator Margin="0,6"/>
                    <Button x:Name="btnNew" Content="New..."/>
                    <Button x:Name="btnEdit" Content="Edit..."/>
                    <Button x:Name="btnClone" Content="Duplicate"/>
                    <Button x:Name="btnDelete" Content="Delete"/>
                    <Separator Margin="0,6"/>
                    <Button x:Name="btnFromCurrent" Content="From current"/>
                    <Separator Margin="0,6"/>
                    <Button x:Name="btnImport" Content="Import..."/>
                    <Button x:Name="btnExport" Content="Export..."/>
                </StackPanel>
            </Grid>
        </GroupBox>

        <!-- Status bar -->
        <StatusBar Grid.Row="3">
            <StatusBar.ItemsPanel>
                <ItemsPanelTemplate>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                    </Grid>
                </ItemsPanelTemplate>
            </StatusBar.ItemsPanel>
            <StatusBarItem Grid.Column="0">
                <TextBlock x:Name="tbStatusBar" Text="Ready."/>
            </StatusBarItem>
            <StatusBarItem Grid.Column="1">
                <Button x:Name="btnTheme" Content="Theme: light" MinWidth="120" Padding="6,2" Margin="3,0"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
'@

[xml]$XAML_EDIT = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Edit profile" Height="440" Width="480"
        WindowStartupLocation="CenterOwner"
        Background="{DynamicResource BgWindow}">
    <Window.Resources>
        <SolidColorBrush x:Key="BgWindow"  Color="#F3F3F3"/>
        <SolidColorBrush x:Key="BgGroup"   Color="#FAFAFA"/>
        <SolidColorBrush x:Key="BgControl" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="FgText"    Color="#000000"/>
        <SolidColorBrush x:Key="FgLabel"   Color="#333333"/>
        <SolidColorBrush x:Key="BorderClr" Color="#CCCCCC"/>

        <Style TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Background" Value="{DynamicResource BgGroup}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource FgLabel}"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource BgControl}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderClr}"/>
            <Setter Property="CaretBrush" Value="{DynamicResource FgText}"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource FgText}"/>
        </Style>
    </Window.Resources>
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Label Content="Profile name:" Width="130"/>
            <TextBox x:Name="txtName" Width="290" Height="24"/>
        </StackPanel>

        <GroupBox Grid.Row="1" Header="Mode" Padding="6">
            <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="rbDhcp" Content="DHCP" Margin="0,0,20,0" IsChecked="True"/>
                <RadioButton x:Name="rbStatic" Content="Static"/>
            </StackPanel>
        </GroupBox>

        <GroupBox Grid.Row="2" Header="Static configuration" Padding="6" x:Name="gbStatic">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                    <RowDefinition/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Label Grid.Row="0" Grid.Column="0" Content="IP address:"/>
                <TextBox Grid.Row="0" Grid.Column="1" x:Name="txtIP" Height="24"/>

                <Label Grid.Row="1" Grid.Column="0" Content="Mask / prefix:"/>
                <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtMask" Height="24" ToolTip="Enter mask (255.255.255.0) OR prefix (24)"/>

                <Label Grid.Row="2" Grid.Column="0" Content="Gateway:"/>
                <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtGw" Height="24"/>

                <Label Grid.Row="3" Grid.Column="0" Content="DNS 1:"/>
                <TextBox Grid.Row="3" Grid.Column="1" x:Name="txtDns1" Height="24"/>

                <Label Grid.Row="4" Grid.Column="0" Content="DNS 2:"/>
                <TextBox Grid.Row="4" Grid.Column="1" x:Name="txtDns2" Height="24"/>
            </Grid>
        </GroupBox>

        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="btnOK" Content="OK" IsDefault="True" Width="90" Margin="3"/>
            <Button x:Name="btnCancel" Content="Cancel" IsCancel="True" Width="90" Margin="3"/>
        </StackPanel>
    </Grid>
</Window>
'@

# ============================================================
#   LOAD WINDOW
# ============================================================
$reader = New-Object System.Xml.XmlNodeReader $XAML
$window = [Windows.Markup.XamlReader]::Load($reader)

# Bind controls
$controls = @{}
$XAML.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) {
        $controls[$name] = $window.FindName($name)
    }
}

# ============================================================
#   GUI LOGIC
# ============================================================
$Script:Profiles = @(Load-Profiles)

function Refresh-Adapters {
    $controls.cbAdapter.Items.Clear()
    $adapters = Get-AdapterList
    $matchIndex = -1
    $i = 0
    foreach ($a in $adapters) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $a.Display
        $item.Tag = $a
        [void]$controls.cbAdapter.Items.Add($item)
        if ($Script:Settings.LastAdapter -and $a.Name -eq $Script:Settings.LastAdapter) {
            $matchIndex = $i
        }
        $i++
    }
    if ($controls.cbAdapter.Items.Count -gt 0) {
        if ($matchIndex -ge 0) {
            $controls.cbAdapter.SelectedIndex = $matchIndex
        } else {
            $controls.cbAdapter.SelectedIndex = 0
        }
    }
}

function Refresh-CurrentConfig {
    $sel = $controls.cbAdapter.SelectedItem
    if (-not $sel) { return }
    $adapterName = $sel.Tag.Name
    $cfg = Get-AdapterConfig -Name $adapterName
    if (-not $cfg) { return }

    $controls.tbStatus.Text = $cfg.Status
    $controls.tbDhcp.Text   = $cfg.DHCP
    $controls.tbIP.Text     = $cfg.IPAddress
    $controls.tbMask.Text   = $cfg.SubnetMask
    $controls.tbPrefix.Text = "$($cfg.PrefixLength)"
    $controls.tbGw.Text     = $cfg.Gateway
    $controls.tbDns.Text    = $cfg.AllDNS
    $controls.tbMac.Text    = $cfg.MAC
    $controls.tbSpeed.Text  = $cfg.LinkSpeed
}

function Refresh-ProfilesList {
    $controls.lbProfiles.Items.Clear()
    foreach ($p in $Script:Profiles) {
        $desc = if ($p.UseDHCP) { 'DHCP' } else { "$($p.IPAddress)/$($p.PrefixLength)  GW: $($p.Gateway)  DNS: $($p.DNS1) $($p.DNS2)" }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = "$($p.Name)  --  $desc"
        $item.Tag = $p
        [void]$controls.lbProfiles.Items.Add($item)
    }
}

function Show-ProfileEditor {
    param([PSCustomObject]$InitialProfile)

    $r = New-Object System.Xml.XmlNodeReader $XAML_EDIT
    $editWin = [Windows.Markup.XamlReader]::Load($r)
    $editWin.Owner = $window
    # Apply current theme to the edit window as well
    Apply-Theme -TargetWindow $editWin -Theme $Script:Settings.Theme

    $ec = @{}
    $XAML_EDIT.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
        $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($n) { $ec[$n] = $editWin.FindName($n) }
    }

    if ($InitialProfile) {
        $ec.txtName.Text = $InitialProfile.Name
        if ($InitialProfile.UseDHCP) {
            $ec.rbDhcp.IsChecked = $true
        } else {
            $ec.rbStatic.IsChecked = $true
        }
        $ec.txtIP.Text   = $InitialProfile.IPAddress
        $ec.txtMask.Text = if ($InitialProfile.PrefixLength) { Convert-PrefixToMask $InitialProfile.PrefixLength } else { '' }
        $ec.txtGw.Text   = $InitialProfile.Gateway
        $ec.txtDns1.Text = $InitialProfile.DNS1
        $ec.txtDns2.Text = $InitialProfile.DNS2
    }

    $updateStaticState = {
        $enabled = $ec.rbStatic.IsChecked
        $ec.gbStatic.IsEnabled = $enabled
    }
    $ec.rbDhcp.Add_Checked($updateStaticState)
    $ec.rbStatic.Add_Checked($updateStaticState)
    & $updateStaticState

    $Script:EditResult = $null

    $ec.btnOK.Add_Click({
        $name = $ec.txtName.Text.Trim()
        if (-not $name) {
            [System.Windows.MessageBox]::Show('Enter a profile name.', 'Error', 'OK', 'Warning') | Out-Null
            return
        }
        $useDhcp = [bool]$ec.rbDhcp.IsChecked

        $ip = $ec.txtIP.Text.Trim()
        $maskRaw = $ec.txtMask.Text.Trim()
        $gw = $ec.txtGw.Text.Trim()
        $dns1 = $ec.txtDns1.Text.Trim()
        $dns2 = $ec.txtDns2.Text.Trim()
        $prefix = $null

        if (-not $useDhcp) {
            if (-not (Test-IPv4 $ip)) {
                [System.Windows.MessageBox]::Show('Invalid IP address.', 'Error', 'OK', 'Warning') | Out-Null
                return
            }
            if ($maskRaw -match '^\d+$') {
                $prefix = [int]$maskRaw
                if ($prefix -lt 0 -or $prefix -gt 32) {
                    [System.Windows.MessageBox]::Show('Prefix must be 0-32.', 'Error', 'OK', 'Warning') | Out-Null
                    return
                }
            } else {
                $prefix = Convert-MaskToPrefix $maskRaw
                if ($null -eq $prefix) {
                    [System.Windows.MessageBox]::Show('Invalid subnet mask.', 'Error', 'OK', 'Warning') | Out-Null
                    return
                }
            }
            if ($gw -and -not (Test-IPv4 $gw)) {
                [System.Windows.MessageBox]::Show('Invalid gateway.', 'Error', 'OK', 'Warning') | Out-Null
                return
            }
            if ($dns1 -and -not (Test-IPv4 $dns1)) {
                [System.Windows.MessageBox]::Show('Invalid DNS1.', 'Error', 'OK', 'Warning') | Out-Null
                return
            }
            if ($dns2 -and -not (Test-IPv4 $dns2)) {
                [System.Windows.MessageBox]::Show('Invalid DNS2.', 'Error', 'OK', 'Warning') | Out-Null
                return
            }
        }

        $Script:EditResult = [PSCustomObject]@{
            Name         = $name
            UseDHCP      = $useDhcp
            IPAddress    = if ($useDhcp) { '' } else { $ip }
            PrefixLength = if ($useDhcp) { $null } else { $prefix }
            Gateway      = if ($useDhcp) { '' } else { $gw }
            DNS1         = if ($useDhcp) { '' } else { $dns1 }
            DNS2         = if ($useDhcp) { '' } else { $dns2 }
        }
        $editWin.DialogResult = $true
        $editWin.Close()
    })

    $ec.btnCancel.Add_Click({
        $editWin.DialogResult = $false
        $editWin.Close()
    })

    $ok = $editWin.ShowDialog()
    if ($ok) { return $Script:EditResult } else { return $null }
}

# ============================================================
#   EVENT HANDLERS
# ============================================================
$controls.btnRefresh.Add_Click({
    Refresh-Adapters
    Refresh-CurrentConfig
    $controls.tbStatusBar.Text = "Refreshed adapter list. ($(Get-Date -Format HH:mm:ss))"
})

$controls.cbAdapter.Add_SelectionChanged({
    Refresh-CurrentConfig
    $sel = $controls.cbAdapter.SelectedItem
    if ($sel -and $sel.Tag) {
        if ($Script:Settings.LastAdapter -ne $sel.Tag.Name) {
            $Script:Settings.LastAdapter = $sel.Tag.Name
            Save-Settings -Settings $Script:Settings
        }
    }
})

$controls.btnApply.Add_Click({
    $selP = $controls.lbProfiles.SelectedItem
    $selA = $controls.cbAdapter.SelectedItem
    if (-not $selP) {
        [System.Windows.MessageBox]::Show('Select a profile.', 'Info', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $selA) {
        [System.Windows.MessageBox]::Show('Select a network adapter.', 'Info', 'OK', 'Information') | Out-Null
        return
    }
    $profile = $selP.Tag
    $adapterName = $selA.Tag.Name
    $confirm = [System.Windows.MessageBox]::Show("Apply profile '$($profile.Name)' to adapter '$adapterName'?", 'Confirmation', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    try {
        $controls.tbStatusBar.Text = "Applying profile $($profile.Name)..."
        Apply-Profile -Profile $profile -AdapterName $adapterName
        Start-Sleep -Milliseconds 800
        Refresh-CurrentConfig
        $controls.tbStatusBar.Text = "OK. Applied '$($profile.Name)' at $(Get-Date -Format HH:mm:ss)."
    } catch {
        Write-Log "Error applying profile: $_" 'ERROR'
        [System.Windows.MessageBox]::Show("Error: $_`n`nMake sure the script runs with administrator privileges.", 'Error', 'OK', 'Error') | Out-Null
        $controls.tbStatusBar.Text = "Error applying profile."
    }
})

$controls.btnNew.Add_Click({
    $p = Show-ProfileEditor -InitialProfile $null
    if ($p) {
        if ($Script:Profiles | Where-Object { $_.Name -eq $p.Name }) {
            [System.Windows.MessageBox]::Show("A profile named '$($p.Name)' already exists.", 'Error', 'OK', 'Warning') | Out-Null
            return
        }
        $Script:Profiles = @($Script:Profiles) + $p
        Save-Profiles -Profiles $Script:Profiles
        Refresh-ProfilesList
        $controls.tbStatusBar.Text = "Added profile '$($p.Name)'."
    }
})

$controls.btnEdit.Add_Click({
    $sel = $controls.lbProfiles.SelectedItem
    if (-not $sel) { return }
    $orig = $sel.Tag
    $p = Show-ProfileEditor -InitialProfile $orig
    if ($p) {
        $Script:Profiles = @($Script:Profiles | Where-Object { $_.Name -ne $orig.Name })
        if ($Script:Profiles | Where-Object { $_.Name -eq $p.Name }) {
            [System.Windows.MessageBox]::Show("A profile named '$($p.Name)' already exists.", 'Error', 'OK', 'Warning') | Out-Null
            return
        }
        $Script:Profiles = @($Script:Profiles) + $p
        Save-Profiles -Profiles $Script:Profiles
        Refresh-ProfilesList
        $controls.tbStatusBar.Text = "Updated '$($p.Name)'."
    }
})

$controls.btnClone.Add_Click({
    $sel = $controls.lbProfiles.SelectedItem
    if (-not $sel) { return }
    $orig = $sel.Tag
    $clone = $orig.PSObject.Copy()
    $clone.Name = "$($orig.Name) (copy)"
    $p = Show-ProfileEditor -InitialProfile $clone
    if ($p) {
        if ($Script:Profiles | Where-Object { $_.Name -eq $p.Name }) {
            [System.Windows.MessageBox]::Show("A profile named '$($p.Name)' already exists.", 'Error', 'OK', 'Warning') | Out-Null
            return
        }
        $Script:Profiles = @($Script:Profiles) + $p
        Save-Profiles -Profiles $Script:Profiles
        Refresh-ProfilesList
    }
})

$controls.btnDelete.Add_Click({
    $sel = $controls.lbProfiles.SelectedItem
    if (-not $sel) { return }
    $orig = $sel.Tag
    $ok = [System.Windows.MessageBox]::Show("Delete profile '$($orig.Name)'?", 'Confirmation', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    $Script:Profiles = @($Script:Profiles | Where-Object { $_.Name -ne $orig.Name })
    Save-Profiles -Profiles $Script:Profiles
    Refresh-ProfilesList
    $controls.tbStatusBar.Text = "Deleted '$($orig.Name)'."
})

$controls.btnFromCurrent.Add_Click({
    $sel = $controls.cbAdapter.SelectedItem
    if (-not $sel) { return }
    $cfg = Get-AdapterConfig -Name $sel.Tag.Name
    if (-not $cfg) { return }
    $draft = [PSCustomObject]@{
        Name         = "New - $($cfg.Name)"
        UseDHCP      = ($cfg.DHCP -eq 'Enabled')
        IPAddress    = $cfg.IPAddress
        PrefixLength = $cfg.PrefixLength
        Gateway      = if ($cfg.Gateway -eq '(none)') { '' } else { $cfg.Gateway }
        DNS1         = $cfg.DNS1
        DNS2         = $cfg.DNS2
    }
    $p = Show-ProfileEditor -InitialProfile $draft
    if ($p) {
        if ($Script:Profiles | Where-Object { $_.Name -eq $p.Name }) {
            [System.Windows.MessageBox]::Show("A profile named '$($p.Name)' already exists.", 'Error', 'OK', 'Warning') | Out-Null
            return
        }
        $Script:Profiles = @($Script:Profiles) + $p
        Save-Profiles -Profiles $Script:Profiles
        Refresh-ProfilesList
        $controls.tbStatusBar.Text = "Created profile from current configuration."
    }
})

$controls.btnImport.Add_Click({
    Import-ProfilesFromFile
})

$controls.btnExport.Add_Click({
    Export-ProfilesToFile
})

$controls.btnTheme.Add_Click({
    $newTheme = if ($Script:Settings.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
    $Script:Settings.Theme = $newTheme
    Apply-Theme -TargetWindow $window -Theme $newTheme
    $controls.btnTheme.Content = "Theme: " + $(if ($newTheme -eq 'Dark') { 'dark' } else { 'light' })
    Save-Settings -Settings $Script:Settings
    Write-Log "Theme changed to: $newTheme"
})

# ============================================================
#   START
# ============================================================

# Single-instance guard (per-session, per-user)
$Script:MutexName = "Local\NetSetPS_$env:USERNAME"
$Script:AppMutexCreated = $false
$Script:AppMutex = New-Object System.Threading.Mutex($true, $Script:MutexName, [ref]$Script:AppMutexCreated)
if (-not $Script:AppMutexCreated) {
    [System.Windows.MessageBox]::Show(
        'NetSetPS is already running. Check the system tray.',
        'Already running', 'OK', 'Information') | Out-Null
    Write-Log 'Second instance blocked by mutex.' 'WARN'
    exit
}

# Load settings and apply theme BEFORE showing the window
Measure-Step 'Load-Settings'       { $Script:Settings = Load-Settings }
Measure-Step 'Apply-Theme'         { Apply-Theme -TargetWindow $window -Theme $Script:Settings.Theme }
$controls.btnTheme.Content = "Theme: " + $(if ($Script:Settings.Theme -eq 'Dark') { 'dark' } else { 'light' })

Measure-Step 'Refresh-Adapters'      { Refresh-Adapters }
Measure-Step 'Refresh-CurrentConfig' { Refresh-CurrentConfig }
Measure-Step 'Refresh-ProfilesList'  { Refresh-ProfilesList }

# Initialize system tray (icon + context menu)
Measure-Step 'Initialize-Tray'       { Initialize-Tray }

# Cleanup handler - fires on X, on Close(), on Exit from tray menu
$window.Add_Closing({
    param($sender, $e)
    Write-Log 'Application closing.'
    if ($Script:NotifyIcon) {
        $Script:NotifyIcon.Visible = $false
        $Script:NotifyIcon.Dispose()
        $Script:NotifyIcon = $null
    }
    if ($Script:AppMutex) {
        try { $Script:AppMutex.ReleaseMutex() } catch {}
        $Script:AppMutex.Dispose()
        $Script:AppMutex = $null
    }
    # Signal Application.Run() to return so the script can exit
    if ([System.Windows.Application]::Current) {
        [System.Windows.Application]::Current.Shutdown()
    }
})

# Check privileges - NetSetPS works with either full Administrator rights OR
# membership in "Network Configuration Operators" (SID S-1-5-32-556). NetConfigOps
# is enough because Apply-Profile uses netsh, which respects this group.
$currentIdent   = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal $currentIdent
$isAdmin        = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$netConfigSid   = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-556'
$isNetConfigOps = $currentPrincipal.IsInRole($netConfigSid)

if (-not ($isAdmin -or $isNetConfigOps)) {
    $controls.tbStatusBar.Text = "WARNING: user not in Administrators or Network Configuration Operators. Applying profiles will fail."
    $window.Title = "NetSetPS  [INSUFFICIENT PRIVILEGES]"
    Write-Log "User has neither Administrators nor NetConfigOps privileges" 'WARN'
} else {
    $role = if ($isAdmin) { 'Administrator' } else { 'NetConfigOps' }
    Write-Log "Running with $role privileges"
}

# Create WPF Application object if none exists yet (needed for Show()+Run() pattern).
# ShowDialog would auto-create one, but Show() alone does not.
if (-not [System.Windows.Application]::Current) {
    New-Object System.Windows.Application | Out-Null
}
# Explicit shutdown: Application.Run() keeps pumping until we call Shutdown() ourselves.
# Otherwise the default (OnLastWindowClose) would kill the app when window is hidden.
[System.Windows.Application]::Current.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

if ($StartMinimized) {
    Write-Log 'Started minimized to tray (window not shown).'
    # Deliberately do NOT call Show() - tray-only mode. Window stays hidden
    # until user picks 'Show window' from tray menu.
} else {
    $window.Show()
}

# Enter the WPF message loop. Returns when Application.Current.Shutdown() is
# called from the Closing handler above.
[System.Windows.Application]::Current.Run() | Out-Null
Write-Log "Application closed."
