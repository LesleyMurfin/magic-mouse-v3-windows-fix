# Magic Mouse v3 Windows Scroll Fix

**STATUS: Pre-release (public packaging in progress).**

Two drivers are available for the Apple Magic Mouse v3 (2024) on Windows. The **v2 KMDF driver** (recommended) restores scroll **and** gestures **and** battery readout, and has been in daily use on developer hardware for months. The **v1 binary patch** is the older fallback (scroll only). No tagged GitHub Release exists yet — install assets are being finalized. See **[Choose Your Driver](#choose-your-driver)** below.

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

## Choose Your Driver

This repo ships **two** independent drivers. Pick one — you do not install both.

| | **v2 — KMDF driver** ★ recommended | **v1 — binary patch** |
|---|---|---|
| **Scroll** | ✅ | ✅ |
| **Gestures** | ✅ | ❌ |
| **Battery %** | ✅ native (shows in Windows Settings) | ⚠️ workaround only — *mutually exclusive with scroll* (see below) |
| **Source** | Full source, auditable | Opaque patched Apple binary |
| **Apple dependency** | None (written from scratch) | Patches Apple's `applewirelessmouse.sys` |
| **Maturity** | In daily use on dev hardware for months | Older approach (sbagirici lineage) |
| **Trade-off** | Adds a KMDF filter to the Bluetooth stack | Redistributes a patched Apple binary (see [DMCA-NOTICE](DMCA-NOTICE.md)) |
| **Both require** | Test-signing enabled + trust the self-signed cert (shows a "Test Mode" desktop watermark) | same |

### The battery difference (important)

- **v2 KMDF** exposes battery natively (HID Feature report, `RID 0x47`). Scroll, gestures, and battery
  all work **at the same time**, with no manual steps — battery percentage appears in Windows Settings.
- **v1 binary patch** cannot do scroll and battery at once. With v1, the two are **mutually exclusive**:
  one device state gives you scroll (battery unavailable), the other gives you a battery read (scroll
  broken). Getting a battery reading means manually flipping the device state and flipping back. This is
  a clunky legacy workaround — it is the main reason the v2 KMDF driver was built.

```
   v1 — BINARY PATCH                       v2 — KMDF DRIVER  (★ recommended)
   Scroll  ─┐  MUTUALLY                    Scroll + Gestures + Battery %
   Battery ─┘  EXCLUSIVE                   ALL AT ONCE, natively
        │   flip device state to               │   one install, done
        │   swap scroll ⇄ battery              │
        ▼                                      ▼
   ✓ Scroll OR ✓ Battery (never both)      ✓ Scroll  ✓ Gestures  ✓ Battery
```

**Recommendation:** choose **v2 KMDF** unless you specifically cannot run a kernel filter driver. It is
the only option that gives scroll + gestures + battery together, and it does not redistribute Apple code.

> **Install:** v1 binary-patch steps are in [Quick Install](#quick-install-3-steps) below. The v2 KMDF
> installer (`mm-dev.ps1`) and signed binaries ship with the upcoming tagged release.

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

## Quick Install (3 Steps)

> **Not yet available — ships with the first tagged release.** The signed v1
> binary, its `SHA256SUMS` checksum file, and the install script are published as
> assets on the GitHub release (see [Releases](../../releases)). The steps below
> describe the flow; the exact filenames and the verified checksum will be filled
> in from the release assets when the tag is cut. **Do not trust any hash that is
> not published in the release's `SHA256SUMS`.**

### Step 1: Download & Verify

```powershell
# Download the v1 binary + SHA256SUMS from the tagged GitHub release, then:
Get-FileHash .\applewirelessmouse.sys -Algorithm SHA256
# Compare the output against the value in the release's SHA256SUMS file.
```

### Step 2: Run Installer

```powershell
# Open PowerShell as Administrator, in the extracted release folder.
# The release bundles the signing certificate and an install script; trust the
# cert (Root + TrustedPublisher) and install the signed package:
.\install-driver.ps1 -InfPath .\MagicMouseDriver.inf
# Accept the certificate-trust prompt when prompted.
```

### Step 3: Reboot

```powershell
shutdown /r /t 60 /c "Magic Mouse driver install - rebooting"
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

## Versions

Two drivers ship from this repo. Pick one with the [Choose Your Driver](#choose-your-driver) table above.

**v2 — KMDF filter driver (recommended, in production):** From-scratch Windows Driver Framework lower filter on the Bluetooth HID stack. Restores scroll + gestures **and** exposes battery percentage natively, all at once. No Apple binary dependency. This is the driver in daily use; signed binaries ship as assets on the tagged release.

**v1 — binary patch (legacy fallback):** Patched Apple `applewirelessmouse.sys` as a WDM lower filter. Restores scroll only; battery readout requires a manual, mutually-exclusive registry flip (see the battery note above). Kept for users who cannot run the KMDF driver.

See `v2-kmdf-driver/README.md` for v2 technical detail.

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
