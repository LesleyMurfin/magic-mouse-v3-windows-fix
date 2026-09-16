#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared host model of GestureEngine.c — imported by the scroll gates.

AccumulateSurfaceScroll + TranslateMouse2ToHid, ported from the shipped C:

  * Wheel / AC Pan only while two or more contacts are down (down >= 2).
    One finger (START or DRAG) never emits, at any step magnitude.
  * Exactly one reference finger — the lowest active DRAG slot with a valid
    anchor — emits notches. Other contacts only re-anchor.
  * While down < 2 an active DRAG anchor is refreshed to the current x/y, so
    one-finger travel never accumulates into a notch when a second finger
    lands: both contacts start the step calculation from current positions.
  * The detent is ctx.ScrollStep, an unsigned (ULONG) registry value: below
    MM_SCROLL_STEP_MIN it falls back to MM_SCROLL_STEP from GestureEngine.h,
    above MM_SCROLL_STEP_MAX it clamps to MM_SCROLL_STEP_MAX. A negative
    REG_DWORD is a huge ULONG, so it clamps to 224 rather than defaulting.
    224 is the clamp ceiling, never the detent.
  * Compact 8-byte 0x12 is shorter than MM2_HEADER_LEN, so it never reaches
    the touch loop: output bytes 6/7 stay 0 and native in[6]/in[7] are not
    copied through.
  * TranslateMouse2ToHid front gate: a report is REJECTED (outLen 0, no
    output bytes, no anchor mutation) unless in/ctx are non-NULL, inLen >= 6,
    in[0] is 0x12 or 0x27, and the length is compact 8, 14 + 8*N, or a short
    header 6..13. Rejects return an NTSTATUS and an empty payload.

No WDK. No .sys load.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
GESTURE_HEADER = ROOT / "GestureEngine.h"

# Wire format (Linux hid-magicmouse.c MOUSE2): 1 RID + 13 header, 8 per touch.
MM2_HEADER_LEN = 14
MM2_COMPACT_LEN = 8
MM2_TOUCH_BYTES = 8
MM_MOUSE_REPORT_LEN = 8
MM_REPORT_ID_MOUSE = 0x12
MM_TOUCH_SLOTS = 16
TOUCH_STATE_MASK = 0xF0
TOUCH_STATE_START = 0x30
TOUCH_STATE_DRAG = 0x40
TOUCH_STATE_UP = 0x00
MM2_BTN_MASK = 0x03

# NTSTATUS values TranslateMouse2ToHid returns.
STATUS_SUCCESS = 0x00000000
STATUS_INVALID_PARAMETER = 0xC000000D
STATUS_NO_MORE_ENTRIES = 0x8000001A


def c_define(name: str) -> int:
    """Read an integer #define out of GestureEngine.h. Fail closed."""
    src = GESTURE_HEADER.read_text(encoding="utf-8")
    hit = re.search(
        r"^#define\s+" + re.escape(name) + r"\s+(\d+)\s*(?://.*)?$",
        src,
        re.M,
    )
    if hit is None:
        raise SystemExit(
            f"FAIL: {GESTURE_HEADER} has no integer #define {name} "
            "(host model cannot single-source the detent)"
        )
    return int(hit.group(1))


# Single source of the detent: the C header, not a literal in a test.
MM_SCROLL_STEP = c_define("MM_SCROLL_STEP")
MM_SCROLL_STEP_MIN = c_define("MM_SCROLL_STEP_MIN")
MM_SCROLL_STEP_MAX = c_define("MM_SCROLL_STEP_MAX")


