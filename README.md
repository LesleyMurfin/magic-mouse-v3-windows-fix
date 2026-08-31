# Magic Mouse v3 Windows Scroll Fix

**0323 product: KMDF `MagicMouseDriver` in `v2-kmdf-driver/`.**  
Double-click `v2-kmdf-driver/Install-KMDF.cmd`. First run: one Administrator prompt (registers a SYSTEM task). Later runs: no UAC. Result: `C:\ProgramData\MagicMouseDriver\RESULT.txt`.

`magic-tray` should install **this** KMDF for PID 0323 (do not vendor the tree into the tray repo).

The v1 `applewirelessmouse.sys` binary patch is a **ship-blocker** (BSOD 0xD1). Do not install it for 0323. Do not dual-filter it with MagicMouseDriver.

---

A Windows KMDF lower filter that presents a standard mouse to hidclass and translates Magic Mouse 2 USB-C (PID 0x0323) RID 0x12 reports so the pointer moves. Also addresses the v3 scroll-stop / DSM collection collapse the v1 patch was aimed at.

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
| Magic Mouse v1 | 2009 | `0x030D` | ❌ Not supported — see [sbagirici's repo](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) |
| Magic Mouse v2 | 2015 | `0x0269` | ❌ Not supported — see [sbagirici's repo](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) |
| Magic Mouse v3 | 2024 | `0x0323` | ✅ This repo |

**Verify your PID:** Device Manager → Human Interface Devices → Apple Magic Mouse → Properties → Details → Hardware Ids. Look for `PID&030D`, `PID&0269`, or `PID&0323`.

## System Requirements

- Windows 10 build 14393 or later, or Windows 11 any version
- Apple Magic Mouse v3 (PID `0x0323`) paired over Bluetooth
- Administrator account for installation
- Reboot access

## Quick Install (one click)

1. Clone this repository on Windows.
2. Double-click `v2-kmdf-driver\Install-KMDF.cmd`.
3. Accept Administrator **once**. After that the SYSTEM task `MM-Kmdf-Install` runs unattended (sign, install, bind 0323 only, Bluetooth bounce, reboot if needed, post-boot test).

Details and HVCI / test-signing notes: [`v2-kmdf-driver/README.md`](v2-kmdf-driver/README.md).

## Legacy v1 binary patch (do not ship)

The steps below install the old patched `applewirelessmouse.sys`. **Do not use this for 0323.** It is kept only as history.

### Step 1: Download & Verify (v1 only — ship-blocker)

```powershell
# Download v1.0.0 release
# Extract to C:\Program Files\MagicMousePatch\

# Verify binary integrity (mandatory)
$sys = "C:\Program Files\MagicMousePatch\v1-binary-patch\applewirelessmouse.sys"
(Get-FileHash $sys -Algorithm SHA256).Hash
# Expected: 370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03
```

### Step 2: Run Installer

```powershell
# Open PowerShell as Administrator
cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
.\Install-MagicMousePatch.ps1

# Accept certificate trust prompt when prompted
```

### Step 3: Reboot

```powershell
# Follow on-screen instructions, or manually:
shutdown /r /t 60 /c "MagicMousePatch installer - rebooting"
```

## What Changes on Your System

| Item | Change |
|------|--------|
| Certificate | MagicMouseFix cert imported to LocalMachine\TrustedPublisher and Root store |
| Driver file | C:\Windows\System32\drivers\applewirelessmouse.sys (66 KB) |
| Service | applewirelessmouse service created, demand-start (Type 1, Start 3) |
| Registry | HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\...\Device Parameters\LowerFilters |
| Backup | Original driver backed up to C:\ProgramData\MagicMousePatch\backup\ |

The patch acts as a WDM lower filter on the Bluetooth HID stack, intercepting device initialization before HID collection structures can collapse.

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

**v2.0.3 (this tree):** KMDF `MagicMouseDriver` for 0323 only — INF, vcxproj, source, and one-click SYSTEM-task installer. See `/v2-kmdf-driver/README.md`.

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
