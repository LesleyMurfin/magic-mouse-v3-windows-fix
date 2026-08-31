# MagicMouseDriver (KMDF) — PID 0x0323 only

**This is the 0323 product.** Double-click `Install-KMDF.cmd`. Success is **pointer and vertical/horizontal surface scroll**.

**Do not install this tree on the live Apr 30 PC yet.** Linux cannot produce a `.sys`. Do not merge until hardware proves scroll. Do not replace the live Apr 30 pointer-only binary by hand.

Windows still installs KMDF as **`MagicMouseDriver.sys`**. Package names are different so they cannot be mixed with PATH-A:

| Package / backup filename | FileVersion | Role |
|---------------------------|-------------|------|
| **`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`** | not 2.0.4.0 | **Pointer-only.** SHA `AD5D244B…`. Scroll dead. Leave on the live PC. |
| **`MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys`** | 2.0.2.0 | **Pointer-dead.** Installer refuses this SHA. |
| **`MagicMouseDriver-kmdf-2.0.4-scroll.sys`** | **2.0.4.0** | **Scroll candidate** from this source. Hash after Windows WDK build. |
| **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`** | PATH-A v1 | **SHIP-BLOCKER.** Lives in `v1-binary-patch/`. Never this product. Never `MagicMouseDriver.sys`. |

Do not install PATH-A. Do not install May 20. Do not stack filters. No dual-filter.

`magic-tray` PR #74 should **pull and install this package** for 0323. Do not vendor the KMDF tree into `magic-tray`.

## One click

1. Clone this repo on Windows.
2. Double-click **`v2-kmdf-driver/Install-KMDF.cmd`**.
3. The **first** run asks for Administrator **once**. That registers two SYSTEM scheduled tasks (`MM-Kmdf-Install`, `MM-Kmdf-PostBoot`). Later clicks only run the task — **no UAC**.
4. The SYSTEM task then, unattended:
   - Builds `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (FileVersion 2.0.4.0) if it is missing and a WDK/EWDK is installed, then stages it as `MagicMouseDriver.sys` for INF
   - Turns on test signing if needed
   - Creates a local `CN=MagicMouseDriver` certificate, signs `.sys` + `.cat`, trusts the publisher
   - `pnputil` installs the package
   - Binds **PID 0323 only**, `LowerFilters=MagicMouseDriver` **sole** (never `applewirelessmouse`, never 030D)
   - Bounces Bluetooth (disable then enable the radio, then restart the 0323 node)
   - Reboots if test signing just changed or PnP asked for it
   - After boot, `MM-Kmdf-PostBoot` checks: service Running, stack `HidBth` / `MagicMouseDriver`, HID started
5. Read **`C:\ProgramData\MagicMouseDriver\RESULT.txt`** — `PASS` or `FAIL`.

Uninstall: double-click `Uninstall-KMDF.cmd`.

## Honest limits

| Topic | What actually happens |
|-------|------------------------|
| **No `.sys` on GitHub** | This environment cannot compile a kernel driver. The repo ships **source + INF + vcxproj + the one-click scripts**. On Windows + WDK the SYSTEM task builds `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (FileVersion 2.0.4.0) and INF copies it as `MagicMouseDriver.sys`. |
| **Test signing** | A self-signed `.sys` will not load until `bcdedit /set testsigning on` and a reboot. A "Test Mode" watermark on the desktop is expected. |
| **HVCI / Memory Integrity** | Windows 11 Core isolation **blocks** self-signed kernel drivers. The task **fails** with a clear RESULT if HVCI is on. Turn Memory integrity **off**, reboot, click again. There is no Microsoft-signed binary in this repo yet. |
| **Apr 30 live KMDF** | Package name **`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`**. Installed as `MagicMouseDriver.sys`, 24536 bytes, SHA256 `AD5D244B…`, `CN=MagicMouseFix` thumb `B902C286…`. **Pointer-only.** Keep installed. FileVersion is **not** 2.0.4.0. |
| **Live HID 2026-08-30 21:23 MDT** | On that Apr 30 binary: `HidD_GetInputReport(0x90)` on **COL02** works (`[90 04 2F …]` → 47% at `buf[2]`). **Feat 0x47 fails** on COL01 and COL02. **COL01 Input 0x12 is X/Y only** — no Wheel usage `0x0038`. All other InRpt/Feat fail. Product battery = RID **0x90**, not 0x47. Product scroll = Wheel/AC Pan on the **0x12** path HidBth delivers, not a convert-to-0x02. |
| **May 20 WDKTestCert** | Package name **`MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys`**. 29184 bytes, SHA256 `559B136A…`, FileVersion **2.0.2.0**. HID started, **pointer dead**. The one-click task **refuses** it. |
| **PATH-A** | Package name **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`**. Windows name `applewirelessmouse.sys`. **SHIP-BLOCKER** (BSOD 0xD1). Not the 0323 product. |

## What magic-tray should install

For **0323** (live USB-C Magic Mouse):

- Source of truth: `LesleyMurfin/magic-mouse-v3-windows-fix` / `v2-kmdf-driver/`
- User action in the tray: same as `Install-KMDF.cmd` (register/start `MM-Kmdf-Install`), **or** download this folder and run that cmd
- Do **not** default 0323 to `sbagirici` / Boot Camp `applewirelessmouse.sys`
- Do **not** copy this tree into `magic-tray/driver/`

## Layout

```
v2-kmdf-driver/
  Install-KMDF.cmd          ← one click
  Install-KMDF.ps1          ← register/start SYSTEM task (UAC once)
  Uninstall-KMDF.cmd
  MagicMouseDriver.inf      ← 0323 only
  MagicMouseDriver.vcxproj
  Driver.c / GestureEngine.c / AclTranslate.c / ...
  scripts/
    Invoke-KmdfInstall.ps1  ← runs as SYSTEM
    Invoke-KmdfPostBoot.ps1
    Kmdf-Common.ps1
```

There is **no** `mm-dev.ps1` and **no** `Phase=Full` that `sc delete`s MagicMouseDriver globally or sets a dual filter.

## Manual build (optional)

See `BUILDING.md`. Not required if you only use the one-click task on a machine that already has WDK.