def strip_c_comments(text: str) -> str:
    """Strip // and /* */ so comments cannot green behavioral C checks."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def i32(u: int) -> int:
    u &= 0xFFFFFFFF
    return u - 0x100000000 if u >= 0x80000000 else u


def i8(b: int) -> int:
    return b - 256 if b >= 128 else b


def clamp_i8(value: int) -> int:
    if value > 127:
        return 127
    if value < -127:
        return -127
    return value


def read_i12le(t0: int, t1: int) -> int:
    return i32((t1 << 28) | (t0 << 20)) >> 20


def read_y(t1: int, t2: int) -> int:
    return -(i32((t2 << 24) | (t1 << 16)) >> 20)


def pack_touch(x: int, y: int, tid: int, state: int) -> bytes:
    x12 = x & 0xFFF
    y12 = (-y) & 0xFFF
    t = bytearray(MM2_TOUCH_BYTES)
    t[0] = x12 & 0xFF
    t[1] = ((x12 >> 8) & 0x0F) | ((y12 & 0x0F) << 4)
    t[2] = (y12 >> 4) & 0xFF
    t[5] = (tid & 3) << 6
    t[6] = (tid >> 2) & 0xFF
    t[7] = state & TOUCH_STATE_MASK
    return bytes(t)


def make_mt(touches: list[bytes]) -> bytearray:
    buf = bytearray(MM2_HEADER_LEN + MM2_TOUCH_BYTES * len(touches))
    buf[0] = MM_REPORT_ID_MOUSE
    for i, t in enumerate(touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        buf[off : off + MM2_TOUCH_BYTES] = t
    return buf


class Ctx:
    """DEVICE_CONTEXT touch state. ScrollStep is the registry tunable."""

    def __init__(self, scroll_step: int = MM_SCROLL_STEP) -> None:
        self.TouchAnchorX = [0] * MM_TOUCH_SLOTS
        self.TouchAnchorY = [0] * MM_TOUCH_SLOTS
        self.TouchAnchorValid = [False] * MM_TOUCH_SLOTS
        self.ScrollStep = scroll_step


def effective_step(ctx: Ctx) -> int:
    """ctx->ScrollStep clamped exactly as AccumulateSurfaceScroll clamps it.

    `step` is ULONG in the C (DEVICE_CONTEXT.ScrollStep). A negative
    REG_DWORD therefore arrives as a huge unsigned value: it passes the
    `< MM_SCROLL_STEP_MIN` test and is caught by `> MM_SCROLL_STEP_MAX`, so
    it CLAMPS to MM_SCROLL_STEP_MAX and never becomes the default. Only a
    too-low value (0) falls back to MM_SCROLL_STEP.
    """
    step = ctx.ScrollStep & 0xFFFFFFFF
    if step < MM_SCROLL_STEP_MIN:
        step = MM_SCROLL_STEP
    if step > MM_SCROLL_STEP_MAX:
        step = MM_SCROLL_STEP_MAX
    return step


def accumulate_surface_scroll(inp: bytes, ctx: Ctx) -> tuple[int, int]:
    """Port of AccumulateSurfaceScroll: TWO_FINGER, one reference finger."""
    out_wheel = 0
    out_hwheel = 0
    if len(inp) < MM2_HEADER_LEN:
        return out_wheel, out_hwheel
    n_touches = (len(inp) - MM2_HEADER_LEN) // MM2_TOUCH_BYTES
    if n_touches == 0:
        return out_wheel, out_hwheel

    down = 0
    for i in range(n_touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        if off + MM2_TOUCH_BYTES > len(inp):
            break
        st = inp[off + 7] & TOUCH_STATE_MASK
        if st in (TOUCH_STATE_START, TOUCH_STATE_DRAG):
            down += 1

    step = effective_step(ctx)

    # Reference = lowest active DRAG slot with a valid anchor. Only that
    # finger emits, so a two-finger drag is one notch per `step` of travel.
    ref_id = MM_TOUCH_SLOTS
    for i in range(n_touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        if off + MM2_TOUCH_BYTES > len(inp):
            break
        t = inp[off : off + MM2_TOUCH_BYTES]
        tid = ((t[6] << 2) | (t[5] >> 6)) & 0xF
        if tid >= MM_TOUCH_SLOTS:
            continue
        if (t[7] & TOUCH_STATE_MASK) == TOUCH_STATE_DRAG:
            if ctx.TouchAnchorValid[tid] and tid < ref_id:
                ref_id = tid

    for i in range(n_touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        if off + MM2_TOUCH_BYTES > len(inp):
            break
        t = inp[off : off + MM2_TOUCH_BYTES]
        tid = ((t[6] << 2) | (t[5] >> 6)) & 0xF
        if tid >= MM_TOUCH_SLOTS:
            continue
        x = read_i12le(t[0], t[1])
        y = read_y(t[1], t[2])
        state = t[7] & TOUCH_STATE_MASK
        if state == TOUCH_STATE_START:
            ctx.TouchAnchorX[tid] = x
            ctx.TouchAnchorY[tid] = y
            ctx.TouchAnchorValid[tid] = True
            continue
        if state != TOUCH_STATE_DRAG or not ctx.TouchAnchorValid[tid]:
            if state == TOUCH_STATE_UP:
                ctx.TouchAnchorValid[tid] = False
            continue

        # TWO_FINGER: 1-finger START/DRAG must not emit Wheel. Keep the
        # anchor on the current position so the travel done while alone is
        # never banked into a notch once a second finger lands.
        if down < 2:
            ctx.TouchAnchorX[tid] = x
            ctx.TouchAnchorY[tid] = y
            continue

        step_y = ctx.TouchAnchorY[tid] - y
        step_x = ctx.TouchAnchorX[tid] - x
        if step_y >= step or step_y <= -step:
            if tid == ref_id:
                out_wheel += 1 if step_y > 0 else -1
            ctx.TouchAnchorY[tid] = y
        if step_x >= step or step_x <= -step:
            if tid == ref_id:
                out_hwheel += -1 if step_x > 0 else 1
            ctx.TouchAnchorX[tid] = x
    return out_wheel, out_hwheel


class Mouse2Result(NamedTuple):
    """TranslateMouse2ToHid's NTSTATUS plus the *outLen bytes it wrote.

    Every reject path in the C sets `*outLen = 0` first and then returns
    without touching `out` or a single anchor, so `payload` is empty and
    `out_len` is 0 on reject. Callers must not assume a report was produced.
    """

    status: int
    payload: bytes

    @property
    def out_len(self) -> int:
        return len(self.payload)

    @property
    def ok(self) -> bool:
        return self.status == STATUS_SUCCESS


def translate_mouse2_to_hid(inp: bytes | None, ctx: Ctx | None) -> Mouse2Result:
    """Port of TranslateMouse2ToHid, front gate included.

    Rejected reports mutate nothing — not the output, not ctx anchors.
    Compact 8-byte 0x12 is shorter than MM2_HEADER_LEN, so it never reaches
    the touch loop and does not copy native in[6]/in[7].
    """
    # *outLen = 0 happens before every check below.
    if inp is None or ctx is None:
        # The C also rejects out == NULL; this model allocates its own out.
        return Mouse2Result(STATUS_INVALID_PARAMETER, b"")

    n = len(inp)
    if n < 6 or (inp[0] != MM_REPORT_ID_MOUSE and inp[0] != 0x27):
        return Mouse2Result(STATUS_NO_MORE_ENTRIES, b"")

    # Compact (8) or full (14 + 8*N). Still accept >=6 so a short header
    # yields buttons + X/Y rather than a dropped report.
    sized_ok = (
        n == MM2_COMPACT_LEN
        or (n >= MM2_HEADER_LEN and (n - MM2_HEADER_LEN) % MM2_TOUCH_BYTES == 0)
        or (n >= 6 and n < MM2_HEADER_LEN)
    )
    if not sized_ok:
        return Mouse2Result(STATUS_NO_MORE_ENTRIES, b"")

    wheel = 0
    hwheel = 0
    if n >= MM2_HEADER_LEN:
        wheel, hwheel = accumulate_surface_scroll(inp, ctx)

    out = bytearray(MM_MOUSE_REPORT_LEN)
    out[0] = MM_REPORT_ID_MOUSE
    out[1] = inp[1] & MM2_BTN_MASK
    out[2:4] = inp[2:4]
    out[4:6] = inp[4:6]
    out[6] = clamp_i8(hwheel) & 0xFF
    out[7] = clamp_i8(wheel) & 0xFF
    return Mouse2Result(STATUS_SUCCESS, bytes(out))
