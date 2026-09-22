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
- The device is disabled and re-enabled with `Disable-PnpDevice` / `Enable-PnpDevice` from the
  `PnpDevice` module rather than `pnputil /disable-device` and `/enable-device`. Those pnputil
  verbs only exist from Windows 10 version 2004 (build 19041), while this installer supports
  build 14393 and up, so on 1607-1909 they could not work at all. Disabling is now treated as
  the optimisation it is: when it cannot be done the copy is still attempted and nothing is
  re-enabled afterwards, and a device that *was* disabled is re-enabled even if the copy fails

### Removed

- The `pnputil` driver-package install route, and the switch that forced the installer past it.
  There is now exactly one route: copy the `.sys` into `C:\Windows\System32\drivers\`, register
  the kernel service, write `LowerFilters` on the chosen device instance. That route was also the
  only way to reach a `-DryRun` that printed an installation-complete banner. No `pnputil` call
  remains on the Driver 1 path

### Fixed

- The 1.0.0 entry below records "Certificate import to LocalMachine\TrustedPublisher and Root
  stores". No `Root` import is performed, and none ever should be: `Root` would let anything
  signed with that key load. The certificate — for the legacy variant only — goes to
  `LocalMachine\TrustedPublisher` and nowhere else. Released history is left as published; this
  entry is the correction
- Writing `LowerFilters` is refused on a machine that keeps the stock ACL on
  `HKLM\SYSTEM\CurrentControlSet\Enum`, which grants Full Control to `SYSTEM` and read-only to
  `Administrators`. That surfaced as a stack trace after the driver had already been copied and
  the service registered. The installer and uninstaller now name the condition and the two ways
  out — run in a SYSTEM context, or grant write access to that one device-instance key — and do
  not report success
- Driver 1 was documented as v3-only in the root README and in the Driver 1 Quick Start, which
  told v1 and v2 owners the fix would not help them. It supports all four PIDs

## [2.0.4.6] - 2026-09-20

Driver 2, the KMDF driver in `v2-kmdf-driver/`. `DriverVer 09/20/2026,2.0.4.6`. Source only: the
last version built, signed and run on hardware is 2.0.4.3.

### Fixed

- Multitouch is recovered automatically after sleep/wake. `mm-auto-f1-watcher.ps1` polls the
  driver's `Diag` key every 5 seconds and re-sends the `HidD_SetFeature([F1,02,01])` enable when
  the device is reporting compact 9-byte input (`LastAclReceived = 9`) while `Rid12Count` is still
  advancing — an actively used mouse that has silently dropped out of multitouch mode. Arrival
  events and the startup reconcile cover reconnects and boot but never fire on resume, so scroll
  previously stayed dead after a sleep/wake cycle until `mm-f1-once.ps1` was run by hand
- A control-channel read whose mapped buffer is shorter than a mouse report is no longer diverted
  into the ACL scratch. `BufferSize` alone was not enough: HidBth reads that channel header-first,
  asking for one byte at a time, and the MDL byte count is what says how much the caller can
  actually receive

## [2.0.4.5] - 2026-09-17

Driver 2. `DriverVer 09/17/2026,2.0.4.5`. Source only.

### Fixed

- The HID control channel is now learned from device-initiated reconnects as well as
  host-initiated opens. Only `BRB_L2CA_OPEN_CHANNEL` was recognised, so after an idle disconnect —
  which the mouse re-establishes itself, as `BRB_L2CA_OPEN_CHANNEL_RESPONSE` — the tracked channel
  handle stayed `NULL`, the control-channel pass-through never engaged, and the COL02 Input `0x90`
  battery percent read back as zero

## [2.0.4.4] - 2026-09-16

Driver 2. `DriverVer 09/16/2026,2.0.4.4`. Source only.

### Changed

- Every dragging contact emits its own wheel notches again. 2.0.4.3 had nominated one reference
  finger — the lowest active drag slot — to halve an accidental double count, but every other
  contact was still re-anchored, so its travel was discarded: whenever the lowest-id contact was
  resting or moving slower than the detent, the finger that was actually sliding emitted nothing
  and scroll was dead rather than merely coarse. Measured on hardware: 694 multitouch reports over
  15 active seconds produced 0 wheel events, against 24 wheel events from the per-contact rule
- The default scroll detent `MM_SCROLL_STEP` is **16**, up from 8, which answers the double count
  the reference finger was aimed at without any gesture going silent. `ScrollStep` remains a
  registry value with the same `[1,224]` clamp, so sensitivity is still tunable without a rebuild

### Fixed

- The COL02 Input `0x90` battery report is no longer swallowed by the ACL scratch diversion. A
  1-byte control-channel read matched the old `BufferSize > 0` gate, so the filter substituted its
  142-byte scratch buffer, the transport delivered the whole `GET_REPORT(Input, 0x90)` response into
  it, and only one byte could be copied back — every layer saw `90 00 00` with `STATUS_SUCCESS`
- `RemainingBufferSize` is restored after a diverted ACL transfer completes, instead of being left
  holding the scratch buffer's size

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
