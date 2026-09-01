# v1.0.0 — Binary patch (unsupported)

**SHIP-BLOCKER for PID 0323.** Do not install this tree.

The package file is **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`**. It has caused BSOD `0xD1` (`DRIVER_IRQL_NOT_LESS_OR_EQUAL`). It is **not** the 0323 product. Never name it `MagicMouseDriver.sys`. Windows would still copy it to `applewirelessmouse.sys` if someone ran the historical installer.

**0323 install entrypoint:** [`../v2-kmdf-driver/Install-KMDF.cmd`](../v2-kmdf-driver/Install-KMDF.cmd)

That KMDF package is `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (FileVersion 2.0.4.0; INF dest `MagicMouseDriver.sys`; sole `LowerFilters=MagicMouseDriver`; PID 0323 only). Do not dual-filter PATH-A with MagicMouseDriver.

This folder is kept as history (bug analysis, architecture notes, SHA256 of the old payload). There is no supported install path here. Do not run `installer/Install-MagicMousePatch.ps1`.

## Historical payload (do not load)

If you need to identify a leftover PATH-A binary on disk:

```
SHA256  370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03
Windows dest   C:\Windows\System32\drivers\applewirelessmouse.sys
Package name   applewirelessmouse-patched-pathA-SHIPBLOCKER.sys
```

Uninstall leftovers with `installer/Uninstall-MagicMousePatch.ps1` (Administrator), then install KMDF.

## Docs (research only)

- `docs/bug-analysis.md` — Mode A / Mode B DSM collapse
- `docs/architecture.md` — WDM lower-filter notes

## Support

Use [`../v2-kmdf-driver/README.md`](../v2-kmdf-driver/README.md) and the root README. Security: `../SECURITY.md`.
