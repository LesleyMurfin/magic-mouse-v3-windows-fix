# Magic Mouse v3 Windows Scroll Fix

**0323 product: KMDF `MagicMouseDriver`.** This is the driver [Magic Tray](https://github.com/LesleyMurfin/magic-mouse-tray) installs for the 2024 / USB-C Magic Mouse (Bluetooth PID `0x0323`). Free, MIT, no subscription.

The **only** 0323 install entrypoint is:

```
v2-kmdf-driver/Install-KMDF.cmd
```

Magic Tray clones this repository’s `main` branch and runs that path. You can run the same file by hand.

Do **not** install `v1-binary-patch` / `Install-MagicMousePatch.ps1` / a patched `applewirelessmouse.sys`. That PATH-A binary is unsupported for shipping (BSOD `0xD1`).

## What this fixes

Apple Magic Mouse v3 on Windows 10/11 loses surface scroll after a Bluetooth idle disconnect and DeviceSetupManager property sync. Cursor still moves; scroll does not come back until you unpair/repair (or install this driver).

This repo ships a from-scratch KMDF lower filter (`MagicMouseDriver`) that binds **PID 0x0323 only**, keeps `LowerFilters=MagicMouseDriver` as the **sole** filter, and presents a standard mouse (RID `0x12` with Wheel / AC Pan) plus battery Input RID `0x90` on COL02.

## Supported hardware

| Model | Year | Bluetooth PID | Supported? |
|-------|------|---------------|------------|
| Magic Mouse v1 | 2009 | `0x030D` | No — use [tealtadpole Boot Camp INF](https://github.com/tealtadpole/MagicMouse2DriversWin11x64) / Magic Tray v1 path |
| Magic Mouse v2 | 2015 | `0x0269` / `0x0310` | No — same v1/v2 INF path |
| Magic Mouse v3 (USB-C) | 2024 | `0x0323` | **Yes — this repo** |

**Verify your PID:** Device Manager → Human Interface Devices → Apple Magic Mouse → Properties → Details → Hardware Ids. You want `PID&0323`.

## System requirements

- Windows 10 build 14393 or later, or Windows 11
- Magic Mouse v3 (PID `0x0323`) paired over Bluetooth
- Administrator (first run only — one UAC prompt)
- Reboot access
- **Test Mode** (`bcdedit /set testsigning on`) — there is no Microsoft-signed `.sys` in this repo yet. A “Test Mode” watermark is expected.
- **Memory integrity / HVCI off** — Windows 11 Core isolation blocks self-signed kernel drivers. Settings → Privacy & security → Windows Security → Device security → Core isolation → Memory integrity **Off**, then reboot.

This installer does **not** turn Driver Signature Enforcement fully off.

## Install (Magic Tray or one click)

### From Magic Tray

1. Pair the USB-C Magic Mouse.
2. In Magic Tray choose **Best for this mouse** / **MagicMouseDriver (KMDF)**.
3. Accept the Administrator prompt.
4. Read `C:\ProgramData\MagicMouseDriver\RESULT.txt` after the task finishes (`PASS` or `FAIL`). The PC may reboot if Test Mode was just enabled.

### Manual (same entrypoint)

1. Clone this repository **on Windows**.
2. Double-click `v2-kmdf-driver\Install-KMDF.cmd`.
3. Accept Administrator **once**. That registers two SYSTEM tasks (`MM-Kmdf-Install`, `MM-Kmdf-PostBoot`). Later clicks start the task with no UAC.
4. The SYSTEM task then, unattended:
   - Builds `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (FileVersion **2.0.4.0**) if a WDK/EWDK is present, and stages it as `MagicMouseDriver.sys` for the INF
   - Turns on test signing if needed
   - Self-signs `.sys` + `.cat` (`CN=MagicMouseFix`) and trusts the publisher
   - `pnputil` installs the package
   - Binds **PID 0323 only**, `LowerFilters=MagicMouseDriver` **sole** (never `applewirelessmouse`, never 030D)
   - Bounces Bluetooth if HID did not start
   - Reboots if test signing just changed
   - After boot, verifies service Running and stack `HidBth` → `MagicMouseDriver`
5. Result file: `C:\ProgramData\MagicMouseDriver\RESULT.txt`  
   Log: `C:\ProgramData\MagicMouseDriver\install.log`

Details: [`v2-kmdf-driver/README.md`](v2-kmdf-driver/README.md). Uninstall: double-click `v2-kmdf-driver\Uninstall-KMDF.cmd`.

## What changes on your system

| Item | Change |
|------|--------|
| Certificate | `CN=MagicMouseFix` in LocalMachine TrustedPublisher and Root |
| Driver file | `C:\Windows\System32\drivers\MagicMouseDriver.sys` |
| Service | `MagicMouseDriver` (kernel, demand-start) |
| Filter | `LowerFilters=MagicMouseDriver` on the 0323 BTHENUM node only |
| Tasks | `MM-Kmdf-Install`, `MM-Kmdf-PostBoot` (SYSTEM) |
| Test Mode | `bcdedit /set testsigning on` if it was off |

## Verify

After reboot:

```powershell
sc query MagicMouseDriver
# STATE should be 4 RUNNING

Get-PnpDevice -Class Mouse | Where-Object { $_.InstanceId -match 'PID_0323|PID&0323' }

Get-Content C:\ProgramData\MagicMouseDriver\RESULT.txt
```

Then:

1. Scroll in any window.
2. Turn the mouse off, wait two minutes, turn it back on.
3. Confirm scroll still works.

Battery for this mouse is HID Input report **0x90 on COL02** (`percent = buf[2]`). Feature 0x47 is not used.

## Package names (do not mix these up)

Windows still loads KMDF as **`MagicMouseDriver.sys`**. Backup / artifact labels are different so they cannot be confused with PATH-A:

| Package / backup filename | FileVersion | Role |
|---------------------------|-------------|------|
| **`MagicMouseDriver-kmdf-2.0.4-scroll.sys`** | **2.0.4.0** | **This product.** INF dest `MagicMouseDriver.sys`. |
| **`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`** | not 2.0.4.0 | Pointer-only baseline. Scroll dead. Not the shipping candidate. |
| **`MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys`** | 2.0.2.0 | Pointer-dead. Installer refuses this SHA. |
| **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`** | PATH-A v1 | **Unsupported.** Lives in `v1-binary-patch/`. Never `MagicMouseDriver.sys`. Never install for 0323. |

There is **no prebuilt `.sys` on GitHub**. Linux cannot compile a kernel driver. On Windows with the WDK, `Install-KMDF.cmd` builds FileVersion 2.0.4.0.

## PATH-A / v1 binary patch — unsupported

`v1-binary-patch/` is historical. It is **not** the 0323 product.

- Do not run `Install-MagicMousePatch.ps1`.
- Do not copy a patched `applewirelessmouse.sys` over the KMDF service.
- Do not dual-filter `MagicMouseDriver` + `applewirelessmouse` (BSOD `0xD1`).

If you previously installed PATH-A, uninstall it (or use `Uninstall-KMDF.cmd` after switching) before installing KMDF.

## How it works

After ~15–30 min idle, DeviceSetupManager can collapse the v3 HID collection:

```
MODE A (working)                      MODE B (broken — after DSM trigger)
────────────────────────────────      ────────────────────────────────────
  Magic Mouse v3 (BT paired)            Magic Mouse v3 (BT paired)
    |
    +-- COL01  <-- pointer + scroll     +-- TLC (unified)  <-- scroll LOST
    |
    +-- COL02  <-- battery / diag           cursor still works
```

Mode B does not self-heal. The KMDF filter sits under HidBth on the 0323 node only:

```
  hidclass.sys
       |
  HidBth.sys
       |
  MagicMouseDriver.sys   <-- KMDF lower filter (this product)
       |
  BTHENUM PDO (PID 0323)
```

Live HID contract: COL01 Input **0x12** (X/Y + Wheel/AC Pan on the shipping build), COL02 Input **0x90** battery. Not Feature 0x47. Not RID 0x02.

## Magic Mouse v1 / v2

This repository is **v3 / 0323 only**. For 2009/2015 mice, Magic Tray installs the tealtadpole Boot Camp INF. See also [`sbagirici/apple-magic-mouse-scroll-fix-windows`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows).

## Contributing

Issues: [GitHub Issues](https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix/issues).

Include `winver`, Hardware Ids (PID), `C:\ProgramData\MagicMouseDriver\install.log`, and:

```powershell
wevtutil epl "Microsoft-Windows-Kernel-PnP/Configuration" C:\pnp-config.evtx
wevtutil epl "Microsoft-Windows-DeviceSetupManager/Admin" C:\dsm-admin.evtx
```

PowerShell scripts must pass PSScriptAnalyzer (GitHub Actions).

## License

MIT License — Copyright 2026 Revive Business Solutions. See `LICENSE`.

## Support

Questions: riley@revivebusiness.ca

Security: `SECURITY.md`.
