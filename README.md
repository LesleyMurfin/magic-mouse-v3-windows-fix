# Magic Mouse 2024 (v3) Windows Driver — Scroll Fix for PID 0323

A free, MIT-licensed **Magic Mouse v3 Windows driver** for the USB-C **Apple Magic Mouse 2024** (Bluetooth **PID 0323**) on **Windows 10/11**. Apple ships no Windows driver for PID `0x0323` and its Boot Camp INF has no `0323` entry, so two-finger scroll dies after a Bluetooth idle disconnect while the cursor keeps working. This project restores and protects scroll by keeping the HID collection stack from collapsing. Not v1 (`030D`) or v2 (`0269`).

**Read the guides:**
[Magic Mouse v3 Windows driver site](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/) ·
[Install the driver on Windows 11](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/install.html) ·
[Fix Magic Mouse scroll not working](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/scroll-fix.html) ·
[Magic Mouse battery percentage on Windows](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/battery.html) ·
[Magic Mouse v3 driver FAQ](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/faq.html)

**Battery percentage:** use [Magic Tray (Windows app)](https://github.com/LesleyMurfin/magic-tray) — a Windows system-tray utility (software, not a physical desk tray) that reads HID Input `0x90` COL02 and installs the KMDF package from this repo. Site: [Magic Tray (Windows app) home](https://magictray.app/).

**STATUS:** KMDF is what Magic Tray recommends. The v1 patched `applewirelessmouse.sys` is documented below as research; Magic Tray will not use it as a KMDF fallback.

If this helped, **star this repo** and **[Magic Tray](https://github.com/LesleyMurfin/magic-tray)**. Signing goal (Stripe, not GitHub Sponsors): [funding](https://magictray.app/funding.html).

## Contents

- [What this fixes](#what-this-fixes)
- [Supported hardware](#supported-hardware)
- [Quick install](#quick-install-3-steps)
- [How it works](#how-it-works)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)


A Windows kernel path that restores scroll on Magic Mouse v3 after Bluetooth reconnection.

## What This Fixes

Apple Magic Mouse v3 on Windows 10/11 loses scroll capability after Bluetooth idle disconnect followed by DeviceSetupManager property synchronization. This patch significantly reduces occurrence of that loss (and may prevent it) by protecting the HID collection structure during DSM initialization. v1.0 empirical results show a 3.1× improvement over the unpatched baseline; long-term (multi-day) prevention is not yet characterized. The v2 KMDF rewrite targets full prevention.

**Affected hardware:**
- Apple Magic Mouse v3 (2024), Bluetooth PID 0x0323
- Windows 10 build 14393 or later / Windows 11 any build

> **Have a Magic Mouse v1 or v2?** This repo is v3-only. For v1/v2 scroll fix on Windows, see [`sbagirici/apple-magic-mouse-scroll-fix-windows`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) — the project this work builds on.

**Symptoms before patch:**
- Scroll wheel works immediately after pairing
- After ~15–30 min idle + Bluetooth disconnect, scroll stops responding
- Cursor movement continues normally
- Issue does not self-recover; requires driver reinstall or device repair

## Supported Hardware

| Model | Year | Bluetooth PID | Supported? |
|-------|------|---------------|------------|
| Magic Mouse v1 | 2009 | `0x030D` | ✅ This repo (Apple-driver route) |
| Magic Mouse v2 | 2015 | `0x0269` | ✅ This repo (Apple-driver route) |
| Magic Mouse v2 (alt PID) | 2015 | `0x0310` | ✅ This repo (Apple-driver route) |
| Magic Mouse v3 | 2024 | `0x0323` | ✅ This repo (Apple-driver route) |

**Verify your PID:** Device Manager → Human Interface Devices → Apple Magic Mouse → Properties → Details → Hardware Ids. Look for `PID&030D`, `PID&0269`, `PID&0310`, or `PID&0323`.

## System Requirements

- Windows 10 build 14393 or later, or Windows 11 any version, x64
- A Magic Mouse paired over Bluetooth: `0x030D`, `0x0269`, `0x0310` or `0x0323`
- Administrator account for installation
- Fast Startup off (`powercfg /h off`, then reboot) — the installer refuses to run otherwise
- Reboot access

## Quick Install

### Step 1: Download & verify

Download the repository or a release ZIP and extract it, then verify the driver you are about
to install from the extracted `v1-binary-patch/` folder:

```powershell
$sys = ".\apple-driver\applewirelessmouse.sys"
(Get-FileHash $sys -Algorithm SHA256).Hash
# Expected: 08F33D7E3ECE2C73950A9706F1C4C9057894EAEAF1C4FB355F261F3C2333378F   (78,424 bytes)

# This is Apple's own driver, unmodified. Confirm Windows agrees:
(Get-AuthenticodeSignature $sys).Status
# Valid
(Get-AuthenticodeSignature $sys).SignerCertificate.Subject
# CN=Microsoft Windows Hardware Compatibility Publisher, ...
```

`installer\SHA256SUMS.txt` carries the same checksum in `sha256sum -c` format.

### Step 2: Run the installer

Double-click `v1-binary-patch\Install.cmd`. It requests Administrator itself, so there is
nothing to type and no execution-policy change.

The same thing explicitly, if you prefer a shell:

```powershell
# Elevated PowerShell
cd .\v1-binary-patch\installer
.\Install-MagicMousePatch.ps1 -DriverPath ..\apple-driver\applewirelessmouse.sys

# Other options: -FromDriverStore, -TargetPid <030D|0310|0269|0323>, -DryRun
```

No certificate prompt: the shipped binary is Apple's own, countersigned by Microsoft, so
nothing has to be added to a trust store. The legacy byte-patched variant did require a
certificate and Test Mode; it is no longer shipped.

### Step 3: Reboot

```powershell
# Follow on-screen instructions, or manually:
shutdown /r /t 60 /c "MagicMousePatch installer - rebooting"
```

## What Changes on Your System

| Item | Change |
|------|--------|
| Certificate | None for the shipped Apple-driver route. The legacy patched variant imported MagicMouseFix to `LocalMachine\TrustedPublisher` only — never the Root store |
| Driver file | `C:\Windows\System32\drivers\applewirelessmouse.sys` (78,424 bytes, Apple's, unmodified) |
| Service | applewirelessmouse service created, demand-start (Type 1, Start 3) |
| Registry | HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\...\Device Parameters\LowerFilters |
| Backup | Original driver backed up to C:\ProgramData\MagicMousePatch\backup\ |

The driver is registered as a WDM lower filter on the Bluetooth HID stack, so it initialises the
device before the HID collection structures can collapse. Nothing Apple shipped is modified — the
fix is the registration, which Windows does not perform on a non-Mac PC.

## Verify It Worked

After reboot:

```powershell
# Check driver is loaded
Get-PnpDevice -Class Mouse | Where-Object {$_.Name -match "Apple"}

# Check service is running
sc query applewirelessmouse
# Should show STATE        : 4 RUNNING

# Event log confirmation (optional)
Get-WinEvent -LogName "Microsoft-Windows-Kernel-PnP/Configuration" -MaxEvents 20 `
  | Where-Object {$_.Message -match "applewirelessmouse"}
```

Test scroll functionality:
1. Open any application with scrollable content
2. Move mouse over content and scroll
3. Disconnect Magic Mouse (turn off), wait 2 minutes, turn back on
4. Verify scroll still works

## Uninstall

```powershell
# Open PowerShell as Administrator
cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
.\Uninstall-MagicMousePatch.ps1

# Follow prompts; reboot when complete
```

Uninstall restores the original driver and removes all Windows registry entries and certificates.

## How It Works

### The Problem: Mode A → Mode B Collapse

After ~15–30 min idle, Windows DeviceSetupManager writes 35 property descriptors to the
Magic Mouse device container. BTHPORT rewrites its internal service cache, collapsing the
dual HID collection structure:

```
MODE A (working)                      MODE B (broken — after DSM trigger)
────────────────────────────────      ────────────────────────────────────
  Magic Mouse v3 (BT paired)            Magic Mouse v3 (BT paired)
    |                                     |
    +-- COL01  <-- scroll + cursor        +-- TLC (unified)  <-- scroll LOST
    |   (HID\VID_004C&PID_0323&COL01)         cursor still works
    |
    +-- COL02  <-- battery / diag
        (HID\VID_004C&PID_0323&COL02)

  DynamicCachedServices:                DynamicCachedServices:
    Entry 0: COL01  0x00110000            Entry 0: TLC    0x00110000
    Entry 1: COL02  0x00020000            Entry 1: empty  0x00000000
                                          (COL02 gone)
```

Mode B is **permanent** — device reconnect, sleep/wake, and restart do not recover it.
Only fix without this patch: unpair and repair the device.

### The Fix: WDM Lower Filter Driver

`applewirelessmouse.sys` is inserted as a lower filter in the Bluetooth HID stack,
intercepting initialization before the collapse can take hold:

```
  Application (scroll events)
       |
  Windows Input Manager
       |
  hidclass.sys          (HID Class Driver)
       |
  HidBth.sys            (Bluetooth HID miniport)
       |
  applewirelessmouse.sys  <-- LOWER FILTER (this patch)
       |                     intercepts DSM descriptor rewrite
  BTHENUM PDO           (Magic Mouse device node)
       |
  BTHPORT.SYS           (Bluetooth port driver)
       |
  Magic Mouse v3 hardware
```

Registered via:
```
HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\
  {00001124-...}_VID&0001004C_PID&0323\...\
    LowerFilters  REG_MULTI_SZ  "applewirelessmouse"
```

**Test evidence:**
- Test 1 (power off/on): scroll persists — PASS
- Test 2 (idle + DSM replay): held Mode A for 69 min vs historical 22 min before flip — PASS
- Test 3 (pnputil rescan): scroll stable — PASS
- Test 4 (sleep/wake): cache byte-identical, scroll works — PASS
- Test 6 (UsoClient force-DSM): scroll preserved — PASS
- Phase 5 (cold reboot): DSM ran twice post-boot, scroll still working — PASS

## Roadmap

**v1.0.0 (current):** Binary patch of Apple firmware via WDM lower filter.
- Patched applewirelessmouse.sys (66 KB)
- PowerShell installer + uninstaller
- Registry-based LowerFilters registration
- Requires certificate trust

**v2.0.0 (in progress):** KMDF filter driver rewrite.
- From-scratch WDF source code
- No Apple binary dependency
- Cleaner driver signing process
- Better Windows Defender SmartScreen integration
- Windows 11 22H2+ target

See `/v2-kmdf-driver/README.md` for v2 status.

## Contributing

### Reporting Issues

File issues at [GitHub Issues](https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix/issues).

**Required information:**
- Windows version and build (run `winver`)
- Magic Mouse hardware version and PID (Device Manager → Human Interface Devices → Apple Magic Mouse → Details → Hardware Ids)
- Steps to reproduce
- Output from Event Viewer:
  - Microsoft-Windows-Kernel-PnP/Configuration (last 50 events)
  - Microsoft-Windows-DeviceSetupManager/Admin (last 50 events)

Export logs:

```powershell
wevtutil epl "Microsoft-Windows-Kernel-PnP/Configuration" C:\pnp-config.evtx
wevtutil epl "Microsoft-Windows-DeviceSetupManager/Admin" C:\dsm-admin.evtx
# Attach .evtx files to issue
```

### Testing Patches

1. Clone this repository
2. Install the patched version per Quick Install
3. Run idle + reconnect test (69+ min)
4. Document results in a test comment with exact Windows version and hardware revision

### Pull Requests

- All commits to feature branches
- PR must include test evidence from your hardware
- Link to related issue
- All .ps1 scripts must pass PSScriptAnalyzer (via GitHub Actions)

## Attribution

Big thanks to [`sbagirici`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) for the original patched `applewirelessmouse.sys` binary and the LowerFilter installation approach that this project builds on. Without that starting point, the v3 investigation would have taken significantly longer.

**v1 / v2 users:** sbagirici's repo is the right place for you — go give it a star.

Our additions on top of that baseline (v3-specific):
- Full root cause analysis of the H-011 / DSM trigger bug (COL01/COL02 Mode A/B collapse mechanism)
- Test battery (Tests 1–6 + Phase 5) quantifying a 3.1× improvement factor
- Rewritten PowerShell installer/uninstaller with correct LowerFilters path, REG_MULTI_SZ type, and two-level BTHENUM enumeration
- SHA256 verification, DMCA notice, HID descriptor research, and release packaging

## License

MIT License — Copyright 2026 Revive Business Solutions.

See `LICENSE` file for full text.

## Support

Questions? Contact: riley@revivebusiness.ca

For security issues, see `SECURITY.md`.
