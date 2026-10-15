# Status — KMDF driver (PID 0323)

Current state of Driver 2. How to help test: `COMMUNITY-TESTING.md`. Build: `BUILDING.md`.
Signing and install: `SIGN-AND-INSTALL.md`. Ship plan: `SHIPPING.md`.

## Version

| | |
|--|--|
| Source in this tree | **2.0.4.6** — `DriverVer 09/20/2026,2.0.4.6`, **not yet built or signed** |
| Last built, signed and run on hardware | **2.0.4.3** — `DriverVer 09/15/2026,2.0.4.3`; signed `0CC4458B…`, unsigned freeze `25A3287A…` (26112 bytes), cert thumb `16940C0F` |

2.0.4.4 through 2.0.4.6 are source only: no WDK or MSVC toolchain is present on the machine this
tree is developed on, so nothing newer than 2.0.4.3 has been compiled, signed or installed. What
each of those versions changes is in `CHANGELOG.md`; the measurements behind the 2.0.4.4 fixes are
in `INCIDENT-2026-09-16.md`.

## Working — measured on hardware (signed 2.0.4.3 build)

| Item | State |
|------|--------|
| Pointer | Optical X/Y on RID `0x12` |
| Battery | COL02 `HidD_GetInputReport(0x90)` |
| Surface scroll | **2-finger** → HID Wheel + AC Pan |
| 1-finger on glass | Does **not** scroll (`TWO_FINGER` / `down < 2`) |
| Sensitivity tuning | `Parameters!ScrollStep` + device restart via `scripts/mm-scroll-tune.ps1` — no rebuild, re-sign or reinstall; clamp `[1,224]` |
| Reconnect + boot | `MmAutoF1Watcher` arrival events **and** startup reconcile |
| Overlay | 135-byte memcpy; prefix `09 02 06 35 8D 35 8B 08 22 25 87` |
| ACL | HidBth IN capacity 9; scratch to see the 23–31 byte `A1 12` report; 8-byte `0x12` written back |
| Bind | SCM service `MagicMouseDriver204Scroll`, dest `MagicMouseDriver-kmdf-204-scroll.sys`, its own DriverStore package — Apple's oem16 package is never touched |

## Fixed in source, not yet on hardware (2.0.4.4 – 2.0.4.6)

| Item | State |
|------|--------|
| Battery through a short control read | A control-channel read smaller than a mouse report is no longer diverted into the ACL scratch, so the `GET_REPORT(Input, 0x90)` response survives instead of arriving as `90 00 00` |
| Battery after an idle disconnect | The HID control channel is also learned from device-initiated reconnects (`BRB_L2CA_OPEN_CHANNEL_RESPONSE`), not only from host-initiated opens |
| Detent | **Every** dragging contact emits its own notches again; default `ScrollStep` **16** (the 2.0.4.3 build shipped 8) |
| Sleep/wake | The watcher polls for compact 9-byte mode on an active mouse and re-arms multitouch itself |

## Host gates (no compiler needed)

`specs/gate_4.py` and the overlay / HID-ACL / MT-enable / BSOD / scroll-threshold /
two-finger-scroll gates in `v2-kmdf-driver/tests/` each run as `python3 <file>`; exit 0 is a pass.
`v2-kmdf-driver/tests/validate-package.sh` checks the package files themselves.

## Not in this package

Windows/macOS **gestures** (no PTP). Magic Mouse v1 `0x030D` / v2 `0x0269`. PATH-A (`0xD1`).

## Left to do

1. **Build and sign 2.0.4.6** on a Windows host with the EWDK or WDK compiler (`BUILDING.md`),
   then confirm battery, pointer and 2-finger scroll on hardware.
2. **Community swap-test** (`SHIPPING.md`) — `pnputil` of the self-signed community package has
   never been run against a real mouse.
3. **EV certificate + Microsoft Partner Center attestation**, so users no longer need Test Mode
   with Secure Boot and memory integrity off. Funding, not code.
4. **Virtual PTP** for real gestures — a separate driver, not this package.

## Settled — do not re-open

- **Multitouch does not survive a reboot by itself.** Device-arrival events cannot cover boot: the
  mouse is already enumerated before the watcher's WMI subscription exists. The watcher's startup
  reconcile covers it, and `auto-f1-watcher.log` must show `F1 fire (startup reconcile…)` shortly
  after boot.
- **The in-kernel auto-F1 path is deleted, not parked.** 2.0.4.2 self-issued
  `IOCTL_HID_SET_FEATURE` against the sibling COL01 PDO; it returned `STATUS_IO_TIMEOUT` and
  stalled pointer and wheel translation, because that request contends on the control channel this
  filter already holds single-slot state for. `kmdf-204-scroll-build.ps1` refuses `Driver.c`
  containing `MmHidSetFeatureWorkItemFunc` or `IoRegisterPlugPlayNotification`.
- **Scroll sensitivity is the detent, never a reference finger.** The 2.0.4.3 single-reference-finger
  rule emitted nothing whenever the lowest-id contact was resting, and is reverted; the double
  count it was aimed at is answered by `MM_SCROLL_STEP` 16, still registry-tunable.
- **`DriverVer` is bumped per build.** The build and sign scripts derive every work directory,
  stage directory and version string from `-Version`, so a bump needs no script edits.
