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
