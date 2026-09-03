#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host-side 0323 2/3-finger click + surface-scroll still from touch delta.

No live mouse. Ports GestureEngine.c TranslateMouse2ToHid for this tree
(any-finger scroll, MM_SCROLL_STEP 64) plus mechanical contact-count remap.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GESTURE = ROOT / "GestureEngine.c"
GESTURE_H = ROOT / "GestureEngine.h"
HID_DESC = ROOT / "HidDescriptor.c"

MM2_HEADER_LEN = 14
MM2_COMPACT_LEN = 8
MM2_TOUCH_BYTES = 8
MM_MOUSE_REPORT_LEN = 8
MM_REPORT_ID_MOUSE = 0x12
MM_TOUCH_SLOTS = 16
MM_SCROLL_STEP = 64
TOUCH_STATE_MASK = 0xF0
TOUCH_STATE_NONE = 0x00
TOUCH_STATE_START = 0x30
TOUCH_STATE_DRAG = 0x40
MM_BTN_LEFT = 0x01
MM_BTN_RIGHT = 0x02
MM_BTN_MIDDLE = 0x04
MM2_BTN_MASK = 0x03


def _code(text: str) -> str:
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


def make_mt(touches: list[bytes], buttons: int = 0) -> bytearray:
    buf = bytearray(MM2_HEADER_LEN + MM2_TOUCH_BYTES * len(touches))
    buf[0] = MM_REPORT_ID_MOUSE
    buf[1] = buttons & 0xFF
    for i, t in enumerate(touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        buf[off : off + MM2_TOUCH_BYTES] = t
    return buf


class Ctx:
    def __init__(self) -> None:
        self.TouchAnchorX = [0] * MM_TOUCH_SLOTS
        self.TouchAnchorY = [0] * MM_TOUCH_SLOTS
        self.TouchAnchorValid = [False] * MM_TOUCH_SLOTS
        self.ClickHeld = False
        self.ClickLatched = 0


def accumulate_surface_scroll(inp: bytes, ctx: Ctx) -> tuple[int, int]:
    """Port of AccumulateSurfaceScroll in this tree (any finger, step 64)."""
    out_wheel = 0
    out_hwheel = 0
    if len(inp) < MM2_HEADER_LEN:
        return out_wheel, out_hwheel
    n_touches = (len(inp) - MM2_HEADER_LEN) // MM2_TOUCH_BYTES
    if n_touches == 0:
        return out_wheel, out_hwheel
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
        step_y = ctx.TouchAnchorY[tid] - y
        step_x = ctx.TouchAnchorX[tid] - x
        if step_y >= MM_SCROLL_STEP or step_y <= -MM_SCROLL_STEP:
            out_wheel += 1 if step_y > 0 else -1
            ctx.TouchAnchorY[tid] = y
        if step_x >= MM_SCROLL_STEP or step_x <= -MM_SCROLL_STEP:
            out_hwheel += -1 if step_x > 0 else 1
            ctx.TouchAnchorX[tid] = x
    return out_wheel, out_hwheel


def count_active_touches(inp: bytes) -> int:
    if len(inp) < MM2_HEADER_LEN:
        return 0
    n_touches = (len(inp) - MM2_HEADER_LEN) // MM2_TOUCH_BYTES
    n = 0
    for i in range(n_touches):
        off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES
        if off + MM2_TOUCH_BYTES > len(inp):
            break
        state = inp[off + 7] & TOUCH_STATE_MASK
        if state in (TOUCH_STATE_START, TOUCH_STATE_DRAG):
            n += 1
    return n


def map_contact_count_to_buttons(contacts: int) -> int:
    if contacts >= 3:
        return MM_BTN_MIDDLE
    if contacts == 2:
        return MM_BTN_RIGHT
    if contacts == 1:
        return MM_BTN_LEFT
    return 0


def remap_mechanical_click(
    hw: int,
    contacts: int,
    have_touch: bool,
    scrolled: bool,
    ctx: Ctx,
) -> int:
    mech = (hw & MM_BTN_LEFT) != 0
    if not have_touch:
        if ctx.ClickHeld and mech:
            return ctx.ClickLatched
        ctx.ClickHeld = False
        ctx.ClickLatched = 0
        return hw & MM2_BTN_MASK
    if not mech:
        ctx.ClickHeld = False
        ctx.ClickLatched = 0
        return 0
    if not ctx.ClickHeld:
        ctx.ClickHeld = True
        if scrolled:
            ctx.ClickLatched = 0
        elif contacts == 0:
            ctx.ClickLatched = hw & MM2_BTN_MASK
        else:
            ctx.ClickLatched = map_contact_count_to_buttons(contacts)
    return ctx.ClickLatched


def translate_mouse2_to_hid(inp: bytes, ctx: Ctx) -> bytes:
    n = len(inp)
    wheel = 0
    hwheel = 0
    if n >= MM2_HEADER_LEN:
        wheel, hwheel = accumulate_surface_scroll(inp, ctx)
    elif n >= 8:
        hwheel = inp[6] if inp[6] < 128 else inp[6] - 256
        wheel = inp[7] if inp[7] < 128 else inp[7] - 256
    have_touch = n >= MM2_HEADER_LEN
    contacts = count_active_touches(inp) if have_touch else 0
    scrolled = wheel != 0 or hwheel != 0
    buttons = remap_mechanical_click(
        inp[1] & MM2_BTN_MASK if n >= 2 else 0,
        contacts,
        have_touch,
        scrolled,
        ctx,
    )
    out = bytearray(MM_MOUSE_REPORT_LEN)
    out[0] = MM_REPORT_ID_MOUSE
    out[1] = buttons
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

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            print(f"FAIL {name} {detail}".rstrip())
            self.failed.append(name)


def _i8(b: int) -> int:
    return b - 256 if b >= 128 else b


def test_c_source(run: _Run) -> None:
    if not GESTURE.is_file():
        run.check("GestureEngine.c exists", False)
        return
    src = _code(GESTURE.read_text(encoding="utf-8"))
    hdr = _code(GESTURE_H.read_text(encoding="utf-8")) if GESTURE_H.is_file() else ""
    hid = _code(HID_DESC.read_text(encoding="utf-8")) if HID_DESC.is_file() else ""
    run.check("AccumulateSurfaceScroll still called", "AccumulateSurfaceScroll" in src)
    run.check("MM_SCROLL_STEP present", "MM_SCROLL_STEP" in src or "MM_SCROLL_STEP" in hdr)
    run.check("CountActiveTouches present", "CountActiveTouches" in src)
    run.check("MapContactCountToButtons present", "MapContactCountToButtons" in src)
    run.check("RemapMechanicalClick present", "RemapMechanicalClick" in src)
    run.check("MM_BTN_RIGHT in header", "MM_BTN_RIGHT" in hdr)
    run.check("MM_BTN_MIDDLE in header", "MM_BTN_MIDDLE" in hdr)
    run.check("no GPL emit_buttons", "magicmouse_emit_buttons" not in src)
    run.check("no GPL firm_touch", "magicmouse_firm_touch" not in src)
    run.check("no GPL middle_button_start", "middle_button_start" not in src)
    run.check(
        "descriptor Button 3 same length",
        "0x29, 0x03" in hid.replace(" ", "") or "0x29,0x03" in hid.replace(" ", ""),
    )
    run.check(
        "descriptor report count 3",
        "0x95, 0x03" in hid.replace(" ", "") or "0x95,0x03" in hid.replace(" ", ""),
    )


def test_one_finger_click_left(run: _Run) -> None:
    ctx = Ctx()
    inp = make_mt([pack_touch(0, 0, 1, TOUCH_STATE_START)], buttons=1)
    out = translate_mouse2_to_hid(inp, ctx)
    run.check(
        "1-finger mechanical → left, no wheel",
        out[1] == MM_BTN_LEFT and out[7] == 0 and out[6] == 0,
        f"btn={out[1]:#x} wheel={out[7]} pan={out[6]}",
    )


def test_two_finger_click_right(run: _Run) -> None:
    ctx = Ctx()
    inp = make_mt(
        [
            pack_touch(0, 0, 1, TOUCH_STATE_START),
            pack_touch(10, 0, 2, TOUCH_STATE_START),
        ],
        buttons=1,
    )
    out = translate_mouse2_to_hid(inp, ctx)
    run.check(
        "2-finger mechanical → right, no wheel",
        out[1] == MM_BTN_RIGHT and out[7] == 0,
        f"btn={out[1]:#x} wheel={out[7]}",
    )


def test_three_finger_click_middle(run: _Run) -> None:
    ctx = Ctx()
    inp = make_mt(
        [
            pack_touch(0, 0, 1, TOUCH_STATE_START),
            pack_touch(10, 0, 2, TOUCH_STATE_START),
            pack_touch(20, 0, 3, TOUCH_STATE_START),
        ],
        buttons=1,
    )
    out = translate_mouse2_to_hid(inp, ctx)
    run.check(
        "3-finger mechanical → middle",
        out[1] == MM_BTN_MIDDLE and out[7] == 0,
        f"btn={out[1]:#x} wheel={out[7]}",
    )


def test_scroll_drag_not_click(run: _Run) -> None:
    ctx = Ctx()
    start = make_mt(
        [
            pack_touch(0, 0, 1, TOUCH_STATE_START),
            pack_touch(10, 0, 2, TOUCH_STATE_START),
        ],
        buttons=0,
    )
    translate_mouse2_to_hid(start, ctx)
    drag = make_mt(
        [
            pack_touch(0, -MM_SCROLL_STEP, 1, TOUCH_STATE_DRAG),
            pack_touch(10, -MM_SCROLL_STEP, 2, TOUCH_STATE_DRAG),
        ],
        buttons=0,
    )
    out = translate_mouse2_to_hid(drag, ctx)
    run.check(
        "2-finger DRAG mechanical up → wheel, buttons 0",
        out[1] == 0 and _i8(out[7]) != 0,
        f"btn={out[1]:#x} wheel={_i8(out[7])}",
    )


def test_press_during_detent_suppressed(run: _Run) -> None:
    ctx = Ctx()
    start = make_mt(
        [
            pack_touch(0, 0, 1, TOUCH_STATE_START),
            pack_touch(10, 0, 2, TOUCH_STATE_START),
        ],
        buttons=0,
    )
    translate_mouse2_to_hid(start, ctx)
    press = make_mt(
        [
            pack_touch(0, -MM_SCROLL_STEP, 1, TOUCH_STATE_DRAG),
            pack_touch(10, -MM_SCROLL_STEP, 2, TOUCH_STATE_DRAG),
        ],
        buttons=1,
    )
    out = translate_mouse2_to_hid(press, ctx)
    run.check(
        "press on detent report → buttons 0, wheel kept",
        out[1] == 0 and _i8(out[7]) != 0,
        f"btn={out[1]:#x} wheel={_i8(out[7])}",
    )


def test_latch_holds_right(run: _Run) -> None:
    ctx = Ctx()
    press = make_mt(
        [
            pack_touch(0, 0, 1, TOUCH_STATE_START),
            pack_touch(10, 0, 2, TOUCH_STATE_START),
        ],
        buttons=1,
    )
    out1 = translate_mouse2_to_hid(press, ctx)
    held = make_mt(
        [
            pack_touch(0, 0, 1, TOUCH_STATE_DRAG),
            pack_touch(10, 0, 2, TOUCH_STATE_NONE),
        ],
        buttons=1,
    )
    out2 = translate_mouse2_to_hid(held, ctx)
    run.check(
        "latch: 2-finger press then one NONE still right",
        out1[1] == MM_BTN_RIGHT and out2[1] == MM_BTN_RIGHT,
        f"press={out1[1]:#x} held={out2[1]:#x}",
    )


def test_compact_hardware_left(run: _Run) -> None:
    ctx = Ctx()
    inp = bytearray(MM2_COMPACT_LEN)
    inp[0] = MM_REPORT_ID_MOUSE
    inp[1] = 1
    out = translate_mouse2_to_hid(bytes(inp), ctx)
    run.check(
        "compact mechanical → hardware left",
        out[1] == MM_BTN_LEFT,
        f"btn={out[1]:#x}",
    )


def test_one_finger_drag_still_scrolls(run: _Run) -> None:
    """This tree has no TWO_FINGER gate; 1-finger DRAG of step 64 must wheel."""
    ctx = Ctx()
    start = make_mt([pack_touch(0, 0, 1, TOUCH_STATE_START)], buttons=0)
    translate_mouse2_to_hid(start, ctx)
    drag = make_mt(
        [pack_touch(0, -MM_SCROLL_STEP, 1, TOUCH_STATE_DRAG)],
        buttons=0,
    )
    out = translate_mouse2_to_hid(drag, ctx)
    run.check(
        "1-finger DRAG step 64 → wheel (scroll path unchanged)",
        out[1] == 0 and _i8(out[7]) != 0,
        f"btn={out[1]:#x} wheel={_i8(out[7])}",
    )


def main() -> int:
    run = _Run()
    test_c_source(run)
    test_one_finger_click_left(run)
    test_two_finger_click_right(run)
    test_three_finger_click_middle(run)
    test_scroll_drag_not_click(run)
    test_press_during_detent_suppressed(run)
    test_latch_holds_right(run)
    test_compact_hardware_left(run)
    test_one_finger_drag_still_scrolls(run)
    if run.failed:
        print(f"{len(run.failed)} failed: {', '.join(run.failed)}")
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
