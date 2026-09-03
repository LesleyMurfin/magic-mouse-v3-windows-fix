# magic-tray: install this KMDF for 0323

Magic Tray treats **this repo / `v2-kmdf-driver/`** as the 0323 driver. Clone `main` and run `v2-kmdf-driver/Install-KMDF.cmd`.

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
- Treat PATH-A / May 20 as installable 0323 products.
- Ship or install `applewirelessmouse-patched-pathA-SHIPBLOCKER.sys` as `MagicMouseDriver.sys`.
- Ship May 20 as `MagicMouseDriver-kmdf-2.0.4-scroll.sys`.

Tray SELECT for 0323 should pull **`MagicMouseDriver-kmdf-2.0.4-scroll.sys`** (FileVersion 2.0.4.0; INF dest `MagicMouseDriver.sys`). Leave **`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`** as the pointer-only baseline. Refuse **`MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys`**. PATH-A stays in `v1-binary-patch/` as **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`**.

Live HID 2026-08-30 21:23 MDT (Apr 30 `AD5D244B`, do not replace that `.sys` yet): battery is RID **0x90** Input on COL02; Feat **0x47** fails; COL01 Input **0x12** is X/Y only (no `0x0038`). Tray should ship the 2.0.4 source that stays on that 0x12 path.
