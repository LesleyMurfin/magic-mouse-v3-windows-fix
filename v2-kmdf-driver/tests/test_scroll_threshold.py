#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Linux mouse detent vs GestureEngine.c.

Host model of AccumulateSurfaceScroll + TranslateMouse2ToHid.
Token SCROLL_STEP_8 must sit next to the detent in GestureEngine.c.
MM_SCROLL_STEP is 8 (live 0323; Linux 224 produced zero wheel).
SCROLL_HR_THRESHOLD 90 is documentation only.

1-finger START/DRAG MAY emit wheel once |step| >= 8.
down < 2 must not gate Wheel (TWO_FINGER is trackpad/PTP-only).
Compact 8-byte 0x12 must not copy native in[6]/in[7].
No WDK. No .sys load.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GESTURE = ROOT / "GestureEngine.c"
GESTURE_H = ROOT / "GestureEngine.h"

MM2_HEADER_LEN = 14
MM2_COMPACT_LEN = 8
MM2_TOUCH_BYTES = 8
MM_MOUSE_REPORT_LEN = 8
MM_REPORT_ID_MOUSE = 0x12
MM_TOUCH_SLOTS = 16
MM_SCROLL_STEP = 8
SCROLL_HR_THRESHOLD = 90
TOUCH_STATE_MASK = 0xF0
TOUCH_STATE_START = 0x30
TOUCH_STATE_DRAG = 0x40


