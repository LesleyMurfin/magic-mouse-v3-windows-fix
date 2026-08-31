# magic-tray: install this KMDF for 0323

`LesleyMurfin/magic-tray` PR #74 should treat **this repo / `v2-kmdf-driver/`** as the 0323 driver.

## Do

- Offer **Install KMDF** that clones or downloads `magic-mouse-v3-windows-fix` and starts `v2-kmdf-driver/Install-KMDF.cmd` (or `schtasks /run /tn MM-Kmdf-Install` after first register).
- Bind **PID 0323 only**.
- Keep `LowerFilters=MagicMouseDriver` **sole**.

## Do not

- Vendor this tree into `magic-tray/driver/`.
- Default 0323 to `sbagirici/apple-magic-mouse-scroll-fix-windows` or Boot Camp `applewirelessmouse.sys`.
- Dual-filter with `applewirelessmouse` (v1 binary is a BSOD 0xD1 ship-blocker).
- Retarget 030D / 0269 with this INF.
- Call leftover `mm-dev.ps1 -Phase Full`.
- Install a May 20 / PATH-A / dual-filter binary.
- Treat this PR as merge-ready before a Windows-built `.sys` proves pointer **and** scroll on hardware.

Live HID 2026-08-30 21:23 MDT (Apr 30 `AD5D244B`, do not replace that `.sys` yet): battery is RID **0x90** Input on COL02; Feat **0x47** fails; COL01 Input **0x12** is X/Y only (no `0x0038`). Tray should ship the 2.0.4 source that stays on that 0x12 path.
