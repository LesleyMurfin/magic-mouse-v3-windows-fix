# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Apple-driver install route. `v1-binary-patch/apple-driver/applewirelessmouse.sys` is Apple's
  own driver redistributed **unmodified** (SHA256
  `08F33D7E3ECE2C73950A9706F1C4C9057894EAEAF1C4FB355F261F3C2333378F`, 78,424 bytes, version
  6.1.7700.0), still carrying its Apple signature and Microsoft WHQL countersignature
  (`CN=Microsoft Windows Hardware Compatibility Publisher`). The fix is the *registration* —
  creating the kernel service and binding the driver as a lower filter — which Windows does not
  do on a non-Mac PC. That logic is this project's own work.
- `v1-binary-patch/Install.cmd`: one-click, self-elevating installer. No PowerShell window and
  no execution-policy change.
- Support for every Magic Mouse model the filter serves, not just v3: `0x030D` (v1), `0x0269`
  and `0x0310` (v2), `0x0323` (v3). New `-TargetPid` switch selects a single model.
- Installer switches `-DriverPath`, `-FromDriverStore` and `-DryRun`.

### Changed

- **The shipped route no longer requires Windows Test Mode or a certificate.** Apple's binary is
  countersigned by Microsoft, so Secure Boot and memory integrity should be able to stay on.
  Note this is not yet verified on a machine with test signing off — the development PC runs
  with it on. Confirm with `sc query applewirelessmouse` after rebooting.
- The installer now identifies which binary it was handed rather than pinning one hash:
  `AppleSigned` (Authenticode Valid + Apple/Microsoft signer + Apple's PE `OriginalFilename`)
  or `PatchedResigned` (the legacy thumbprint). Apple's driver is deliberately **not**
  hash-pinned at runtime, because Apple has shipped more than one Boot Camp build and a pin
  would reject a legitimately signed newer copy. Test-signing and certificate-import steps are
  gated to `PatchedResigned` only.
- Release provenance moved to model v2: the shipped driver is verified by hashing the tracked
  bytes rather than scraping a constant out of the installer, which is what the old
  `$ExpectedSha256` / `$ExpectedSize` pair did. The legacy triple is still verified where it is
  documented.
- `DMCA-NOTICE.md` rewritten: the repository now redistributes Apple's driver verbatim rather
  than a patched derivative, which is a materially different posture and is stated as such.
- `README.md` and `SECURITY.md` corrected. `README.md` had claimed the installer imports a
  certificate into `LocalMachine\TrustedPublisher` **and the Root store**; the installer imports
  to `TrustedPublisher` only, and its own comment calls a Root import a security hole.

### Deprecated

- The byte-patched, re-signed driver variant (SHA256 `370A5555…`, 66,288 bytes, signed
  `CN=MagicMouseFix`) is no longer shipped. Patching breaks Apple's countersignature, which is
  why it needed Test Mode. Its constants are retained so an existing installation can be
  identified and cleanly uninstalled.

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
