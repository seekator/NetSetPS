# NetSetPS

A PowerShell + WPF replacement for [NetSetMan](https://www.netsetman.com/). Manages network profiles (IP / mask / gateway / DNS, DHCP) per adapter. Windows 10/11, Server 2016+. Built-in PowerShell 5.1. No external modules.

## Install workflow

Three build steps and one install step, run in order **as administrator** from Windows PowerShell 5.1 (not PowerShell 7 — see note below):

```powershell
.\Build-Native.ps1     # 1. Compile NetSetPS.Native.dll
.\Sign.ps1             # 2. Create self-signed cert, install to Trusted Root, sign all files
.\Install.ps1          # 3. Copy files to Program Files, create shortcuts
```

Then log in as your daily user, double-click **NetSetPS** on the public desktop, accept the UAC prompt.

### PowerShell 7 caveat

PowerShell 7.6.x has a bug where the `Microsoft.PowerShell.Security` module fails to load, which breaks `Get-AuthenticodeSignature` and `Set-AuthenticodeSignature`. Run the install sequence from **Windows PowerShell 5.1** (`powershell.exe`, the classic blue console). The installed app itself runs fine with the PowerShell hosted by the shortcut.

## Architecture — why three build steps

### Build-Native.ps1

Compiles `NetSetPS.Native.dll` from inline C# P/Invoke wrappers (`ExtractIconEx`, `DestroyIcon`, `SetForegroundWindow`, `GetConsoleWindow`, `ShowWindow`). This DLL is loaded at runtime instead of `Add-Type` compiling C# on every launch.

Behavioral AV engines (Bitdefender Advanced Threat Defense, Kaspersky System Watcher, Windows Defender ML) fingerprint runtime C# compilation — the child processes `csc.exe` and `cvtres.exe` — as fileless malware indicators. Pre-building removes them.

### Sign.ps1

Creates a self-signed code-signing certificate (`CN=NetSetPS Self-Signed`), installs it to `Cert:\CurrentUser\Root`, and signs `NetSetPS.ps1`, `NetSetPS.Native.dll`, and every other .ps1 in the repo.

Windows shows a security dialog on first Trusted Root install — click **Yes**. The shortcut uses `-ExecutionPolicy AllSigned` which requires a valid signature; unsigned files won't run.

Signatures are invalidated by any edit. Re-run `Sign.ps1` after modifying signed files.

### Install.ps1

- Cleans leftover state from previous install variants (scheduled tasks, NetConfigOps group memberships, `LocalAccountTokenFilterPolicy` registry value)
- Verifies `NetSetPS.ps1` is signed (survives PS 7.6 breakage gracefully)
- Copies `NetSetPS.ps1` and `NetSetPS.Native.dll` to `C:\Program Files\NetSetPS\`
- Creates public desktop + start menu shortcuts with `-ExecutionPolicy AllSigned -WindowStyle Minimized -NoLogo -File ...` and the RunAs flag set (byte 21, bit 0x20 of the .lnk)

## How the app launches

1. Double-click **NetSetPS** on the public desktop
2. UAC prompt appears — enter admin credentials
3. PowerShell console briefly flashes in the taskbar (Minimized)
4. The script loads `NetSetPS.Native.dll` and calls `ShowWindow(GetConsoleWindow(), SW_HIDE)` — console disappears
5. WPF window loads, tray icon appears

Closing the window (X) or `Exit` from the tray menu ends the process. Next launch requires another UAC prompt (nothing cached).

`-WindowStyle Minimized` is used instead of `-Hidden` because `-Hidden` in the command line is a strong fingerprint that behavioral AV associates with fileless malware. The script hides its own console from the inside, which AV does not observe as a command-line pattern.

## Performance

Cold start is 3-8 seconds depending on Bitdefender's realtime scan of the elevated PowerShell process. Warm start after that is faster.

The script writes `[PERF]` entries to `%ProgramData%\NetSetPS\netsetps.log` timing each initialization step. If startup feels slow, tail the log and look for the outlier:

```powershell
Get-Content 'C:\ProgramData\NetSetPS\netsetps.log' -Tail 25
```

`Test-AutostartEnabled` (used to draw the checkbox on the tray menu's "Start with Windows" item) caches its result for 60 seconds. Without the cache, opening the tray menu triggered a 3-second CIM call to Task Scheduler every time.

## AV behavior

With the DLL + signature + `AllSigned` combo, Bitdefender Advanced Threat Defense is usually quiet. If it still flags on launch:

1. Bitdefender **Protection** → **Advanced Threat Defense** → **Settings** → **Manage Exceptions**
2. Add these paths:
   - `C:\Program Files\NetSetPS\NetSetPS.ps1`
   - `C:\Program Files\NetSetPS\NetSetPS.Native.dll`
   - `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` (with command line pattern `*NetSetPS.ps1*` if your BD version supports argument filtering)

Exceptions in the regular AV scanner don't cover the behavioral engine — you need to add them under **Advanced Threat Defense** specifically.

## Uninstall

```powershell
.\Uninstall.ps1                                                # standard
.\Uninstall.ps1 -KeepProfiles                                  # keep JSON profiles + log
.\Uninstall.ps1 -Force                                         # kill running instance then remove
.\Uninstall.ps1 -RevokeFromUser 'Danie' -RemoveTokenPolicy     # also revert legacy config
```

Uninstall aborts safely if the app is running — you get a clear message instead of silent failure.

## Editing the code

After any edit of `NetSetPS.ps1` (or any signed file):

1. `.\Sign.ps1` — re-sign, because content change invalidated the signature
2. `.\Install.ps1` — copy the new files to Program Files (make sure the running app is closed first)

## Layout

```
Repo:
  NetSetPS.ps1           # main application (WPF GUI + tray)
  NetSetPS.Native.dll    # native P/Invoke wrappers (built by Build-Native.ps1)
  Build-Native.ps1       # DLL builder
  Sign.ps1               # cert creator + code signer
  Install.ps1            # installer
  Uninstall.ps1          # uninstaller
  README.md
  LICENSE

After install:
  C:\Program Files\NetSetPS\NetSetPS.ps1
  C:\Program Files\NetSetPS\NetSetPS.Native.dll

  C:\ProgramData\NetSetPS\profiles.json     # profile database
  C:\ProgramData\NetSetPS\settings.json     # theme, last adapter
  C:\ProgramData\NetSetPS\netsetps.log      # action + [PERF] log

  C:\Users\Public\Desktop\NetSetPS.lnk      # shortcut (RunAs flag)
  C:\ProgramData\Microsoft\Windows\Start Menu\Programs\NetSetPS.lnk
```

## Profile format

```json
{
  "Name":         "Office",
  "UseDHCP":      false,
  "IPAddress":    "10.10.20.15",
  "PrefixLength": 24,
  "Gateway":      "10.10.20.1",
  "DNS1":         "10.10.20.10",
  "DNS2":         "10.10.20.11"
}
```

DHCP profiles need only `Name` and `"UseDHCP": true`.

`profiles.json` is a JSON array. Hand-editable, or deployable via GPO / Intune / DSC.

## Features

- Per-adapter profile management (IP / mask / gateway / DNS or DHCP), applied via `netsh interface ipv4` under the hood
- Live current-config panel: status, IP, subnet mask, prefix, gateway, DNS, MAC, link speed
- System tray icon with right-click menu — apply profile, switch adapter, show/hide window, autostart toggle, exit
- Active profile detection — the profile matching current NIC state is marked with `●`
- Dark mode with persistent user preference
- Import / export profiles as JSON
- Single-instance guard (per user session, mutex-based)
- Timed startup diagnostics — `[PERF]` entries in the log

## Tray menu

Right-click the tray icon:

```
NetSetPS                      (header, disabled)
─────────────────
Current adapter: Ethernet     (info, disabled)
─────────────────
Apply profile ▶ ● Office      (● = matches current NIC state)
                   Home
                   Hotel
Change adapter ▶ Ethernet [Up]
                 Wi-Fi [Disconnected]
─────────────────
Show / Hide window
─────────────────
Start with Windows            (creates NetSetPS-Autostart task)
─────────────────
Exit
```

Double-click the tray icon to bring the window back. Close the window with X or `Exit` from the menu to end the app.

## Known limitations

- IPv4 only
- Does not manage WINS or DNS suffix search list
- Self-signed cert is trusted only on the machine where it was created — users on other machines need to re-sign locally with their own cert
- "Start with Windows" autostart in UAC-per-launch mode is unreliable — the autostart task runs as the admin who was elevated at install time, not as the standard user who logs in daily

## License

MIT — see [LICENSE](LICENSE).

## Repository

<https://github.com/seekator/NetSetPS>
