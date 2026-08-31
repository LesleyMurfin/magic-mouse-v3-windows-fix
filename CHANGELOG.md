# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.4.1] - 2026-08-31

### Changed

- Unique INF / catalog / dest `.sys` so Windows creates a **new** DriverStore folder beside Apr 30 oem16 (`f7bf31c7`). Does not reuse the failed oem26 identity (`MagicMouseDriver.inf` + `MagicMouseDriver.cat` + `08/30/2026,2.0.4.0` / `magicmousedriver.inf_amd64_79beb68f1da25da4`).
  - INF: `MagicMouseDriver-kmdf-204-scroll.inf`
  - CatalogFile: `MagicMouseDriver-kmdf-204-scroll.cat`
  - DriverVer: `09/01/2026,2.0.4.1`
  - ServiceBinary / CopyFiles: `MagicMouseDriver-kmdf-204-scroll.sys` (not `MagicMouseDriver.sys`)
- Canonical artifact: `MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys` after the freeze-hash gate. Never ship a second live-named `MagicMouseDriver.sys`.
- Install story is **signed `pnputil /add-driver` only**. Removed SYSTEM auto-sign / unsigned-activate path (`Invoke-KmdfInstall.ps1`, `pr3-activate` style Copy-Item onto System32 / DriverStore). Uninstall deletes only the unique package (leaves oem16).
- Human signs with cert thumb `16940C0F` (private key on the PC). No PFX in git.
- ACL rewrite will not grow a 6-byte 0x12 report past proven buffer capacity (Event 41 hunch; pointer-safe passthrough if it cannot grow).
- HID contract documented: keep X/Y `0x0030`/`0x0031` on 0x12; add Wheel `0x0038` as extra; battery stays Input `0x90` COL02; no Feature `0x47`. PATH-A still ship-blocker.
- Refuse SHA `845435CE…` (failed 2.0.4), May 20 `559B136A…`, and Apr 30 `AD5D244B…` as *this* package.

## [2.0.4] - 2026-08-31

### Changed

