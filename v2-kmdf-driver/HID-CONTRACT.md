# HID contract — 2.0.4 scroll (PID 0323)

Authoritative live probe: **2026-08-30 21:23 MDT** on Apr 30 MagicMouseFix
`MagicMouseDriver.sys` SHA256 `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B`
(pointer works, no wheel). Stack is already `HidBth / MagicMouseDriver / BthEnum`.

## Must keep (Apr 30 pointer)

| Item | Value |
|------|--------|
| COL01 report | Input **0x12** |
| Pointer X | Generic Desktop **0x0030** on report 0x12 |
| Pointer Y | Generic Desktop **0x0031** on report 0x12 |
| Optical fields | `[0x12][buttons][X i16 LE][Y i16 LE]` — same offsets as native / Linux MOUSE2 |
| Battery | HID Input **0x90** on **COL02** (`HidD_GetInputReport`; percent at `buf[2]`) |

Do **not** replace X/Y with Wheel. Do **not** convert 0x12 → RID 0x02.

## Must add (scroll)

| Item | Value |
|------|--------|
| Wheel | Generic Desktop **0x0038** on the **same** 0x12 collection, **after** X/Y |
| AC Pan | Consumer **0x0238** on the same 0x12 collection |

Report after injection (8 bytes):

```
[0] RID 0x12
[1] buttons
[2..3] X INT16 LE     — kept
[4..5] Y INT16 LE     — kept
[6] AC Pan INT8       — extra
[7] Wheel INT8        — extra (0x0038)
```

## Must not use

| Item | Why |
|------|-----|
| Feature **0x47** | Fails on COL01 and COL02 on the live Apr 30 stack |
| RID **0x02** / Descriptor C | hidclass never bound that on this PC |
| PATH-A `applewirelessmouse.sys` | SHIPBLOCKER BSOD 0xD1 |

## Event 41 hunch (not fact)

Kernel-Power Event 41 after the 2.0.4 install
`845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3` may have been:

1. **In-place oem26 overwrite** — same INF identity as `magicmousedriver.inf_amd64_79beb68f1da25da4` so System32 `MagicMouseDriver.sys` was a hardlink; unsigned `pr3-activate-204` then the signed install wrote through that link.
2. **DriverEntry / PnP / ACL grow** in that binary — rewriting a 6-byte native 0x12 to 8 bytes without a proven ACL buffer capacity is a bugcheck candidate.

This tree keeps the 0x12 X/Y usages, adds Wheel as extra, and **refuses to write past the ACL buffer**. If capacity is only 6 bytes, native X/Y is left intact (pointer-safe).

## Hardware-proven 2026-09-01

Proven on hardware with the 2.0.4.1 build: 2-finger Wheel/AC Pan; 1-finger does not scroll (`TWO_FINGER` / `down < 2`). Detent `MM_SCROLL_STEP` **8** (224 zeroed wheel on this glass; the default is **16** in source since 2026-09-16). Battery `0x90`. Overlay 135-byte memcpy. HidBth IN capacity 9; scratch then 8-byte `0x12` back. After bind, `HidD_SetFeature(F1)` so HidBth sends 4-byte `0x53`. Not a Precision Touchpad. Do not grow this overlay for PTP.

## Hi-res scroll — two descriptors, both 0x87 (issue #48)

One HID Wheel unit is `WHEEL_DELTA` = 120 to hidclass, so classic mode can only scroll in whole
lines. The fix is the HID **Resolution Multiplier**, not a second wheel axis and not PTP.

| Item | Value |
|------|--------|
| Classic descriptor | `g_HidDescriptor[]`, **135 bytes (0x87)** |
| Hi-res descriptor | `g_HidDescriptorHiRes[]`, **also exactly 135 bytes (0x87)** — `C_ASSERT(sizeof(g_HidDescriptorHiRes) == sizeof(g_HidDescriptor))` |
| Selector | `Parameters!HiResScroll` (REG_DWORD, any non-zero = on, **default 0**), read once in `EvtDeviceAdd`, passed to `SdpRewrite_Process` as `HiRes` |
| Multiplier item | Generic Desktop **0x48** (Resolution Multiplier), Logical Minimum **1**, Logical Maximum **4**, **no Physical Minimum / Maximum** — the multiplier *is* the logical value, range 1..4 |
| Where it lives | Feature on report **0xF1**, inside a `Collection (Logical)` (`0xA1,0x02`) that also contains **AC Pan and Wheel** |
| Feature items | `0xB1,0x02` (Data,Var,Abs → `0xF1` byte 0) then `0xB1,0x03` (Constant → `0xF1` byte 1) |
| Report 0xF1 size | **still 2 bytes**, so `HidD_SetFeature(F1)` from `scripts/mm-f1-once.ps1` keeps working |
| Report 0x12 wire layout | **identical in both descriptors** — the 8-byte table above is unchanged; AC Pan is still byte 6, Wheel still byte 7, still Report Count 1, still after X/Y |
| COL02 | Battery Input `0x90` semantics unchanged |

