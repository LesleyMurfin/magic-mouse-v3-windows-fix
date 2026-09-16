#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Linux mouse detent vs GestureEngine.c.

Host model of AccumulateSurfaceScroll + TranslateMouse2ToHid lives in
hostmodel.py and is shared with test_two_finger_scroll.py; the detent comes
from #define MM_SCROLL_STEP in GestureEngine.h, never from a literal here.
Token SCROLL_STEP_8 must sit next to the detent in GestureEngine.c.
MM_SCROLL_STEP is 8 (live 0323).

The detent is the tunable ScrollStep (REG_DWORD under
Services\\MagicMouseDriver204Scroll\\Parameters), default MM_SCROLL_STEP 8,
clamped to [MM_SCROLL_STEP_MIN 1, MM_SCROLL_STEP_MAX 224]. 224 is the clamp
ceiling — the Linux default at which this hardware produced zero wheel — and
is never the detent. The clamp is unsigned (ULONG): too low becomes the
default 8, too high — including a negative REG_DWORD — becomes 224.

1-finger START/DRAG must not emit wheel at any |step|, including 8 and 20.
down < 2 keeps the whole emit path gated: the contact's anchor is refreshed
to the current position and nothing is banked. Wheel/AC Pan need two or more
contacts down, and one reference finger emits for the whole gesture.
Compact 8-byte 0x12 must not copy native in[6]/in[7].
A report that fails the TranslateMouse2ToHid front gate is dropped whole:
outLen 0, no output bytes, no anchor mutation.
No WDK. No .sys load.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hostmodel import (  # noqa: E402
    MM2_COMPACT_LEN,
    MM2_HEADER_LEN,
    MM2_TOUCH_BYTES,
    MM_MOUSE_REPORT_LEN,
    MM_REPORT_ID_MOUSE,
    MM_SCROLL_STEP,
    MM_SCROLL_STEP_MAX,
    STATUS_NO_MORE_ENTRIES,
    TOUCH_STATE_DRAG,
    Ctx,
    Mouse2Result,
    effective_step,
    i8,
    make_mt,
    pack_touch,
    strip_c_comments,
    translate_mouse2_to_hid,
)

ROOT = Path(__file__).resolve().parents[1]
GESTURE = ROOT / "GestureEngine.c"
GESTURE_H = ROOT / "GestureEngine.h"


class _Run:
    def __init__(self) -> None:
        self.failed: list[str] = []

    def check(self, name: str, ok: bool, msg: str) -> None:
        if ok:
            print(f"PASS: {name}: {msg}")
        else:
            print(f"FAIL: {name}: {msg}")
            self.failed.append(name)


def one_slot_drag(step_y: int) -> tuple[Mouse2Result, int]:
    """14+8 one-slot DRAG with pre-seeded anchor at (0,0). stepY = -y."""
    ctx = Ctx()
    ctx.TouchAnchorValid[0] = True
    ctx.TouchAnchorX[0] = 0
    ctx.TouchAnchorY[0] = 0
    drag = pack_touch(0, -step_y, 0, TOUCH_STATE_DRAG)
    inp = make_mt([drag])
    return translate_mouse2_to_hid(inp, ctx), len(inp)

def _function_body(code: str, name: str) -> str:
    """Return one production C function body, including nested blocks."""
    match = re.search(r"\b" + re.escape(name) + r"\s*\([^;{}]*\)\s*\{", code, re.S)
    if not match:
        return ""
    depth = 1
    pos = match.end()
    while depth and pos < len(code):
        if code[pos] == "{":
            depth += 1
        elif code[pos] == "}":
            depth -= 1
        pos += 1
    return code[match.end() : pos - 1] if depth == 0 else ""