- Artifact / backup / FileVersion labels so KMDF and PATH-A cannot be mixed up. Windows still installs KMDF as `MagicMouseDriver.sys` and PATH-A as `applewirelessmouse.sys`.
  - Pointer-only: `MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys` (FileVersion not 2.0.4.0)
  - Pointer-dead: `MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys` (FileVersion 2.0.2.0; installer refuses)
  - Scroll candidate: `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (FileVersion / DriverVer **2.0.4.0**)
  - PATH-A ship-blocker: `applewirelessmouse-patched-pathA-SHIPBLOCKER.sys` (v1-binary-patch only)
- Live HID 2026-08-30 21:23 MDT on Apr 30 MagicMouseFix (`AD5D244B`): **stay on the path HidBth delivers**
  - COL01 Input **0x12** is X/Y only (no Wheel usage 0x0038) — that is why pointer moves and scroll does not
  - COL02 `HidD_GetInputReport(0x90)` works: `bytes=[90 04 2F ...]` → 47% at `buf[2]`
  - Feature **0x47 fails** on COL01 and COL02. Product battery is RID **0x90 Input**, not 0x47
- SDP inject now adds Wheel (GD 0x38) and AC Pan (Consumer 0x0238) on **RID 0x12**, plus RID **0x90** battery Input
- Gesture/ACL rewrite stays on 8-byte RID **0x12** (`[12][buttons][X i16][Y i16][AC Pan][Wheel]`). Does **not** convert to RID 0x02
- Do not install this build on the live Apr 30 PC until a Windows WDK `.sys` exists. Do not merge until hardware proves scroll

## [2.0.3] - 2026-08-31

### Added

- KMDF `MagicMouseDriver` source package in `v2-kmdf-driver/` (PID **0x0323 only**)
- One-click `Install-KMDF.cmd`: first run registers SYSTEM tasks `MM-Kmdf-Install` and `MM-Kmdf-PostBoot`; later runs start the task with no UAC
- Unattended SYSTEM path: test-signing, self-sign cert + catalog, `pnputil` install, sole `LowerFilters=MagicMouseDriver`, Bluetooth disable/enable bounce, reboot if required, post-boot verify
- RID 0x12 / 0x27 → 6-byte RID 0x02 translation (optical X/Y + buttons + **vertical and horizontal surface scroll**) on ACL completions and IRP_MJ_READ — **superseded in 2.0.4** (live hidclass bound 0x12, not 0x02)
- Installer refuses May 20 WDKTestCert SHA256 `559B136A…`; reuses `CN=MagicMouseFix` when present; Bluetooth bounce only if HID did not start
- `MAGIC-TRAY.md`: tray PR #74 should pull this KMDF for 0323 and must not vendor it

### Fixed

- Live 2.0.2.0: HID started, pointer did not move — descriptor injection without matching X/Y reports

### Removed / rejected

- No `mm-dev.ps1 -Phase Full`
- No dual-filter `MagicMouseDriver,applewirelessmouse`
- No 030D / 0310 INF hardware IDs
- v1 patched `applewirelessmouse.sys` marked ship-blocker (BSOD 0xD1)

## [1.0.0] - 2026-05-18

### Added

- Initial public release: PATH-A binary patch for Apple Magic Mouse v3 scroll stop bug
- Patched applewirelessmouse.sys kernel driver (66 KB, SHA256: 370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03)
- MagicMouseFix certificate (CN=MagicMouseFix, thumbprint 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE)
- PowerShell installer script (Install-MagicMousePatch.ps1) with:
  - OS version checking (Windows 10 build 14393+, Windows 11 all builds)
  - Magic Mouse PID 0x0323 detection
  - Binary SHA256 verification
  - Certificate import to LocalMachine\TrustedPublisher and Root stores
  - Driver backup to C:\ProgramData\MagicMousePatch\backup\
  - PendingFileRenameOperations support for locked files
  - Registry-based LowerFilters registration
  - Service registration via sc.exe and registry
  - Reboot instruction prompt
- PowerShell uninstaller script (Uninstall-MagicMousePatch.ps1) with:
  - LowerFilters registry cleanup
  - Driver restore from backup
  - Service removal
  - Certificate removal by thumbprint
  - Complete system state rollback
  - Reboot instruction prompt
- Complete documentation:
  - README.md with quick install (3 steps)
  - bug-analysis.md explaining Mode A/Mode B problem, DSM behavior, registry changes
  - architecture.md detailing WDM lower filter implementation
  - CONTRIBUTING.md with issue template and test procedures
  - SECURITY.md with vulnerability disclosure process
- GitHub issue template (bug_report.md) requiring:
  - Windows version and build
  - Magic Mouse PID verification
  - Event log exports from Microsoft-Windows-Kernel-PnP/Configuration and Microsoft-Windows-DeviceSetupManager/Admin channels
- GitHub Actions workflow (ps-lint.yml) running PSScriptAnalyzer on all PowerShell scripts
- .gitignore excluding Windows driver artifacts while preserving release binaries and certificates

### Fixed

- Apple Magic Mouse v3 scroll stops working after Bluetooth idle disconnect + DeviceSetupManager property sync
- HID collection COL02 collapse during DSM initialization now prevented
- DynamicCachedServices registry rewrite side effects mitigated

### Tested

- Test 1 (power off/on): scroll persists — PASS
- Test 2 (BT idle + DSM replay): held Mode A 69+ min vs 22-min historical flip — PASS
- Test 3 (pnputil rescan): scroll stable — PASS
- Test 4 (sleep/wake): cache byte-identical — PASS
- Test 6 (UsoClient force-DSM): scroll preserved — PASS
- Phase 5 (cold reboot): DSM ran twice post-boot, cursor + scroll working — PASS

### Hardware

- Apple Magic Mouse v3 (2024), Bluetooth HID PID 0x0323
- MAC format: D0C050XXXXXX
- Tested on Windows 10 build 14393+, Windows 11 any build

### Known Limitations

- v1.0.0 is a binary patch of Apple firmware via WDM lower filter; requires certificate trust prompt on first install
- Depends on applewirelessmouse.sys patched binary (not open source)
- Works with Windows 10 build 14393 and later; earlier builds not supported

### Roadmap

- v2.0.0: KMDF filter driver rewrite from source (in progress — see /v2-kmdf-driver/)
- Remove Apple binary dependency
- Native WDF source code
- Improved Windows Defender SmartScreen integration
- Windows 11 22H2+ optimizations