`SdpRewrite_Process` checks **both** `g_HidDescriptorSize` and `g_HidDescriptorHiResSize` against
`SDP_HID_OVERLAY_LEN` (`0x87`) and copies `SDP_HID_OVERLAY_LEN` bytes either way. The SDP length
stores are **never** a function of `HiRes`: same 11-byte prefix `09 02 06 35 8D 35 8B 08 22 25 87`,
no writes to `0x35` / `0x36` / `0x25` / `buf[4]`.

### Must not — host `SET_REPORT(Feature, 0xF1)` with any payload but `02 01`

Report `0xF1` is Apple's **multitouch enable** (`53 F1 02 01` on the Bluetooth control channel,
Linux `feature_mt_mouse2`). Windows sets the Resolution Multiplier with
`SET_REPORT(Feature, 0xF1)` and builds its own payload, which is not `02 01`. If that payload
reached the mouse it would drop the device back to compact 9-byte mode and surface scroll would
die. `Driver.c` therefore repairs it **in place** on the outbound control channel: when
`ctx->HiResScroll` is set and an outbound buffer of `>= 4` bytes starts `0x53 0xF1` with bytes
2/3 that are **not** already `02 01`, it records the multiplier the host asked for (`origBuf[2]`,
clamped to `1..MM_HIRES_MULTIPLIER`, 0 treated as 1) in `ctx->HostMultiplier`, then writes
`origBuf[2] = 0x02; origBuf[3] = 0x01;` and increments `ctx->F1PayloadForced` (published to
`Diag!F1PayloadForced`). The capture is the only record of the host's multiplier, since the
repair overwrites the byte. An `02 01` payload is left alone and is **not** read as "multiplier
2": on this shared report ID it is indistinguishable from an MT-enable write, so
`ctx->HostMultiplier` stays 1 and the detent keeps the classic feel — the safe direction.
`MmSendMtEnable` is untouched and still spells `53 F1 02 01` literally.

### Why the multiplier shares 0xF1 instead of taking its own report ID

A new Feature report ID would be a report the mouse does not have. HidBth would put it on the
Bluetooth control channel, the device would HANDSHAKE-reject it, the SET would fail, and the
multiplier would stay **1** — no hi-res scroll, silently. `0xF1` is a Feature report this hardware
demonstrably accepts, so Windows gets a real success handshake.

### Byte budget — why this is still a same-size overlay

The `Collection (Logical)` wrapper and the multiplier items were paid for by:

1. dropping the vendor `Usage Page (0xFF00)` / `Usage (0x01)` pair before `0x85 0xF1`;
2. omitting Physical Minimum / Maximum on the multiplier (8 bytes);
3. deleting a duplicate `Logical Minimum (0)` in COL02 before `0x26, 0xFF, 0x00`.

That is what keeps the overlay 0x87 in both modes, which keeps the `0x50 SdpWalkStream` bugcheck
class (INCIDENT / `tests/test_bsod_regress.py`) out of scope. **Do not grow either descriptor.**

### Sensitivity — the detent follows the multiplier the host actually armed

`MM_HIRES_MULTIPLIER` (4) is only the descriptor's Logical Maximum: it is the largest multiplier
the host may ask for, not the one in force. The host applies its own multiplier to every unit it
receives, so the driver divides the detent by `ctx->HostMultiplier` — the value Windows requested
in the last `SET_REPORT(Feature, 0xF1)`, captured from `origBuf[2]` before the payload repair and
clamped to `1..MM_HIRES_MULTIPLIER`. It is **1 until Windows actually arms the multiplier**, so
hi-res then feels exactly like classic rather than scrolling 4× too fast; dividing by a constant
4 while the host still delivers 120 per unit is precisely that bug.

With `ScrollStep` 16 and an armed multiplier of 4 the detent is 4 touch units and each unit is
`120 / 4 = 30`: gain is `1/4 × 30 = 7.5` per touch unit, the same as classic's `1/16 × 120`. The
division is **nearest-rounded** (`(step + m/2) / m`, floor 1), so gain is exact when `ScrollStep`
is a multiple of the armed multiplier and off by the rounding otherwise — e.g. `ScrollStep` 18 at
multiplier 4 gives detent 5, i.e. 24 per touch unit against classic's 120/18 = 6.67.

Beyond that, hi-res and classic are **not** equal in general, deliberately. Classic emits at most
one unit per report and re-anchors to the current position, so sub-detent and super-detent travel
is thrown away; `DetentUnits` in hi-res mode returns `travel / step` and consumes only
`units * step`, so the remainder is carried. Units are additionally capped per report against the
`±127` the INT8 wheel fields can carry, with `consumed` recomputed from the capped units, so a
saturating report leaves the surplus in the anchor instead of discarding it. The contract is
therefore: **gain matched to the multiplier the host armed, exact when `ScrollStep` is a multiple
of it, finer steps once it is armed, and no discarded sub-detent, super-detent or saturated
travel** — never "identical feel" or "same total scroll" unqualified. A fast flick is the extreme
case, where classic collapses the whole gesture into one 120 notch, so a tester may perceive
hi-res as slightly faster on flicks. `ScrollStep` is still the sensitivity knob if the old
behaviour is wanted back.