def test_c_source(run: _Run) -> None:
    if not GESTURE.is_file():
        run.check("SCROLL_STEP_8", False, f"missing {GESTURE}")
        run.check("NO_DOWN_LT_2", False, f"missing {GESTURE}")
        run.check("COMPACT_NO_NATIVE_WHEEL", False, f"missing {GESTURE}")
        return
    raw = GESTURE.read_text(encoding="utf-8")
    code = strip_c_comments(raw)
    active_raw = _function_body(raw, "AccumulateSurfaceScroll")
    active = _function_body(code, "AccumulateSurfaceScroll")
    down_match = re.search(r"down\s*<\s*2", active)
    detent_match = re.search(
        r"stepY\s*>=\s*\(INT\)\s*step.*?\*outWheel",
        active,
        re.S,
    )
    has_active_detent = (
        bool(active)
        and re.search(r"step\s*=\s*ctx->ScrollStep", active) is not None
        and detent_match is not None
        and down_match is not None
        and down_match.start() < detent_match.start()
    )
    has_token = "SCROLL_STEP_8" in active_raw and has_active_detent
    run.check(
        "SCROLL_STEP_8",
        has_token,
        "GestureEngine.c SCROLL_STEP_8 next to the detent"
        if has_token
        else "GestureEngine.c missing SCROLL_STEP_8 next to the detent",
    )
    has_down = has_active_detent
    run.check(
        "DOWN_LT_2",
        has_down,
        "AccumulateSurfaceScroll gates wheel on down < 2"
        if has_down
        else "GestureEngine.c missing down < 2 (1-finger must not emit Wheel)",
    )
    has_tf = "TWO_FINGER" in active_raw and has_down
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
        return
    hdr = GESTURE_H.read_text(encoding="utf-8")
    has_step = (
        re.search(r"#define\s+MM_SCROLL_STEP\s+8\b", hdr) is not None
        and MM_SCROLL_STEP == 8
    )
    run.check(
        "MM_SCROLL_STEP_8",
        has_step,
        "GestureEngine.h MM_SCROLL_STEP 8 (live 0323 detent; host model reads it)"
        if has_step
        else "GestureEngine.h missing #define MM_SCROLL_STEP 8",
    )

def test_scroll_step_clamp(run: _Run) -> None:
    """ctx->ScrollStep is ULONG: too low → default 8, too high → 224."""
    low = effective_step(Ctx(scroll_step=0))
    run.check(
        "SCROLL_STEP_CLAMP_LOW",
        low == MM_SCROLL_STEP,
        f"ScrollStep 0 below MM_SCROLL_STEP_MIN → default detent {MM_SCROLL_STEP}"
        if low == MM_SCROLL_STEP
        else f"ScrollStep 0 gave detent {low} (want default {MM_SCROLL_STEP})",
    )
    # A negative REG_DWORD reaches the driver as a huge ULONG, so it trips
    # the > MAX clamp and lands on 224 — never on the default.
    high = effective_step(Ctx(scroll_step=-1))
    run.check(
        "SCROLL_STEP_CLAMP_HIGH",
        high == MM_SCROLL_STEP_MAX,
        f"ScrollStep -1 (0xFFFFFFFF as ULONG) clamps to {MM_SCROLL_STEP_MAX}"
        if high == MM_SCROLL_STEP_MAX
        else (
            f"ScrollStep -1 gave detent {high} (want clamp {MM_SCROLL_STEP_MAX}; "
            "signed compare would give the default instead)"
        ),
    )


def test_one_slot_drag_thresholds(run: _Run) -> None:
    """14+8 one-slot DRAG must not emit wheel (1-finger), at any magnitude."""
    cases = (MM_SCROLL_STEP - 1, MM_SCROLL_STEP, 20, -20)
    for step in cases:
        res, n = one_slot_drag(step)
        out = res.payload
        wheel = i8(out[7])
        hwheel = i8(out[6])
        ok = (
            res.ok
            and res.out_len == MM_MOUSE_REPORT_LEN
            and n == MM2_HEADER_LEN + MM2_TOUCH_BYTES
            and wheel == 0
            and hwheel == 0
        )
        run.check(
            f"ONE_SLOT_DRAG_{step}",
            ok,
            f"14+8 one-slot DRAG |stepY|={step} wheel=0"
            if ok
            else f"1-finger still emitted wheel={wheel} hwheel={hwheel} step={step}",
        )


