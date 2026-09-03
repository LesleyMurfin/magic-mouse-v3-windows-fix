# DESIGN — 0323 2/3-finger click (MU-parity, no tap)

Status: Implement in `GestureEngine.c` / `.h`. Surface scroll stays the existing 0323 touch-delta path.

Magic Mouse 2024 (`PID 0x0323`) has one mechanical switch under the whole glass. Firmware reports that switch in MOUSE2 `data[1]` bit 0. The 14+8×N touch block (already parsed for Wheel / AC Pan) says how many fingers are down. Magic Utilities maps that count to extra buttons. This vertical does the same two rows only: **2-finger click = right**, **3-finger click = middle**. It does not copy Linux `emulate_3button` (that is X-position of one firm touch, GPL). It does not synthesize a click from finger down/up. 1-finger tap is a non-goal — the mouse already has a button.

## Linux numeric facts (no GPL)

`drivers/hid/hid-magicmouse.c` layout only:

| Item | Value |
| --- | --- |
| MOUSE2 report ID | `0x12` |
| Compact report | 8 bytes (no touch) |
| Full header | 14 bytes, then `8 * N` touch records |
| Hardware buttons | `data[1]` (bit 0 mechanical / left) |
| Touch id | `(tdata[6] << 2 \| tdata[5] >> 6) & 0xF` |
| Touch x | signed 12-bit: `(tdata[1] << 28 \| tdata[0] << 20) >> 20` |
| Touch y | `-((tdata[2] << 24 \| tdata[1] << 16) >> 20)` |
| Touch state | `tdata[7] & 0xF0` |
| NONE / START / DRAG | `0x00` / `0x30` / `0x40` |
| Touch size (unused here) | `tdata[5] & 0x3F` |

Linux middle-click is `x` vs ±350 on a single firm contact (`size >= 8`). **Do not port that.** Contact count is the MU-parity map.

## Contact-count → button

Active contact = a touch record whose state is START or DRAG. NONE is up. Same slots `AccumulateSurfaceScroll` already walks (`id < 16`).

| Active contacts at mechanical **press edge** | Output `out[1]` |
| --- | --- |
| no touch block (compact / short header) | hardware `data[1] & 0x03` |
| 0 (all NONE) with mechanical down | hardware `data[1] & 0x03` |
| 1 | Left (`0x01`) |
| 2 | Right (`0x02`) |
| 3 or more | Middle (`0x04`) |

Output is **exactly one** button, not OR'd with firmware left. A 2-finger click is right only.

## Finger-down / up so scroll drag is not a click

1. **Touch never synthesizes a button.** START, DRAG, and NONE do not set `out[1]`. Only the mechanical bit (`data[1] & 0x01`) does. A 1- or 2-finger surface drag with the switch up stays buttons = 0 and still produces Wheel / AC Pan from touch delta.
2. **Latch on 0→1, hold until 1→0.** Contact count is sampled on the mechanical press edge and stored in `DEVICE_CONTEXT` (`ClickHeld`, `ClickLatched`). A finger lifting mid-click does not switch right → left. Release clears the latch.
3. **Press edge during a detent is not a click.** If the same report already produced Wheel or AC Pan, latch 0 for that press. Scroll-then-bottom-out must not emit right/middle. Tiny motion below `MM_SCROLL_STEP` still clicks.
4. **Compact reports mid-press keep the latch** if mechanical is still down (no new count). Mechanical up on compact clears.

Scroll path is unchanged: `AccumulateSurfaceScroll` still fills Wheel / AC Pan from START anchors and DRAG steps. Click remap runs **after** that, under its own lock acquire (WDF spinlocks are not recursive).

## HID report / descriptor

Output stays 8-byte RID `0x12`: `[12][buttons][X i16][Y i16][AC Pan][Wheel]`.

COL01 currently advertises Button 1–2 and pads 6 constant bits. Bit 2 would be ignored. Same-length patch: Usage Maximum 3, Report Count 3, pad 5 bits. Descriptor **byte count is unchanged**, so SDP overlay size does not grow.

## Files

| File | Role |
| --- | --- |
| `v2-kmdf-driver/DESIGN-mouse-multitouch-click.md` | This design. |
| `v2-kmdf-driver/GestureEngine.c` | Count START/DRAG, latch, remap. Scroll loop untouched. |
| `v2-kmdf-driver/GestureEngine.h` | Button bits including middle. |
| `v2-kmdf-driver/Driver.h` | `ClickHeld` / `ClickLatched` on `DEVICE_CONTEXT`. |
| `v2-kmdf-driver/HidDescriptor.c` | Same-length Button 1–3. |
| `v2-kmdf-driver/tests/test_mouse_multitouch_click.py` | Host-side map + scroll-not-click. No live mouse. |

## Tests

No WDK on Linux. Host Python, no hardware:

- Source: `TranslateMouse2ToHid` still calls `AccumulateSurfaceScroll`; `MM_SCROLL_STEP` present; no `magicmouse_emit_buttons` / `firm_touch` / `middle_button_start`.
- 1-finger mechanical, no drag → left; Wheel 0.
- 2-finger START + mechanical, no detent → right; Wheel 0.
- 3-finger START + mechanical → middle.
- 2-finger DRAG of `MM_SCROLL_STEP` with mechanical **up** → Wheel ±1, buttons 0.
- 2-finger DRAG detent on the **press** report → buttons 0 (suppressed).
- Latch: 2-finger press then one finger NONE, mechanical still down → still right.
- Compact 8-byte `data[1]=1` with no prior latch → left (hardware).

## Non-goals

- 1-finger tap-to-click.
- Linux X-position 3-button emulation.
- Trackpad files, tray C#, MU binaries, PathA, `pnputil`.
- Changing `MM_SCROLL_STEP` or adding a 2-finger-only scroll gate.
- Push. Killing the live tray. Installing on the live PC.
