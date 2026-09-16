# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Apple's own `applewirelessmouse.sys`, **unmodified**, bundled at
  `v1-binary-patch/apple-driver/applewirelessmouse.sys` (78,424 bytes, version 6.1.7700.0, SHA256
  `08F33D7E3ECE2C73950A9706F1C4C9057894EAEAF1C4FB355F261F3C2333378F`, Apple signature with
  Microsoft WHQL countersignature intact). No `.inf` and no `.cat`: the installer registers the
  service itself, so nothing needs a re-signed catalog. Checksum in
  `v1-binary-patch/installer/SHA256SUMS.txt`
- One-click `v1-binary-patch/Install.cmd`: requests Administrator itself and runs the installer
  against the bundled driver, so there is no PowerShell to open and no execution policy to change
- Installer variant detection from the Authenticode signature: `AppleSigned` (Apple's unmodified
  binary) versus the legacy `PatchedResigned` byte-patched copy. Test Mode, memory integrity
  (HVCI) and certificate-trust requirements are now applied **only** to the legacy variant; a
  binary that matches neither variant is refused. Running the Apple-signed route with Test Mode
  off is expected to work because the binary is Microsoft-countersigned, but is **not yet
  verified** — the development machine runs with `testsigning` on
- Support for every Magic Mouse Bluetooth PID: `030D` (v1), `0269` and `0310` (v2), `0323`
  (v3, 2024, USB-C), matched on the Bluetooth HID profile `00001124` under `BTHENUM`
- `-DryRun`, which reports every action and changes nothing, and
  `-TargetPid <030D|0310|0269|0323>`, which restricts the install to one mouse when several are
  paired

### Changed

- `applewirelessmouse` is registered as a lower filter by writing `LowerFilters` (`REG_MULTI_SZ`)
  on the selected device instance under `HKLM\SYSTEM\CurrentControlSet\Enum\`, preserving any
  filters already present
- Post-install verification now compares the installed file against the source actually installed
  — hash, size, Authenticode status and the signer expected for the detected variant — and reads
  back the `LowerFilters` value and the service key when a mouse was bound. Verification failure
  exits non-zero and points at `Uninstall-MagicMousePatch.ps1`

### Removed

- The `pnputil` driver-package install route, and the switch that forced the installer past it.
  There is now exactly one route: copy the `.sys` into `C:\Windows\System32\drivers\`, register
  the kernel service, write `LowerFilters` on the chosen device instance

### Fixed

- The 1.0.0 entry below records "Certificate import to LocalMachine\TrustedPublisher and Root
  stores". No `Root` import is performed, and none ever should be: `Root` would let anything
  signed with that key load. The certificate — for the legacy variant only — goes to
  `LocalMachine\TrustedPublisher` and nowhere else. Released history is left as published; this
  entry is the correction

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