def two_slot_drag(step_y: int) -> tuple[Mouse2Result, int]:
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
    res, n = two_slot_drag(MM_SCROLL_STEP)
    wheel = i8(res.payload[7])
    ok = res.ok and n == MM2_HEADER_LEN + 2 * MM2_TOUCH_BYTES and wheel == 1
    run.check(
        "TWO_FINGER_STEP_NONZERO",
        ok,
        "14+16 two-slot DRAG emits exactly one notch per step (one reference finger)"
        if ok
        else f"2-finger step={MM_SCROLL_STEP} wheel={wheel} (want 1) len={n}",
    )


def test_compact_garbage_no_wheel(run: _Run) -> None:
    """Compact 8-byte 0x12 with garbage at [6]/[7] → wheel/hwheel 0."""
    inp = bytearray(MM2_COMPACT_LEN)
    inp[0] = MM_REPORT_ID_MOUSE
    inp[6] = 0x7F
    inp[7] = 0x81
    res = translate_mouse2_to_hid(bytes(inp), Ctx())
    out = res.payload
    wheel = i8(out[7])
    hwheel = i8(out[6])
    ok = res.ok and res.out_len == MM_MOUSE_REPORT_LEN and wheel == 0 and hwheel == 0
    run.check(
        "COMPACT_GARBAGE_NO_WHEEL",
        ok,
        "compact 8-byte 0x12 garbage [6]/[7] → wheel/hwheel 0"
        if ok
        else f"compact copied garbage wheel={wheel} hwheel={hwheel} (must leave 0)",
    )


def test_front_gate_rejects(run: _Run) -> None:
    """Malformed reports are dropped whole: outLen 0 and anchors untouched.

    The C returns before it reads a single touch, so a rejected report must
    not synthesize an 8-byte 0x12 and must not re-anchor any slot.
    """
    good = make_mt([pack_touch(0, -MM_SCROLL_STEP, 0, TOUCH_STATE_DRAG)])
    cases = (
        ("SHORT_5", bytes(good[:5])),
        ("UNALIGNED_18", bytes(good[: MM2_HEADER_LEN + 4])),
        ("FOREIGN_RID_0x11", bytes([0x11]) + bytes(good[1:])),
    )
    for name, inp in cases:
        ctx = Ctx()
        ctx.TouchAnchorValid[0] = True
        ctx.TouchAnchorX[0] = 0
        ctx.TouchAnchorY[0] = 0
        res = translate_mouse2_to_hid(inp, ctx)
        anchors_kept = (
            ctx.TouchAnchorValid == [True] + [False] * (len(ctx.TouchAnchorValid) - 1)
            and ctx.TouchAnchorX[0] == 0
            and ctx.TouchAnchorY[0] == 0
        )
        ok = (
            res.status == STATUS_NO_MORE_ENTRIES
            and res.out_len == 0
            and res.payload == b""
            and anchors_kept
        )
        run.check(
            f"FRONT_GATE_{name}",
            ok,
            f"len={len(inp)} rid={inp[0]:#x} rejected, outLen 0, anchors untouched"
            if ok
            else (
                f"len={len(inp)} rid={inp[0]:#x} status={res.status:#x} "
                f"outLen={res.out_len} anchorsKept={anchors_kept} "
                "(reject must not emit or re-anchor)"
            ),
        )


def main() -> int:
    run = _Run()
    test_c_source(run)
    test_scroll_step_clamp(run)
    test_one_slot_drag_thresholds(run)
    test_two_finger_emits(run)
    test_compact_garbage_no_wheel(run)
    test_front_gate_rejects(run)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
