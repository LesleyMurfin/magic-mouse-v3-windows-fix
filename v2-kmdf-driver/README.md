# MagicMouseDriver (KMDF) — PID 0x0323 only

**This is the 0323 product.** Double-click `Install-KMDF.cmd`. Success is **pointer and vertical/horizontal surface scroll**.

**Do not install this tree on the live Apr 30 PC yet.** Linux cannot produce a `.sys`. Do not merge until hardware proves scroll. Do not replace the live Apr 30 `MagicMouseDriver.sys` (`AD5D244B`) by hand.

Do not install the v1 `applewirelessmouse.sys` binary patch (BSOD 0xD1). Do not install the May 20 WDKTestCert 2.0.2.0 (pointer-dead). Do not stack filters. No PATH-A. No dual-filter.

`magic-tray` PR #74 should **pull and install this package** for 0323. Do not vendor the KMDF tree into `magic-tray`.

## One click

1. Clone this repo on Windows.
2. Double-click **`v2-kmdf-driver/Install-KMDF.cmd`**.
3. The **first** run asks for Administrator **once**. That registers two SYSTEM scheduled tasks (`MM-Kmdf-Install`, `MM-Kmdf-PostBoot`). Later clicks only run the task — **no UAC**.
4. The SYSTEM task then, unattended:
   - Builds `MagicMouseDriver.sys` if it is missing and a WDK/EWDK is installed
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
| **No `.sys` on GitHub** | This environment cannot compile a kernel driver. The repo ships **source + INF + vcxproj + the one-click scripts**. On a Windows machine with WDK or Enterprise WDK, the SYSTEM task builds; or drop a built `MagicMouseDriver.sys` next to the INF and click again. |
| **Test signing** | A self-signed `.sys` will not load until `bcdedit /set testsigning on` and a reboot. A "Test Mode" watermark on the desktop is expected. |
| **HVCI / Memory Integrity** | Windows 11 Core isolation **blocks** self-signed kernel drivers. The task **fails** with a clear RESULT if HVCI is on. Turn Memory integrity **off**, reboot, click again. There is no Microsoft-signed binary in this repo yet. |
| **Apr 30 live KMDF** | `MagicMouseDriver.sys` 24536 bytes, SHA256 `AD5D244B…`, `CN=MagicMouseFix` thumb `B902C286…`. **Pointer moves, scroll does not.** Keep installed. Do not replace until a 2.0.4 `.sys` from this source is built on Windows WDK. |
| **Live HID 2026-08-30 21:23 MDT** | On that Apr 30 binary: `HidD_GetInputReport(0x90)` on **COL02** works (`[90 04 2F …]` → 47% at `buf[2]`). **Feat 0x47 fails** on COL01 and COL02. **COL01 Input 0x12 is X/Y only** — no Wheel usage `0x0038`. All other InRpt/Feat fail. Product battery = RID **0x90**, not 0x47. Product scroll = Wheel/AC Pan on the **0x12** path HidBth delivers, not a convert-to-0x02. |
| **May 20 WDKTestCert** | 29184 bytes, SHA256 `559B136A…`, version 2.0.2.0. HID started, **pointer dead**. The one-click task **refuses** to install it. |
| **v1 applewirelessmouse.sys** | PATH-A patch. **SHIP-BLOCKER** (BSOD 0xD1). Not the 0323 product. |

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
