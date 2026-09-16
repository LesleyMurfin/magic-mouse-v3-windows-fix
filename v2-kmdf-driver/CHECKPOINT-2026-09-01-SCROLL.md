# Checkpoint — 2026-09-01 two-finger surface scroll (PID 0x0323)

User: **it's working.** Pointer, battery, **2-finger** surface scroll. 1-finger glass does not scroll. No new BSOD. oem16 not overwritten.

## Where the source is

| Item | Value |
|------|--------|
| Worktree | `/data/projects/.worktrees/magic-mouse-v3-windows-fix-scroll` |
| Branch | `ai/kmdf-204-unique-pkg-7748` |
| Do not edit | `/home/lesley/orca/workspaces/magic-mouse-v3-fix/Bios-Driver` |

Ship / test / attestation: `SHIPPING.md`. Working vs leftover: `STATUS.md`. Community how-to-test: `COMMUNITY-TESTING.md`.



## What is loaded on the Apr 30 PC

| Item | Value |
|------|--------|
| Unique dest | `C:\Windows\System32\drivers\MagicMouseDriver-kmdf-204-scroll.sys` |
| Unsigned freeze SHA | `E73EC0A83BB01393C6ECD4359AAC6F52FAEE53C242B87ED2E49630F967375A55` (`TWO_FINGER` + `SCROLL_STEP_8`) |
| Signed on-disk SHA | `9901390eca723517e1c33b92769846584bc0f6b900c694f50a0c3d5597b1a5c9` |
| Artifact name | `MagicMouseDriver-kmdf-2.0.4-scroll-E73EC0A8.sys` |
| Size (unsigned) | 25088 |
| DriverVer | `09/01/2026,2.0.4.1` |
| SCM / LowerFilters | `MagicMouseDriver204Scroll` |
| INF dest | `MagicMouseDriver-kmdf-204-scroll.sys` |
| Sign thumb | `16940C0F` |
| **oem16 restore (must stay)** | `MagicMouseDriver.sys` SHA `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B` |

PnP: HIDClass **Started** oem50; COL01/COL02 Started. After bind, `HidD_SetFeature(F1)` (err 121/-EIO class) so HidBth sends 4-byte `0x53`. Idle `A1 60 02`. Motion+touch `LastAclReceived` 23–31 `A1 12`.

**Live stack:** LowerFilters **`MagicMouseDriver204Scroll` only**, `HidBth`, COL01 `mouhid` + Wheel/AC Pan, COL02 `0x90`. AC-01 FAIL is accept-test wanting live name `MagicMouseDriver`.



