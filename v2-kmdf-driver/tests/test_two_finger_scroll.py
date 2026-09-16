#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Two-finger-only surface scroll vs GestureEngine.c.

Host model of AccumulateSurfaceScroll + TranslateMouse2ToHid compact 0x12
lives in hostmodel.py and is shared with test_scroll_threshold.py; the detent
is #define MM_SCROLL_STEP from GestureEngine.h, not a literal here.

1-finger START/DRAG must not emit Wheel/AC Pan, and while down < 2 the active
DRAG anchor is refreshed to the current position, so one-finger travel is
discarded instead of banked into a notch when a second finger lands. Token
TWO_FINGER must sit next to down < 2 in GestureEngine.c. Compact 8-byte 0x12
must not copy native in[6]/in[7]. No WDK. No .sys load.
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
    TOUCH_STATE_DRAG,
    TOUCH_STATE_START,
    Ctx,
    i8,
    make_mt,
    pack_touch,
    strip_c_comments,
    translate_mouse2_to_hid,
)

ROOT = Path(__file__).resolve().parents[1]
GESTURE = ROOT / "GestureEngine.c"


class _Run:
    def __init__(self) -> None:
        self.failed: list[str] = []

    def check(self, name: str, ok: bool, msg: str) -> None:
        if ok:
            print(f"PASS: {name}: {msg}")
        else:
            print(f"FAIL: {name}: {msg}")
            self.failed.append(name)


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
        run.check("TWO_FINGER", False, f"missing {GESTURE}")
        run.check("DOWN_LT_2", False, f"missing {GESTURE}")
        run.check("ONE_FINGER_ANCHOR_REFRESH", False, f"missing {GESTURE}")
        run.check("COMPACT_NO_NATIVE_WHEEL", False, f"missing {GESTURE}")
        return
    raw = GESTURE.read_text(encoding="utf-8")
    code = strip_c_comments(raw)
    active_raw = _function_body(raw, "AccumulateSurfaceScroll")
    active = _function_body(code, "AccumulateSurfaceScroll")
    # Token may sit in a comment next to the production down < 2 branch.
    branch_match = re.search(
        r"down\s*<\s*2\s*\)\s*\{([^{}]*)\}", active, re.S
    )
    branch = branch_match.group(1) if branch_match else ""
    has_down = branch_match is not None
    has_token = "TWO_FINGER" in active_raw and has_down
    run.check(
        "TWO_FINGER",
        has_token,
        "GestureEngine.c TWO_FINGER next to down < 2"
        if has_token
        else "GestureEngine.c missing TWO_FINGER next to down < 2",
    )
    run.check(
        "DOWN_LT_2",
        has_down,
        "AccumulateSurfaceScroll gates emit on down < 2 (START/DRAG count)"
        if has_down
        else "GestureEngine.c missing down < 2 (count START/DRAG; 1-finger anchors only)",
    )
    # The down < 2 branch must refresh the anchor from this report's x/y,
    # not merely assign stale or unrelated coordinates before continuing.
    refreshes = (
        re.search(
            r"TouchAnchorX\s*\[\s*id\s*\]\s*=\s*\(\s*INT16\s*\)\s*x\s*;",
            branch,
        )
        is not None
        and re.search(
            r"TouchAnchorY\s*\[\s*id\s*\]\s*=\s*\(\s*INT16\s*\)\s*y\s*;",
            branch,
        )
        is not None
        and re.search(r"\bcontinue\s*;", branch) is not None
    )
    run.check(
        "ONE_FINGER_ANCHOR_REFRESH",
        refreshes,
        "down < 2 refreshes TouchAnchorX/Y to the current position, then continues"
        if refreshes
        else "down < 2 branch does not re-anchor (one-finger travel would bank a notch)",
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


def test_one_finger_drag_no_wheel(run: _Run) -> None:
    """14+8 one-slot DRAG with |stepY| >= MM_SCROLL_STEP → wheel/AC Pan 0."""
    ctx = Ctx()
    ctx.TouchAnchorValid[0] = True
    ctx.TouchAnchorX[0] = 0
    ctx.TouchAnchorY[0] = 0
    drag = pack_touch(0, -MM_SCROLL_STEP, 0, TOUCH_STATE_DRAG)
    inp = make_mt([drag])
    ok_len = len(inp) == MM2_HEADER_LEN + MM2_TOUCH_BYTES
    res = translate_mouse2_to_hid(inp, ctx)
    wheel = i8(res.payload[7])
    hwheel = i8(res.payload[6])
    ok = ok_len and res.ok and wheel == 0 and hwheel == 0
    run.check(
        "ONE_FINGER_DRAG_NO_WHEEL",
        ok,
        "14+8 one-slot DRAG |stepY|>=MM_SCROLL_STEP wheel/AC Pan 0"
        if ok
        else (
            f"14+8 one-slot DRAG emitted wheel={wheel} hwheel={hwheel} "
            f"len={len(inp)} (must be 0)"
        ),
    )


def test_one_finger_travel_not_banked(run: _Run) -> None:
    """Long 1-finger DRAG, then a 2nd finger lands: no notch from that travel.

    The one-finger frames must leave the anchor on the current position. If
    the anchor stays at touch-down, the first two-finger frame sees the whole
    accumulated travel and emits a spurious notch (the pre-fix regression).
    """
    travel = MM_SCROLL_STEP * 10
    ctx = Ctx()
    ctx.TouchAnchorValid[0] = True
    ctx.TouchAnchorX[0] = 0
    ctx.TouchAnchorY[0] = 0

    # One finger travels `travel` units in y, in MM_SCROLL_STEP increments.
    solo_wheel = 0
    y = 0
    while y > -travel:
        y -= MM_SCROLL_STEP
        solo = make_mt([pack_touch(0, y, 0, TOUCH_STATE_DRAG)])
        res = translate_mouse2_to_hid(solo, ctx)
        solo_wheel |= i8(res.payload[7]) | i8(res.payload[6])

    # Second finger lands. Slot 0 has not moved since the last frame.
    both = make_mt(
        [
            pack_touch(0, y, 0, TOUCH_STATE_DRAG),
            pack_touch(40, y, 1, TOUCH_STATE_START),
        ]
    )
    res = translate_mouse2_to_hid(both, ctx)
    wheel = i8(res.payload[7])
    hwheel = i8(res.payload[6])
    ok = res.ok and solo_wheel == 0 and wheel == 0 and hwheel == 0
    run.check(
        "ONE_FINGER_TRAVEL_NOT_BANKED",
        ok,
        f"1-finger travel {travel} discarded; hand-over frame wheel/AC Pan 0"
        if ok
        else (
            f"hand-over frame emitted wheel={wheel} hwheel={hwheel} "
            f"(solo={solo_wheel}); down < 2 must re-anchor, travel={travel}"
        ),
    )


def test_two_finger_start_drag_may_wheel(run: _Run) -> None:
    """14+16 two-slot START/DRAG with the same step → wheel MAY be non-zero."""
    ctx = Ctx()
    ctx.TouchAnchorValid[0] = True
    ctx.TouchAnchorValid[1] = True
    ctx.TouchAnchorX[0] = ctx.TouchAnchorX[1] = 0
    ctx.TouchAnchorY[0] = ctx.TouchAnchorY[1] = 0
    start = pack_touch(0, 0, 0, TOUCH_STATE_START)
    drag = pack_touch(0, -MM_SCROLL_STEP, 1, TOUCH_STATE_DRAG)
    inp = make_mt([start, drag])
    ok_len = len(inp) == MM2_HEADER_LEN + 2 * MM2_TOUCH_BYTES
    res = translate_mouse2_to_hid(inp, ctx)
    wheel = i8(res.payload[7])
    ok = ok_len and res.ok and wheel != 0
    run.check(
        "TWO_FINGER_START_DRAG_WHEEL",
        ok,
        "14+16 two-slot START/DRAG |stepY|>=MM_SCROLL_STEP wheel non-zero"
        if ok
        else (
            f"14+16 two-slot START/DRAG wheel={wheel} len={len(inp)} "
            f"(two-finger may emit; got zero)"
        ),
    )


def test_compact_garbage_no_wheel(run: _Run) -> None:
    """Compact 8-byte 0x12 with garbage at [6]/[7] → wheel/hwheel 0."""
    inp = bytearray(MM2_COMPACT_LEN)
    inp[0] = MM_REPORT_ID_MOUSE
    inp[6] = 0x7F
    inp[7] = 0x81
    res = translate_mouse2_to_hid(bytes(inp), Ctx())
    wheel = i8(res.payload[7])
    hwheel = i8(res.payload[6])
    ok = res.out_len == MM_MOUSE_REPORT_LEN and wheel == 0 and hwheel == 0
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
    test_one_finger_drag_no_wheel(run)
    test_one_finger_travel_not_banked(run)
    test_two_finger_start_drag_may_wheel(run)
    test_compact_garbage_no_wheel(run)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