def _code(text: str) -> str:
    """Strip // and /* */ so comments cannot green behavioral C checks."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def _i32(u: int) -> int:
    u &= 0xFFFFFFFF
    return u - 0x100000000 if u >= 0x80000000 else u


def _clamp_i8(value: int) -> int:
    if value > 127:
        return 127
    if value < -127:
        return -127
    return value


def _read_i12le(t0: int, t1: int) -> int:
    return _i32((t1 << 28) | (t0 << 20)) >> 20


def _read_y(t1: int, t2: int) -> int:
    return -(_i32((t2 << 24) | (t1 << 16)) >> 20)


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
    def __init__(self) -> None:
        self.TouchAnchorX = [0] * MM_TOUCH_SLOTS
        self.TouchAnchorY = [0] * MM_TOUCH_SLOTS
        self.TouchAnchorValid = [False] * MM_TOUCH_SLOTS


def accumulate_surface_scroll(inp: bytes, ctx: Ctx) -> tuple[int, int]:
    """Port of AccumulateSurfaceScroll: TWO_FINGER + step 8."""
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
    for i in range(n_touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        if off + MM2_TOUCH_BYTES > len(inp):
            break
        t = inp[off : off + MM2_TOUCH_BYTES]
        tid = ((t[6] << 2) | (t[5] >> 6)) & 0xF
        if tid >= MM_TOUCH_SLOTS:
            continue
        x = _read_i12le(t[0], t[1])
        y = _read_y(t[1], t[2])
        state = t[7] & TOUCH_STATE_MASK
        if state == TOUCH_STATE_START:
            ctx.TouchAnchorX[tid] = x
            ctx.TouchAnchorY[tid] = y
            ctx.TouchAnchorValid[tid] = True
            continue
        if state != TOUCH_STATE_DRAG or not ctx.TouchAnchorValid[tid]:
            if state == 0x00:
                ctx.TouchAnchorValid[tid] = False
            continue
        if down < 2:
            continue
        step_y = ctx.TouchAnchorY[tid] - y
        step_x = ctx.TouchAnchorX[tid] - x
        if step_y >= MM_SCROLL_STEP or step_y <= -MM_SCROLL_STEP:
            out_wheel += 1 if step_y > 0 else -1
            ctx.TouchAnchorY[tid] = y
        if step_x >= MM_SCROLL_STEP or step_x <= -MM_SCROLL_STEP:
            out_hwheel += -1 if step_x > 0 else 1
            ctx.TouchAnchorX[tid] = x
    return out_wheel, out_hwheel


def translate_mouse2_to_hid(inp: bytes, ctx: Ctx) -> bytes:
    """Compact 8-byte 0x12 does not copy native in[6]/in[7]."""
    n = len(inp)
    wheel = 0
    hwheel = 0
    if n >= MM2_HEADER_LEN:
        wheel, hwheel = accumulate_surface_scroll(inp, ctx)
    out = bytearray(MM_MOUSE_REPORT_LEN)
    out[0] = MM_REPORT_ID_MOUSE
    if n >= 2:
        out[1] = inp[1] & 0x03
    if n >= 4:
        out[2:4] = inp[2:4]
    if n >= 6:
        out[4:6] = inp[4:6]
    out[6] = _clamp_i8(hwheel) & 0xFF
    out[7] = _clamp_i8(wheel) & 0xFF
    return bytes(out)


class _Run:
    def __init__(self) -> None:
        self.failed: list[str] = []

    def check(self, name: str, ok: bool, msg: str) -> None:
        if ok:
            print(f"PASS: {name}: {msg}")
        else:
            print(f"FAIL: {name}: {msg}")
            self.failed.append(name)


def _i8(b: int) -> int:
    return b - 256 if b >= 128 else b


def one_slot_drag(step_y: int) -> tuple[bytes, int]:
    """14+8 one-slot DRAG with pre-seeded anchor at (0,0). stepY = -y."""
    ctx = Ctx()
    ctx.TouchAnchorValid[0] = True
    ctx.TouchAnchorX[0] = 0
    ctx.TouchAnchorY[0] = 0
    drag = pack_touch(0, -step_y, 0, TOUCH_STATE_DRAG)
    inp = make_mt([drag])
    return translate_mouse2_to_hid(inp, ctx), len(inp)


def test_c_source(run: _Run) -> None:
    if not GESTURE.is_file():
        run.check("SCROLL_STEP_8", False, f"missing {GESTURE}")
        run.check("NO_DOWN_LT_2", False, f"missing {GESTURE}")
        run.check("COMPACT_NO_NATIVE_WHEEL", False, f"missing {GESTURE}")
        return
    raw = GESTURE.read_text(encoding="utf-8")
    code = _code(raw)
    has_token = "SCROLL_STEP_8" in raw
    run.check(
        "SCROLL_STEP_8",
        has_token,
        "GestureEngine.c SCROLL_STEP_8 next to the detent"
        if has_token
        else "GestureEngine.c missing SCROLL_STEP_8 next to the detent",
    )
    has_down = re.search(r"down\s*<\s*2", code) is not None
    run.check(
        "DOWN_LT_2",
        has_down,
        "AccumulateSurfaceScroll gates wheel on down < 2"
        if has_down
        else "GestureEngine.c missing down < 2 (1-finger must not emit Wheel)",
    )
    has_tf = "TWO_FINGER" in raw
    run.check(
        "TWO_FINGER",
        has_tf,
        "GestureEngine.c TWO_FINGER token present"
        if has_tf
        else "GestureEngine.c missing TWO_FINGER",
    )
    copies_native = (
        re.search(r"in\s*\[\s*6\s*\]", code) is not None
        and re.search(r"in\s*\[\s*7\s*\]", code) is not None
    )
    run.check(
        "COMPACT_NO_NATIVE_WHEEL",
        not copies_native,
        "compact 8-byte 0x12 does not copy in[6]/in[7] into wheel"
        if not copies_native
        else "compact 8-byte path assigns in[6]/in[7] into wheel/hwheel (must leave 0)",
    )

    if not GESTURE_H.is_file():
        run.check("MM_SCROLL_STEP_8", False, f"missing {GESTURE_H}")
        run.check("SCROLL_HR_THRESHOLD_90", False, f"missing {GESTURE_H}")
        return
    hdr = GESTURE_H.read_text(encoding="utf-8")
    has_step = re.search(r"#define\s+MM_SCROLL_STEP\s+8\b", hdr) is not None
    run.check(
        "MM_SCROLL_STEP_8",
        has_step,
        "GestureEngine.h MM_SCROLL_STEP 8 (live 0323 detent)"
        if has_step
        else "GestureEngine.h missing #define MM_SCROLL_STEP 8",
    )
    has_hr = re.search(r"#define\s+SCROLL_HR_THRESHOLD\s+90\b", hdr) is not None
    run.check(
        "SCROLL_HR_THRESHOLD_90",
        has_hr,
        "GestureEngine.h SCROLL_HR_THRESHOLD 90 (HR-only; redundant on 8-bit Wheel)"
        if has_hr
        else "GestureEngine.h missing #define SCROLL_HR_THRESHOLD 90",
    )


def test_one_slot_drag_thresholds(run: _Run) -> None:
    """14+8 one-slot DRAG must not emit wheel (1-finger)."""
    cases = (7, 8, 20, -20)
    for step in cases:
        out, n = one_slot_drag(step)
        wheel = _i8(out[7])
        hwheel = _i8(out[6])
        ok = n == MM2_HEADER_LEN + MM2_TOUCH_BYTES and wheel == 0 and hwheel == 0
        run.check(
            f"ONE_SLOT_DRAG_{step}",
            ok,
            f"14+8 one-slot DRAG |stepY|={step} wheel=0"
            if ok
            else f"1-finger still emitted wheel={wheel} hwheel={hwheel} step={step}",
        )


def two_slot_drag(step_y: int) -> tuple[bytes, int]:
    ctx = Ctx()
    ctx.TouchAnchorValid[0] = True
    ctx.TouchAnchorValid[1] = True
    ctx.TouchAnchorX[0] = 0
    ctx.TouchAnchorY[0] = 0
    ctx.TouchAnchorX[1] = 10
    ctx.TouchAnchorY[1] = 0
    drag0 = pack_touch(0, -step_y, 0, TOUCH_STATE_DRAG)
    drag1 = pack_touch(10, -step_y, 1, TOUCH_STATE_DRAG)
    inp = make_mt([drag0, drag1])
    return translate_mouse2_to_hid(inp, ctx), len(inp)


def test_two_finger_emits(run: _Run) -> None:
    out, n = two_slot_drag(MM_SCROLL_STEP)
    wheel = _i8(out[7])
    ok = n == MM2_HEADER_LEN + 2 * MM2_TOUCH_BYTES and wheel != 0
    run.check(
        "TWO_FINGER_STEP_NONZERO",
        ok,
        "14+16 two-slot DRAG wheel non-zero"
        if ok
        else f"2-finger step={MM_SCROLL_STEP} wheel={wheel} len={n}",
    )


def test_compact_garbage_no_wheel(run: _Run) -> None:
    """Compact 8-byte 0x12 with garbage at [6]/[7] → wheel/hwheel 0."""
    inp = bytearray(MM2_COMPACT_LEN)
    inp[0] = MM_REPORT_ID_MOUSE
    inp[6] = 0x7F
    inp[7] = 0x81
    out = translate_mouse2_to_hid(bytes(inp), Ctx())
    wheel = _i8(out[7])
    hwheel = _i8(out[6])
    ok = len(out) == MM_MOUSE_REPORT_LEN and wheel == 0 and hwheel == 0
    run.check(
        "COMPACT_GARBAGE_NO_WHEEL",
        ok,
        "compact 8-byte 0x12 garbage [6]/[7] → wheel/hwheel 0"
        if ok
        else f"compact copied garbage wheel={wheel} hwheel={hwheel} (must leave 0)",
    )


def main() -> int:
    run = _Run()
    test_c_source(run)
    test_one_slot_drag_thresholds(run)
    test_two_finger_emits(run)
    test_compact_garbage_no_wheel(run)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