Build/sign path that produced this: `v2-kmdf-driver/scripts/kmdf-204-from-wsl.sh` then `kmdf-204-scroll-sign.ps1` + `kmdf-204-pnputil-once.ps1` via `mm-queue-submit.sh`. OutDir `C:\mm-dev-queue\kmdf-204-bld\`. Inf2Cat MSB6006 is expected noise; `.sys` still froze.

## Hardware proof (authoritative)

User: **scroll is working.**

Diag `HKLM\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Diag` after motion:

| Field | Value | Meaning |
|-------|--------|---------|
| `SdpPatchSuccess` | 1 | 135-byte same-size overlay applied |
| `LastAclReceived` | 23–31 | MT-sized interrupt (not 6-byte optical-only) |
| `LastAclCapacity` | 9 | HidBth IN buffer; we scratch-expand, translate, write **8-byte 0x12** back |
| `LastAclBytes` | `A1 12 00 … 29 …` | HIDP DATA INPUT + RID **0x12** + touch tail |
| `Rid12Count` / `AclTranslateCount` | 13637+ | live 0x12 rewrite |
| Idle (no motion) | `A1 60 02` | HIDP DATA INPUT RID **0x60** — not 0x12; ignore |

`mm-accept-test.ps1` (2026-09-01 14:09):

| Check | Result |
|-------|--------|
| AC-02 COL01 Started | PASS |
| AC-03 COL02 Started | PASS |
| AC-04 Wheel `0x0038` + AC Pan `0x0238` | PASS |
| AC-05 COL02 UP `0xFF00` Usage `0x0014` InLen=3 | PASS |
| AC-06 `HidD_GetInputReport(0x90)` | PASS **39%** (`90 04 27`) |
| AC-01 LowerFilters name | FAIL (unique SCM vs live `MagicMouseDriver` — expected) |
| AC-07 `C:\mm3-debug.log` | FAIL (DebugView not required) |
| AC-08 tray `pct=` | FAIL (tray log, not this driver) |

Linux: `specs/gate_4.py`, `tests/test_sdp_overlay.py`, `tests/test_mt_enable.py` exit 0.

## What works (Windows mouse)

- Pointer X/Y on RID `0x12` (usages `0x0030` / `0x0031`)
- **Surface scroll:** finger-drag → HID Wheel `0x0038` (byte 7) and AC Pan `0x0238` (byte 6)
- `GestureEngine.c` `TOUCH_STATE_DRAG` (Linux `magicmouse_emit_touch` style) from 14+8*N touch block in the **scratch** IN buffer
- Compact 8-byte `0x12` keeps native bytes 6–7 if no touch block
- Battery Input `0x90` COL02, percent at byte[2]

## What does **not** work (do not call these “gestures”)

- macOS Mission Control / swipe desktops / pinch / Force Click
- Windows Precision Touchpad gestures
- Linux `emulate_3button` (middle click from finger X)
- Hidclass sees a **mouse with wheel+tilt**, not a digitizer


## Causal path (what actually made it work)

| Step | File / symbol | Why |
|------|----------------|-----|
| 1 | `HidDescriptor.c` `g_HidDescriptor[]` (135 / `0x87`) | hidclass must see Wheel + `0x90`. Count 1 AC Pan then Wheel (not Count-2 inherit). |
| 2 | `InputHandler.c` `SdpRewrite_Process` | Find prefix `09 02 06 35 8D 35 8B 08 22 25 87`; `RtlCopyMemory` 135 HID bytes only. No `buf[4]` / `0x35` rewrite (that 0x50'd). |
| 3 | `Driver.c` `OnSdpQueryComplete` | Calls overlay on `IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE`. `SdpPatchSuccess=1`. |
| 4 | `Driver.c` `EvtIoInternalDeviceControl` / `OnAclTransferComplete` | HidBth IN **capacity 9**. Swap to `Scratch[MM_ACL_MAX_PARSE]`, see 23–31 byte `A1 12`, write 8-byte `0x12` back. Do not grow HidBth’s buffer. |
| 5 | `AclTranslate.c` `TranslateAclHidReport` | Strip optional `A1`; keep `0x90` untouched; call gesture fill. |
| 6 | `GestureEngine.c` `TranslateMouse2ToHid` / `AccumulateSurfaceScroll` | 14+8×N touch → bytes 6/7 AC Pan / Wheel. Compact 8-byte `0x12` keeps native 6/7. |
| 7 | INF dest / SCM unique | oem50 load without hardlinking oem16. |

F1 SetFeature, `OPEN_CHANNEL` 0x11, third-party ACL OUT — **not** in this table.

## Evidence vs luck

- Overlay, unique package, no length rewrite: **dumps** (0x50 `SdpWalkStream`, Event 41).
- Scratch IN: **Diag** `LastAclCapacity=9` / early `LastAclReceived=9`.
- Gesture fill: **Linux** `hid-magicmouse.c` MOUSE2, then **Diag** `A1 12` + 23–31 bytes while scrolling.
- F1: **not a green SetFeature.** HidBth sent 4-byte `53 F1 02 01` (`LastOutHdr=83`); user-mode 121. Linux treats Mouse 2 F1 **-EIO as success**. Before that, motion was **9-byte compact `0x12`** (`Rid12=171`). After, **23–31 byte MT**. Correlation, not a passing `HidD_SetFeature`. Do not keep sending F1.
- Dead-end OUTs/OPENs/`0x55` hijack: measured fail (`0xC0000206`, `0xC00000D0`, HIDClass Error). Not how scroll started.

## How scroll actually enables (measured)

HidBth IN capacity stays **9**. We swap the BRB to `Scratch[MM_ACL_MAX_PARSE]`, so `LastAclReceived` can be 23–31. Translate in scratch; write 8-byte `0x12` (+ optional `A1`) back into the 9-byte HidBth buffer. **Do not grow HidBth’s IN buffer.**

Linux `feature_mt_mouse2` `{0xF1,0x02,0x01}` / wire `53 F1 02 01`:

- Mouse 2 SET_REPORT F1 returns **-EIO** on Linux; that is treated as success + 500ms retry
- Windows `HidD_SetFeature` F1: Win32 **121 TIMEOUT** (same class of “invalid report id”)
- HidBth still sent 4-byte `0x53` (`LastOutHdr=83`, `LastOutBufferSize=4`) when Feature `0xF1` was in the overlay
- **MT-sized interrupt reports still appear** (`LastAclReceived=23–31`) while the user scrolls — do not keep sending F1

## Dead ends — do not repeat

| Attempt | Result |
|---------|--------|
| PATH-A `applewirelessmouse.sys` | BSOD `0xD1` |
| 108-byte HID + SDP length rewrite (`buf[4]` / `0x35`) | BSOD `0x50` `BTHport!SdpWalkStream` |
| Live SCM `MagicMouseDriver` / dest `MagicMouseDriver.sys` | Event 41 / oem16 hardlink |
| Feature F1 inheriting GD Wheel (`FD72C374`) | HIDClass **Error** — reverted |
| Third-party `BRB_L2CA_ACL_TRANSFER` OUT (4 / 9 / 66 bytes) | `0xC0000206` always |
| `BRB_L2CA_OPEN_CHANNEL` Psm `0x11` | `0xC00000D0` (HidBth owns control) |
| Interrupt ACL OUT | `0xC0000206` (IN-only) |
| Rewrite HidBth SET_REPORT `0x55` to F1 | hidclass timeout 121; quieted mouse |
| Eating GET_REPORT `0x41` | LastAcl stuck at 1 |
| Treating control-channel IN as mouse ACL | swallowed HIDP handshake |

Keep: unique SCM, 135-byte memcpy overlay, Count 1 AC Pan then Wheel, `0x90` passthrough, control IN passthrough (`MtControlHandle`), `LastAclBytes` Diag.

## HID overlay (135 bytes, `sizeof == 0x87`)

- Prefix **unchanged**: `09 02 06 35 8D 35 8B 08 22 25 87`
- COL01 RID `0x12`: buttons, X/Y Count 2, then **Count 1** Consumer AC Pan `0A 38 02`, then Wheel `09 38`
- Feature RID **`0xF1`** Count 2, vendor page `0xFF00` Usage `0x01`, Logical Min 0 — **not** GD Wheel (that Error’d)
- COL02 RID `0x90` battery Input
- No `0x85 0x47`, no `0x85 0x02`

## Kernel Diag (read this first next session)

```
HKLM\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Diag
```

`LastAclBytes` REG_BINARY 16 bytes. `LastAclReceived` ≥ 14 (often 23–31) while scrolling. Idle may be `A1 60 02`.

`MtEnableStatus=0xC0000206` / `MtEnableTries=3` is leftover third-party OUT — ignore.

## Rebuild / reload (if you must)

1. Linux: `python3 specs/gate_4.py` and `bash v2-kmdf-driver/tests/validate-package.sh`
2. `bash v2-kmdf-driver/scripts/kmdf-204-from-wsl.sh`
3. Patch `$Want` in `kmdf-204-scroll-sign.ps1` to the new unsigned SHA
4. Queue `kmdf-204-scroll-sign.ps1` then `kmdf-204-pnputil-once.ps1` (deletes unique oem50 only, add-driver, restart, **sleep 3s**, `mm-f1-once.ps1`)
5. Confirm HIDClass Started, `SdpPatchSuccess=1`, `LastOutHdr=83`, 1-finger no wheel, 2-finger wheel, `0x90` percent

Do not pnputil a length-rewrite SDP. Do not bind PATH-A. Do not ship `MM_SCROLL_STEP 224` (live 0323 produced zero wheel).

## Product: two-finger wheel (user-confirmed)

Linux/Mac Magic Mouse is 1-finger scroll. User wanted **1-finger must not scroll**. That is the Windows PTP contact-count rule, implemented as HID Wheel (not a digitizer).

| | |
|--|--|
| 1-finger START/DRAG | anchors only; Wheel/AC Pan **0** (`down < 2`) |
| 2+ START/DRAG | detent `MM_SCROLL_STEP` **8** (`SCROLL_STEP_8`) |
| Compact 8-byte `0x12` | do not copy native `[6]/[7]` |
| `MM_SCROLL_STEP 224` | **fail** on this glass — do not reload |

Host: `test_scroll_threshold.py` — 1-slot DRAG wheel 0; 2-slot wheel ≠ 0. `gate_4.py` requires `SCROLL_STEP_8` **and** `TWO_FINGER` in `GestureEngine.c`.

MT after reinstall: overlay Feature `0xF1` is not enough. Userspace `HidD_SetFeature([F1,02,01])` on COL01 makes HidBth send `0x53` size 4 (`LastOutHdr=83`). Third-party ACL OUT 66-byte F1 stays `0xC0000206` — ignore. Copy `mm-f1-once.ps1` lives at `C:\mm-dev-queue\mm-f1-once.ps1`.

## Gestures (not this package)

hidclass sees a **mouse with wheel+tilt**, not a Precision Touchpad. Swipe-desktops / pinch / Mission Control **cannot** go in the 135-byte SDP overlay (grow = 0x50).

| Path | What you get | Cost |
|------|----------------|------|
| **A. Virtual PTP PDO** | Real Windows precision gestures | New signed HID, two devices, cursor-fight risk. Only real OS-gesture path. Scratch already has 14+8×N. |
| **B. Tray SendInput** | Fake 2-finger → Win+Ctrl+←/→ | Not OS gestures. Easy. |
| **C. Don’t** | Mouse + 2-finger wheel only | **Current.** |

Linux trackpad gestures are `ABS_MT_*` + libinput on **trackpad PIDs**, not Magic Mouse.

## Future v1 (0x030D) / v2 (0x0269)

Same filter, **`PidInfo` table**: HardwareId, RID (v1 `0x29` 6+8N, Mouse2 `0x12` 8 or 14+8N), SDP prefix+overlay **or skip**, MT feature (v1 `D7 01`, Mouse2 `F1 02 01`), battery RID. New INF HardwareId per PID. **Never** memcpy the 0323 `25 87` blob onto v1/v2. Never PATH-A. No dump → no bind.

## Peer-review

- `.ai/peer-reviews/2026-09-01-prd-188-sdp-overlay.yaml` — 135-byte overlay (ExpertHid Count-2).
- `.ai/peer-reviews/2026-09-01-scroll-threshold.yaml` — ExpertHid-2 APPROVE Linux 224 / no TWO_FINGER; ExpertSec CHANGES-NEEDED TWO_FINGER-in-gate. **Overruled by user:** 224 zeroed wheel; 1-finger still scrolled; shipped TWO_FINGER + detent 8. User: it's working.

