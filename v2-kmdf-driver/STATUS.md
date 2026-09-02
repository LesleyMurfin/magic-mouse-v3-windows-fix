# Status — unique 2.0.4.1 KMDF (PID 0323)

Branch `ai/kmdf-204-unique-pkg-7748` (PR #4, **draft**). This PC is the only lab. Community how-to-test: `COMMUNITY-TESTING.md`. Ship mechanics: `SHIPPING.md`.

## Working (user-confirmed 2026-09-01)

| Item | State |
|------|--------|
| Pointer | Optical X/Y on RID `0x12` |
| Battery | COL02 `HidD_GetInputReport(0x90)` |
| Surface scroll | **2-finger** → HID Wheel + AC Pan |
| 1-finger on glass | Does **not** scroll (`TWO_FINGER` / `down < 2`) |
| Detent | `MM_SCROLL_STEP` **8** (224 produced zero wheel) |
| Overlay | 135-byte memcpy; prefix `09 02 06 35 8D 35 8B 08 22 25 87` |
| ACL | HidBth IN cap 9; scratch to see 23–31 byte `A1 12`; write 8-byte `0x12` back |
| Bind | oem50, SCM `MagicMouseDriver204Scroll`, dest `MagicMouseDriver-kmdf-204-scroll.sys` |
| Loaded SHA | signed `9901390e…` / unsigned freeze `E73EC0A8…` / thumb **16940C0F** |
| oem16 | `AD5D244B` **not** overwritten |
| After bind | `HidD_SetFeature(F1)` → HidBth 4-byte `0x53` |
| Host gates | `specs/gate_4.py`, overlay/hid_acl/bsod/scroll_threshold, `validate-package.sh` |
| This PC policy | testsigning Yes, Secure Boot off, Memory integrity off |

## Not in this package

Windows/macOS **gestures** (no PTP). v1 `0x030D` / v2 `0x0269`. PATH-A (`0xD1`).

## Left to do

1. Community **swap-test** (`SHIPPING.md`) — pnputil of self-signed package not run on this PC.
2. **Reboot:** does MT survive without F1?
3. Bump **DriverVer** on the next `.sys`.
4. Tray F1 on connect.
5. Virtual PTP (gestures) — new spec, not this overlay.
6. EV + Partner Center if Secure Boot “just works” is the goal.
7. Keep PR #4 draft until swap-test. Do not merge PR #3.
