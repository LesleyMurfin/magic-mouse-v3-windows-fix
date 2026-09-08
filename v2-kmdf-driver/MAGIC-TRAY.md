# magic-tray: install this KMDF for 0323

`LesleyMurfin/magic-tray` PR #74 should treat **this repo / `v2-kmdf-driver/`** as the 0323 driver.

## Do

- Offer **Install KMDF** that uses the **signed unique package** only:
  `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install`
- Bind **PID 0323 only**.
- Keep `LowerFilters=MagicMouseDriver204Scroll` **sole**. `MagicMouseDriver` is the Apr 30 oem16 service — do not set it.
- Pull the freeze-named artifact `MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys`.

## Do not

- Vendor this tree into `magic-tray/driver/`.
- Default 0323 to `sbagirici` or Boot Camp `applewirelessmouse.sys`.
- Dual-filter with `applewirelessmouse` (PATH-A is a BSOD 0xD1 ship-blocker).
- Retarget 030D / 0269 with this INF.
- Call leftover `mm-dev.ps1 -Phase Full`.
- Install May 20 / PATH-A / dual-filter / SHA `845435CE…`.
- `Copy-Item` onto `C:\Windows\System32\drivers\MagicMouseDriver.sys` or DriverStore.
- Run unsigned activate (`pr3-activate-204`).
- `pnputil /delete-driver` Apr 30 oem16 / `MagicMouseDriver.inf`.
- Ship a second live-named `MagicMouseDriver.sys`.
- Treat this PR as merge-ready before hardware proves pointer **and** scroll.

Tray SELECT for 0323 should pull **`MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys`** (FileVersion 2.0.4.1; INF dest `MagicMouseDriver-kmdf-204-scroll.sys`). Leave **`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`** as the pointer-only baseline (live name `MagicMouseDriver.sys`). Refuse **`MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys`**. PATH-A stays in `v1-binary-patch/`.
