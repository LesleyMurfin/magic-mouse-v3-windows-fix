#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Hi-res scroll (issue #48) vs HidDescriptor.c / GestureEngine.c / Driver.c.

One HID Wheel unit is WHEEL_DELTA = 120 to hidclass, which is the "one line
per notch" jump users report. The fix is the HID Resolution Multiplier
(Generic Desktop usage 0x48) in a second 135-byte descriptor, selected by
Parameters!HiResScroll, plus a detent divided by the same multiplier so the
gesture gain does not move.

This file proves the descriptor with a real HID item parser rather than byte
substrings — a Resolution Multiplier that parses as the wrong item type, or
lands outside the Logical collection that scopes it to Wheel / AC Pan, is a
descriptor the host will not honour even though every byte substring is
present. It then proves the arithmetic against the host model in
hostmodel.py, and the registry / SET_REPORT wiring against the driver source.

What "gain equivalence" means here (measured, not assumed):

  * Per touch unit the gain is identical: classic is 1 unit per
    MM_SCROLL_STEP of travel x 120; hi-res is 1 unit per
    MM_SCROLL_STEP / MM_HIRES_MULTIPLIER of travel x (120 /
    MM_HIRES_MULTIPLIER). On a drag that is an exact multiple of the detent
    the two deliver exactly the same scroll.
  * They are NOT equal in general, and hi-res is the correct one. Classic
    emits at most one unit per report and snaps the anchor to the current
    position, so sub-detent and super-detent travel is simply discarded: a
    60-unit flick in one report scrolls 120 classic and 450 hi-res. Hi-res is
    therefore never worse and its unscrolled residue is strictly smaller.
  * The sub-detent case is literally issue #48: a nudge shorter than the
    classic detent scrolls nothing at all today.

No WDK. No .sys load. Exit 0 only if every check prints PASS:.
"""
from __future__ import annotations

import os
import random
import re
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hostmodel import (  # noqa: E402
    MM_HIRES_MULTIPLIER,
    MM_SCROLL_STEP,
    TOUCH_STATE_DRAG,
    WHEEL_DELTA,
    Ctx,
    detent_units,
    effective_step,
    i8,
    make_mt,
    pack_touch,
    strip_c_comments,
    translate_mouse2_to_hid,
)

ROOT = Path(__file__).resolve().parents[1]
HID_C = ROOT / "HidDescriptor.c"
GESTURE_C = ROOT / "GestureEngine.c"
GESTURE_H = ROOT / "GestureEngine.h"
DRV_C = ROOT / "Driver.c"
DRV_H = ROOT / "Driver.h"
IH_C = ROOT / "InputHandler.c"
INF = ROOT / "MagicMouseDriver-kmdf-204-scroll.inf"

HID_LEN = 0x87
# Scroll delivered per emitted unit once the host has applied the multiplier.
HIRES_UNIT_DELTA = WHEEL_DELTA // MM_HIRES_MULTIPLIER
# Hi-res detent in touch units.
HIRES_STEP = MM_SCROLL_STEP // MM_HIRES_MULTIPLIER

# HID 1.11 item types / tags used below.
TYPE_MAIN = 0
TYPE_GLOBAL = 1
TYPE_LOCAL = 2
MAIN_INPUT = 0x8
MAIN_OUTPUT = 0x9
MAIN_FEATURE = 0xB
MAIN_COLLECTION = 0xA
MAIN_END_COLLECTION = 0xC
COLLECTION_PHYSICAL = 0x00
COLLECTION_APPLICATION = 0x01
COLLECTION_LOGICAL = 0x02
USAGE_PAGE_GENERIC_DESKTOP = 0x01
USAGE_PAGE_CONSUMER = 0x0C
USAGE_X = 0x30
USAGE_Y = 0x31
USAGE_WHEEL = 0x38
USAGE_RESOLUTION_MULTIPLIER = 0x48
USAGE_AC_PAN = 0x0238
# bSize 0/1/2/3 encodes 0/1/2/4 data bytes (HID 1.11 6.2.2.2).
_SIZE_BYTES = (0, 1, 2, 4)
LONG_ITEM_PREFIX = 0xFE


class Item(NamedTuple):
    """One parsed short item."""

    index: int
    offset: int
    tag: int
    type: int
    data: bytes

    @property
    def uval(self) -> int:
        value = 0
        for i, byte in enumerate(self.data):
            value |= byte << (8 * i)
        return value

    @property
    def sval(self) -> int:
        if not self.data:
            return 0
        value = self.uval
        bits = 8 * len(self.data)
        return value - (1 << bits) if value & (1 << (bits - 1)) else value


class Field(NamedTuple):
    """One report field produced by a Main Input/Output/Feature item."""

    report_id: int
    kind: str
    usage_page: int
    usage: int | None
    report_size: int
    logical_min: int
    logical_max: int
    flags: int
    bit_offset: int
    collections: tuple[tuple[int, int], ...]

    @property
    def layout(self) -> tuple:
        """Everything about the wire format, minus collection identity.

        The hi-res blob wraps AC Pan / Wheel in an extra Logical collection,
        which is a grouping change, not a wire-format change.
        """
        return (
            self.report_id,
            self.kind,
            self.usage_page,
            self.usage,
            self.report_size,
            self.logical_min,
            self.logical_max,
            self.flags,
            self.bit_offset,
        )


def parse_items(blob: bytes) -> list[Item]:
    """Walk the descriptor as HID short items. Raises on anything malformed."""
    items: list[Item] = []
    pos = 0
    while pos < len(blob):
        prefix = blob[pos]
        if prefix == LONG_ITEM_PREFIX:
            raise ValueError(f"long item at byte {pos}")
        size = _SIZE_BYTES[prefix & 0x03]
        if pos + 1 + size > len(blob):
            raise ValueError(f"item at byte {pos} runs past the descriptor end")
        items.append(
            Item(
                index=len(items),
                offset=pos,
                tag=(prefix >> 4) & 0x0F,
                type=(prefix >> 2) & 0x03,
                data=bytes(blob[pos + 1 : pos + 1 + size]),
            )
        )
        pos += 1 + size
    return items


class Walk(NamedTuple):
    items: list[Item]
    fields: list[Field]
    balanced: bool
    max_depth: int


def walk_descriptor(blob: bytes) -> Walk:
    """Resolve global/local state into concrete report fields."""
    items = parse_items(blob)
    fields: list[Field] = []
    usage_page = 0
    logical_min = 0
    logical_max = 0
    report_size = 0
    report_count = 0
    report_id = 0
    usages: list[tuple[int, int]] = []
    usage_min: tuple[int, int] | None = None
    usage_max: tuple[int, int] | None = None
    collections: list[tuple[int, int]] = []
    bit_cursor: dict[tuple[int, str], int] = {}
    underflow = False
    max_depth = 0

    def clear_locals() -> None:
        nonlocal usages, usage_min, usage_max
        usages = []
        usage_min = None
        usage_max = None

    for item in items:
        if item.type == TYPE_GLOBAL:
            if item.tag == 0x0:
                usage_page = item.uval
            elif item.tag == 0x1:
                logical_min = item.sval
            elif item.tag == 0x2:
                logical_max = item.sval
            elif item.tag == 0x7:
                report_size = item.uval
            elif item.tag == 0x8:
                report_id = item.uval
            elif item.tag == 0x9:
                report_count = item.uval
            elif item.tag in (0xA, 0xB):
                raise ValueError("Push/Pop is not modelled (and is not used)")
            continue
        if item.type == TYPE_LOCAL:
            if len(item.data) == 4:
                page = item.uval >> 16
                value = item.uval & 0xFFFF
            else:
                page = usage_page
                value = item.uval
            if item.tag == 0x0:
                usages.append((page, value))
            elif item.tag == 0x1:
                usage_min = (page, value)
            elif item.tag == 0x2:
                usage_max = (page, value)
            continue

        # Main item.
        if item.tag == MAIN_COLLECTION:
            collections.append((item.uval, item.index))
            max_depth = max(max_depth, len(collections))
            clear_locals()
            continue
        if item.tag == MAIN_END_COLLECTION:
            if collections:
                collections.pop()
            else:
                underflow = True
            clear_locals()
            continue
        kind = {
            MAIN_INPUT: "Input",
            MAIN_OUTPUT: "Output",
            MAIN_FEATURE: "Feature",
        }.get(item.tag)
        if kind is None:
            clear_locals()
            continue
        key = (report_id, kind)
        base = bit_cursor.get(key, 0)
        for n in range(report_count):
            if usages:
                page, usage = usages[min(n, len(usages) - 1)]
            elif usage_min is not None:
                page, first = usage_min
                last = usage_max[1] if usage_max is not None else first
                usage = min(first + n, last)
            else:
                page, usage = usage_page, None
            fields.append(
                Field(
                    report_id=report_id,
                    kind=kind,
                    usage_page=page,
                    usage=usage,
                    report_size=report_size,
                    logical_min=logical_min,
                    logical_max=logical_max,
                    flags=item.uval,
                    bit_offset=base + n * report_size,
                    collections=tuple(collections),
                )
            )
        bit_cursor[key] = base + report_count * report_size
        clear_locals()

    return Walk(items, fields, not underflow and not collections, max_depth)


def descriptor_bytes(name: str) -> bytes:
    """Parse one `const UCHAR <name>[] = { … };` blob out of HidDescriptor.c.

    Anchored on the whole declaration: `g_HidDescriptorHiRes[]` also starts
    with `g_HidDescriptor`, so a name-prefix split is ambiguous.
    """
    text = HID_C.read_text(encoding="utf-8")
    match = re.search(
        r"const\s+UCHAR\s+" + re.escape(name) + r"\s*\[\s*\]\s*=\s*\{(.*?)\n\s*\};",
        text,
        re.S,
    )
    if match is None:
        raise ValueError(f"const UCHAR {name}[] = {{ … }}; not found")
    body = re.sub(r"//.*?$", "", match.group(1), flags=re.M)
    return bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})\b", body))


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


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


class _Run:
    def __init__(self) -> None:
        self.failed: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        extra = f" — {detail}" if detail else ""
        if ok:
            print(f"PASS: {name}{extra}")
        else:
            print(f"FAIL: {name}{extra}")
            self.failed.append(name)


# ---------------------------------------------------------------------------
# Descriptor
# ---------------------------------------------------------------------------


def test_descriptor(run: _Run) -> None:
    blobs: dict[str, bytes] = {}
    errors: dict[str, str] = {}
    for name in ("g_HidDescriptor", "g_HidDescriptorHiRes"):
        try:
            blobs[name] = descriptor_bytes(name)
        except (OSError, ValueError) as exc:
            errors[name] = str(exc)
    sizes = {name: len(blob) for name, blob in blobs.items()}
    both_0x87 = len(blobs) == 2 and all(size == HID_LEN for size in sizes.values())
    run.check(
        "HIRES_DESC_BOTH_0x87",
        both_0x87,
        f"sizes={sizes} errors={errors}"
        if not both_0x87
        else "g_HidDescriptor and g_HidDescriptorHiRes are both 135 bytes, so "
        "the SDP overlay is same-size in either mode",
    )
    if not both_0x87:
        for name in (
            "HIRES_DESC_ITEMS_PARSE",
            "HIRES_DESC_COLLECTIONS_BALANCED",
            "HIRES_MULTIPLIER_IS_FEATURE",
            "HIRES_MULTIPLIER_IN_LOGICAL_COLLECTION",
            "HIRES_MULTIPLIER_RANGE_1_4",
            "HIRES_MULTIPLIER_MATCHES_HEADER",
            "HIRES_REPORT_12_LAYOUT_IDENTICAL",
            "HIRES_REPORT_F1_TWO_BYTES",
            "HIRES_COL02_BATTERY_UNCHANGED",
        ):
            run.check(name, False, "descriptor blobs unusable")
        return

    walks: dict[str, Walk] = {}
    parse_err = ""
    for name, blob in blobs.items():
        try:
            walks[name] = walk_descriptor(blob)
        except ValueError as exc:
            parse_err = f"{name}: {exc}"
            break
    parsed = len(walks) == 2
    run.check(
        "HIRES_DESC_ITEMS_PARSE",
        parsed,
        parse_err
        if parse_err
        else "both descriptors parse as HID short items, exactly to the last byte"
        + f" (classic {len(walks['g_HidDescriptor'].items)} items, hi-res "
        + f"{len(walks['g_HidDescriptorHiRes'].items)} items)",
    )
    if not parsed:
        for name in (
            "HIRES_DESC_COLLECTIONS_BALANCED",
            "HIRES_MULTIPLIER_IS_FEATURE",
            "HIRES_MULTIPLIER_IN_LOGICAL_COLLECTION",
            "HIRES_MULTIPLIER_RANGE_1_4",
            "HIRES_MULTIPLIER_MATCHES_HEADER",
            "HIRES_REPORT_12_LAYOUT_IDENTICAL",
            "HIRES_REPORT_F1_TWO_BYTES",
            "HIRES_COL02_BATTERY_UNCHANGED",
        ):
            run.check(name, False, "descriptor did not parse")
        return

    classic = walks["g_HidDescriptor"]
    hires = walks["g_HidDescriptorHiRes"]

    opens = sum(
        1
        for it in hires.items
        if it.type == TYPE_MAIN and it.tag == MAIN_COLLECTION
    )
    closes = sum(
        1
        for it in hires.items
        if it.type == TYPE_MAIN and it.tag == MAIN_END_COLLECTION
    )
    balanced = classic.balanced and hires.balanced and opens == closes
    run.check(
        "HIRES_DESC_COLLECTIONS_BALANCED",
        balanced,
        f"hi-res {opens} Collection / {closes} End Collection, max depth "
        f"{hires.max_depth}; classic balanced={classic.balanced}",
    )

    mult = [
        f
        for f in hires.fields
        if f.usage_page == USAGE_PAGE_GENERIC_DESKTOP
        and f.usage == USAGE_RESOLUTION_MULTIPLIER
    ]
    one_mult = len(mult) == 1
    is_feature = one_mult and mult[0].kind == "Feature" and mult[0].flags == 0x02
    run.check(
        "HIRES_MULTIPLIER_IS_FEATURE",
        is_feature,
        f"Generic Desktop 0x48 on report {mult[0].report_id:#04x} as "
        f"{mult[0].kind} flags {mult[0].flags:#04x} (0xB1 Data,Var,Abs)"
        if is_feature
        else f"found {len(mult)} Resolution Multiplier field(s): "
        + repr([f.layout for f in mult]),
    )

    wheel = [
        f
        for f in hires.fields
        if f.report_id == 0x12
        and f.usage_page == USAGE_PAGE_GENERIC_DESKTOP
        and f.usage == USAGE_WHEEL
    ]
    acpan = [
        f
        for f in hires.fields
        if f.report_id == 0x12
        and f.usage_page == USAGE_PAGE_CONSUMER
        and f.usage == USAGE_AC_PAN
    ]
    # Mouse (Application) > Pointer (Physical) > the multiplier's Logical
    # scope. Hoisting the Logical collection out of the Pointer collection
    # would take Wheel / AC Pan out of the pointer with it.
    stack = tuple(col for col, _ in mult[0].collections) if mult else ()
    scoped = (
        is_feature
        and len(wheel) == 1
        and len(acpan) == 1
        and stack
        == (COLLECTION_APPLICATION, COLLECTION_PHYSICAL, COLLECTION_LOGICAL)
        and mult[0].collections[-1] == wheel[0].collections[-1]
        and mult[0].collections[-1] == acpan[0].collections[-1]
    )
    run.check(
        "HIRES_MULTIPLIER_IN_LOGICAL_COLLECTION",
        scoped,
        "Resolution Multiplier, Wheel (09 38) and AC Pan (0A 38 02) share one "
        "Collection (Logical) A1 02 — the scope that tells the host which "
        "axis the multiplier applies to"
        if scoped
        else f"mult collections={mult[0].collections if mult else None} "
        f"wheel={[f.collections for f in wheel]} "
        f"acpan={[f.collections for f in acpan]}",
    )

    if one_mult:
        lo, hi = mult[0].logical_min, mult[0].logical_max
    else:
        lo = hi = 0
    range_ok = one_mult and lo == 1 and hi == 4 and not (lo <= 0 <= hi)
    run.check(
        "HIRES_MULTIPLIER_RANGE_1_4",
        range_ok,
        f"Logical Minimum {lo}, Logical Maximum {hi}: 1x..4x, so the value "
        "the detent is divided by can never be 0"
        if range_ok
        else f"Logical range [{lo}, {hi}] — must be [1, 4] and must exclude 0",
    )

    hdr = _read(GESTURE_H)
    define = re.search(r"#define\s+MM_HIRES_MULTIPLIER\s+(\d+)\b", hdr)
    header_value = int(define.group(1)) if define else -1
    pinned = (
        define is not None
        and one_mult
        and header_value == hi
        and header_value == MM_HIRES_MULTIPLIER
    )
    run.check(
        "HIRES_MULTIPLIER_MATCHES_HEADER",
        pinned,
        f"GestureEngine.h MM_HIRES_MULTIPLIER {header_value} == the "
        f"descriptor's Logical Maximum {hi}: the host divides WHEEL_DELTA by "
        "one of them and the driver divides the detent by the other, so "
        "drifting apart silently changes sensitivity"
        if pinned
        else f"MM_HIRES_MULTIPLIER={header_value} descriptor Logical Maximum={hi}",
    )

    classic_12 = [
        f.layout for f in classic.fields if f.report_id == 0x12 and f.kind == "Input"
    ]
    hires_12 = [
        f.layout for f in hires.fields if f.report_id == 0x12 and f.kind == "Input"
    ]
    # Byte 0 is the report ID, so payload bit 40 is report byte 6 and bit 48
    # is report byte 7 — the AC Pan / Wheel bytes TranslateMouse2ToHid fills.
    want_tail = [
        (
            0x12,
            "Input",
            USAGE_PAGE_CONSUMER,
            USAGE_AC_PAN,
            8,
            -127,
            127,
            0x06,
            40,
        ),
        (
            0x12,
            "Input",
            USAGE_PAGE_GENERIC_DESKTOP,
            USAGE_WHEEL,
            8,
            -127,
            127,
            0x06,
            48,
        ),
    ]
    want_xy = [
        (0x12, "Input", USAGE_PAGE_GENERIC_DESKTOP, USAGE_X, 16, -2047, 2047, 0x06, 8),
        (0x12, "Input", USAGE_PAGE_GENERIC_DESKTOP, USAGE_Y, 16, -2047, 2047, 0x06, 24),
    ]
    buttons_ok = (
        len(hires_12) >= 3
        and [f[2:] for f in hires_12[:2]]
        == [(0x09, 1, 1, 0, 1, 0x02, 0), (0x09, 2, 1, 0, 1, 0x02, 1)]
        and hires_12[2][4:] == (6, 0, 1, 0x03, 2)
    )
    layout_ok = (
        classic_12 == hires_12
        and hires_12[3:5] == want_xy
        and hires_12[5:7] == want_tail
        and len(hires_12) == 7
        and buttons_ok
    )
    run.check(
        "HIRES_REPORT_12_LAYOUT_IDENTICAL",
        layout_ok,
        "report 0x12 Input is byte-for-byte the same in both descriptors: "
        "2 button bits, 6 const, X/Y Size 16 Count 2 logical -2047..2047, "
        "AC Pan at byte 6 and Wheel at byte 7, Size 8 Count 1, -127..127"
        if layout_ok
        else f"classic={classic_12}\n        hires={hires_12}",
    )

    def feature_bits(walk: Walk, rid: int) -> int:
        return sum(
            f.report_size
            for f in walk.fields
            if f.report_id == rid and f.kind == "Feature"
        )

    hires_f1 = [
        f for f in hires.fields if f.report_id == 0xF1 and f.kind == "Feature"
    ]
    f1_ok = (
        feature_bits(hires, 0xF1) == 16
        and feature_bits(classic, 0xF1) == 16
        and len(hires_f1) == 2
        and hires_f1[0].bit_offset == 0
        and hires_f1[0].usage == USAGE_RESOLUTION_MULTIPLIER
        and hires_f1[1].bit_offset == 8
        and hires_f1[1].flags == 0x03
    )
    run.check(
        "HIRES_REPORT_F1_TWO_BYTES",
        f1_ok,
        "report 0xF1 is still a 2-byte Feature report (multiplier at byte 0, "
        "constant pad at byte 1), so HidD_SetFeature with "
        "FeatureReportByteLength 3 still works — mm-f1-once.ps1 included"
        if f1_ok
        else f"hi-res F1 bits={feature_bits(hires, 0xF1)} "
        f"classic F1 bits={feature_bits(classic, 0xF1)} "
        f"fields={[f.layout for f in hires_f1]}",
    )

    classic_90 = [
        f.layout for f in classic.fields if f.report_id == 0x90 and f.kind == "Input"
    ]
    hires_90 = [
        f.layout for f in hires.fields if f.report_id == 0x90 and f.kind == "Input"
    ]
    col02_ok = (
        classic_90 == hires_90
        and len(hires_90) == 9
        and [f[3] for f in hires_90[:3]] == [0x61, 0x44, 0x46]
        and all(f[4] == 1 and f[6] == 1 for f in hires_90[:3])
        and all(f[4] == 1 and f[7] == 0x01 for f in hires_90[3:8])
        and hires_90[8][3] == 0x65
        and hires_90[8][4:8] == (8, 0, 255, 0x02)
        and hires_90[8][8] == 8
    )
    run.check(
        "HIRES_COL02_BATTERY_UNCHANGED",
        col02_ok,
        "COL02 report 0x90 is identical in both: Present / Charging / "
        "Discharging, 5 const bits, then 8-bit Relative State of Charge "
        "0..255 — the duplicate Logical Minimum (0) the hi-res blob dropped "
        "for budget was genuinely redundant"
        if col02_ok
        else f"classic={classic_90}\n        hires={hires_90}",
    )


# ---------------------------------------------------------------------------
# Arithmetic (host model)
# ---------------------------------------------------------------------------


class Drag(NamedTuple):
    units: int
    emitting: int
    residue: int

    @property
    def delta(self) -> int:
        """Scroll delivered, in WHEEL_DELTA-scaled units."""
        return self.units * self.unit_delta

    unit_delta: int = WHEEL_DELTA


def two_finger_drag(deltas: list[int], hi_res: bool) -> Drag:
    """Drive two pre-anchored contacts through per-report y deltas.

    Both slots are DRAG for the whole gesture, so down is 2 on every report
    and travel is the only variable. `residue` is the travel still sitting in
    the anchors when the gesture ends — the part that never scrolled.
    """
    ctx = Ctx(hi_res=hi_res)
    for tid, x in ((0, 0), (1, 40)):
        ctx.TouchAnchorValid[tid] = True
        ctx.TouchAnchorX[tid] = x
        ctx.TouchAnchorY[tid] = 0
    units = 0
    emitting = 0
    y = 0
    for delta in deltas:
        y += delta
        inp = make_mt(
            [
                pack_touch(0, -y, 0, TOUCH_STATE_DRAG),
                pack_touch(40, -y, 1, TOUCH_STATE_DRAG),
            ]
        )
        res = translate_mouse2_to_hid(inp, ctx)
        if not res.ok:
            raise SystemExit("FAIL: host model rejected a well-formed report")
        wheel = i8(res.payload[7])
        units += wheel
        if wheel:
            emitting += 1
    residue = sum(abs(ctx.TouchAnchorY[tid] + y) for tid in (0, 1))
    return Drag(
        units=units,
        emitting=emitting,
        residue=residue,
        unit_delta=HIRES_UNIT_DELTA if hi_res else WHEEL_DELTA,
    )


def test_arithmetic(run: _Run) -> None:
    default_ctx = Ctx()
    classic_step = effective_step(default_ctx)
    hires_step = effective_step(Ctx(hi_res=True))
    tiny_step = effective_step(Ctx(scroll_step=1, hi_res=True))
    step_ok = (
        default_ctx.HiResScroll is False
        and classic_step == MM_SCROLL_STEP
        and hires_step == HIRES_STEP
        and hires_step * MM_HIRES_MULTIPLIER == MM_SCROLL_STEP
        and tiny_step == 1
    )
    run.check(
        "HIRES_DETENT_IS_STEP_OVER_MULTIPLIER",
        step_ok,
        f"detent {classic_step} classic / {hires_step} hi-res "
        f"(= {MM_SCROLL_STEP} / {MM_HIRES_MULTIPLIER}); ScrollStep 1 floors "
        f"at {tiny_step}, never 0"
        if step_ok
        else f"classic={classic_step} hires={hires_step} floor={tiny_step} "
        f"default HiResScroll={default_ctx.HiResScroll}",
    )

    steady = [1] * 64
    plain = two_finger_drag(steady, hi_res=False)
    explicit = two_finger_drag(steady, hi_res=False)
    default_run = two_finger_drag(steady, hi_res=Ctx().HiResScroll)
    default_ok = (plain == explicit == default_run) and plain.units != 0
    run.check(
        "HIRES_DEFAULT_IS_CLASSIC",
        default_ok,
        f"Ctx() defaults HiResScroll False; the 64-unit drag is unchanged "
        f"({plain.units} units, {plain.emitting} emitting reports)"
        if default_ok
        else f"plain={plain} explicit={explicit} default={default_run}",
    )

    hires = two_finger_drag(steady, hi_res=True)
    exact_ok = (
        plain.units * WHEEL_DELTA == hires.units * HIRES_UNIT_DELTA
        and plain.delta == hires.delta
        and plain.residue == hires.residue == 0
        and plain.units == 8
        and hires.units == 32
    )
    run.check(
        "HIRES_GAIN_EXACT_ON_MULTIPLE",
        exact_ok,
        f"64-unit two-finger drag: classic {plain.units} units x "
        f"{WHEEL_DELTA} = {plain.delta}; hi-res {hires.units} units x "
        f"{HIRES_UNIT_DELTA} = {hires.delta}. Same scroll, 4x finer "
        "quantisation, nothing discarded either way"
        if exact_ok
        else f"classic={plain} hires={hires}",
    )

    smaller_ok = (
        hires.emitting > plain.emitting
        and HIRES_UNIT_DELTA < WHEEL_DELTA
        and hires.emitting == plain.emitting * MM_HIRES_MULTIPLIER
    )
    run.check(
        "HIRES_MORE_SMALLER_STEPS",
        smaller_ok,
        f"same drag emits on {hires.emitting} reports instead of "
        f"{plain.emitting}, each worth {HIRES_UNIT_DELTA} instead of "
        f"{WHEEL_DELTA} — that is the 'one line at a time' jump of issue #48"
        if smaller_ok
        else f"classic emitting={plain.emitting} hires emitting={hires.emitting}",
    )

    # A drag with a remainder: classic throws the leftover travel away.
    ragged = [1] * 90
    c_ragged = two_finger_drag(ragged, hi_res=False)
    h_ragged = two_finger_drag(ragged, hi_res=True)
    residue_ok = (
        h_ragged.residue < c_ragged.residue
        and h_ragged.delta > c_ragged.delta
        and c_ragged.residue == 2 * (90 % MM_SCROLL_STEP)
        and h_ragged.residue == 2 * (90 % HIRES_STEP)
    )
    run.check(
        "HIRES_RESIDUE_SMALLER",
        residue_ok,
        f"90-unit drag: classic delivers {c_ragged.delta} and leaves "
        f"{c_ragged.residue} touch units unscrolled; hi-res delivers "
        f"{h_ragged.delta} and leaves {h_ragged.residue}"
        if residue_ok
        else f"classic={c_ragged} hires={h_ragged}",
    )

    # A long jittery drag that does NOT land on a detent boundary: hi-res
    # must never deliver less than classic on any shape, and must leave less
    # travel unscrolled. Deltas of 0..9 mean some reports sit below the
    # hi-res detent and some cross several of them.
    rng = random.Random(48)
    noisy = [rng.randint(0, 9) for _ in range(199)]
    travelled = sum(noisy)
    c_noisy = two_finger_drag(noisy, hi_res=False)
    h_noisy = two_finger_drag(noisy, hi_res=True)
    never_worse = all(
        abs(two_finger_drag(case, hi_res=True).delta)
        >= abs(two_finger_drag(case, hi_res=False).delta)
        for case in ([1] * 64, [1] * 90, [12], [60], [-60], noisy)
    )
    noisy_ok = (
        never_worse
        and travelled % MM_SCROLL_STEP != 0
        and travelled % HIRES_STEP != 0
        and h_noisy.delta > c_noisy.delta
        and h_noisy.residue < c_noisy.residue
        and h_noisy.residue < 2 * HIRES_STEP
    )
    run.check(
        "HIRES_NEVER_DELIVERS_LESS",
        noisy_ok,
        f"199 reports / {travelled} touch units (not a detent multiple): "
        f"classic {c_noisy.delta} with {c_noisy.residue} touch units never "
        f"scrolled, hi-res {h_noisy.delta} with {h_noisy.residue}; hi-res >= "
        "classic on every shape tried"
        if noisy_ok
        else f"classic={c_noisy} hires={h_noisy} never_worse={never_worse} "
        f"travelled={travelled}",
    )

    # Issue #48 proper: a nudge shorter than the classic detent.
    nudge = [1] * 12
    c_nudge = two_finger_drag(nudge, hi_res=False)
    h_nudge = two_finger_drag(nudge, hi_res=True)
    nudge_ok = (
        c_nudge.units == 0
        and c_nudge.delta == 0
        and h_nudge.units == 2 * (12 // HIRES_STEP)
        and h_nudge.delta > 0
    )
    run.check(
        "HIRES_SUBDETENT_NUDGE_EMITS",
        nudge_ok,
        f"12-unit nudge (below the {MM_SCROLL_STEP}-unit classic detent): "
        f"classic scrolls nothing at all, hi-res emits {h_nudge.units} units "
        f"= {h_nudge.delta}. This is the reported bug"
        if nudge_ok
        else f"classic={c_nudge} hires={h_nudge}",
    )

    # A fast flick arrives as one big report: classic collapses it to 1 unit.
    flick = [60]
    c_flick = two_finger_drag(flick, hi_res=False)
    h_flick = two_finger_drag(flick, hi_res=True)
    flick_ok = (
        c_flick.units == 2
        and c_flick.residue == 0
        and h_flick.units == 2 * (60 // HIRES_STEP)
        and h_flick.delta > c_flick.delta
    )
    run.check(
        "HIRES_FLICK_NOT_COLLAPSED",
        flick_ok,
        f"60 units in one report: classic emits {c_flick.units} unit(s) = "
        f"{c_flick.delta} and discards the rest by snapping the anchor; "
        f"hi-res emits {h_flick.units} = {h_flick.delta}"
        if flick_ok
        else f"classic={c_flick} hires={h_flick}",
    )

    back = two_finger_drag([-60], hi_res=True)
    back_classic = two_finger_drag([-60], hi_res=False)
    mirror_ok = (
        back.units == -h_flick.units
        and back_classic.units == -c_flick.units
        and back.delta == -h_flick.delta
    )
    run.check(
        "HIRES_NEGATIVE_MIRRORS",
        mirror_ok,
        f"the same flick upward: classic {back_classic.units}, hi-res "
        f"{back.units} = {back.delta} — exactly the positive case negated"
        if mirror_ok
        else f"down={h_flick} up={back} classic up={back_classic}",
    )

    # C integer division truncates toward zero; Python's // floors. A naive
    # port emits one unit too many on every negative sub-detent remainder and
    # leaves the anchor on the wrong side of the finger.
    units, consumed = detent_units(-10, HIRES_STEP, True)
    floor_units = -10 // HIRES_STEP
    neg = two_finger_drag([-10], hi_res=True)
    trunc_ok = (
        HIRES_STEP == 4
        and (units, consumed) == (-2, -8)
        and floor_units == -3
        and units != floor_units
        and neg.units == -4
        and neg.residue == 2 * 2
        and detent_units(10, HIRES_STEP, True) == (2, 8)
    )
    run.check(
        "HIRES_TRUNCATES_TOWARD_ZERO",
        trunc_ok,
        f"detent_units(-10, {HIRES_STEP}) = {(units, consumed)}; Python's "
        f"-10 // {HIRES_STEP} would be {floor_units}. Through the full stack "
        f"a -10 drag emits {neg.units} units and leaves {neg.residue} touch "
        "units of residue, not an over-scroll"
        if trunc_ok
        else f"units={units} consumed={consumed} floor={floor_units} neg={neg}",
    )


# ---------------------------------------------------------------------------
# Driver source
# ---------------------------------------------------------------------------


def _uchar_define(text: str, name: str) -> int | None:
    match = re.search(
        r"#define\s+" + re.escape(name) + r"\s+\(\(UCHAR\)\s*0x([0-9A-Fa-f]+)\s*\)",
        text,
    )
    return int(match.group(1), 16) if match else None


def f1_repair_contract(drv_code: str, drv_h: str) -> dict[str, int] | None:
    """Constants for the outbound 0xF1 repair, if the C path is intact.

    None disables the host vectors below rather than letting an independent
    Python model pass while the driver's predicate has changed shape.

    The `__try` is part of the contract, not incidental style: origBuf is a
    mapping the filter does not own, so an unwritable one has to cost the
    repair and not the machine. Dropping the SEH here must fail this gate.
    """
    predicate = re.search(
        r"ctx->HiResScroll\s*&&[\s\S]{0,200}?n\s*>=\s*4\s*\)"
        r"[\s\S]{0,120}?__try[\s\S]{0,200}?"
        r"origBuf\s*\[\s*0\s*\]\s*==\s*MM_HID_SET_REPORT_FEATURE\s*&&"
        r"[\s\S]{0,120}?origBuf\s*\[\s*1\s*\]\s*==\s*MM_REPORT_ID_VENDOR_F1"
        r"[\s\S]{0,200}?origBuf\s*\[\s*2\s*\]\s*!=\s*MM_MT_ENABLE_B0"
        r"[\s\S]{0,120}?origBuf\s*\[\s*3\s*\]\s*!=\s*MM_MT_ENABLE_B1"
        r"[\s\S]{0,200}?origBuf\s*\[\s*2\s*\]\s*=\s*MM_MT_ENABLE_B0\s*;"
        r"[\s\S]{0,120}?origBuf\s*\[\s*3\s*\]\s*=\s*MM_MT_ENABLE_B1\s*;"
        r"[\s\S]{0,120}?forcedF1\s*=\s*TRUE\s*;"
        r"[\s\S]{0,200}?__except\s*\(\s*EXCEPTION_EXECUTE_HANDLER\s*\)",
        drv_code,
    )
    if predicate is None:
        return None
    values: dict[str, int] = {}
    for name in (
        "MM_HID_SET_REPORT_FEATURE",
        "MM_REPORT_ID_VENDOR_F1",
        "MM_MT_ENABLE_B0",
        "MM_MT_ENABLE_B1",
    ):
        value = _uchar_define(drv_h, name)
        if value is None:
            return None
        values[name] = value
    return values


def f1_repair(buf: bytearray, n: int, hi_res: bool, k: dict[str, int]) -> bool:
    """Host execution of the outbound SET_REPORT(Feature, 0xF1) repair."""
    if (
        hi_res
        and n >= 4
        and buf[0] == k["MM_HID_SET_REPORT_FEATURE"]
        and buf[1] == k["MM_REPORT_ID_VENDOR_F1"]
        and (buf[2] != k["MM_MT_ENABLE_B0"] or buf[3] != k["MM_MT_ENABLE_B1"])
    ):
        buf[2] = k["MM_MT_ENABLE_B0"]
        buf[3] = k["MM_MT_ENABLE_B1"]
        return True
    return False


def test_c_source(run: _Run) -> None:
    gesture = strip_c_comments(_read(GESTURE_C))
    helper = _function_body(gesture, "DetentUnits")
    active = _function_body(gesture, "AccumulateSurfaceScroll")

    hi_branch = re.search(
        r"if\s*\(\s*hiRes\s*\)\s*\{[\s\S]{0,300}?"
        r"INT\s+units\s*=\s*travel\s*/\s*step\s*;[\s\S]{0,200}?"
        r"\*consumed\s*=\s*units\s*\*\s*step\s*;[\s\S]{0,160}?return\s+units\s*;",
        helper,
    )
    classic_branch = re.search(
        r"travel\s*>=\s*step\s*\|\|\s*travel\s*<=\s*-\s*step"
        r"[\s\S]{0,200}?\*consumed\s*=\s*travel\s*;"
        r"[\s\S]{0,160}?return\s*\(\s*travel\s*>\s*0\s*\)\s*\?\s*1\s*:\s*-1\s*;",
        helper,
    )
    detent_ok = bool(helper) and hi_branch is not None and classic_branch is not None
    run.check(
        "HIRES_C_DETENT_UNITS",
        detent_ok,
        "DetentUnits keeps both rules: hi-res takes the quotient and consumes "
        "units * step (remainder stays in the anchor); classic emits one unit "
        "and consumes the whole travel"
        if detent_ok
        else f"body={bool(helper)} hiRes branch={hi_branch is not None} "
        f"classic branch={classic_branch is not None}",
    )

    clamp = re.search(r"step\s*>\s*MM_SCROLL_STEP_MAX", active)
    divide = re.search(
        r"if\s*\(\s*hiRes\s*\)\s*\{[\s\S]{0,200}?"
        r"step\s*/=\s*MM_HIRES_MULTIPLIER\s*;[\s\S]{0,160}?"
        r"if\s*\(\s*step\s*<\s*1\s*\)\s*\{\s*step\s*=\s*1\s*;",
        active,
    )
    reads_flag = re.search(r"BOOLEAN\s+hiRes\s*=\s*ctx->HiResScroll\s*;", active)
    divide_ok = (
        divide is not None
        and clamp is not None
        and reads_flag is not None
        and clamp.start() < divide.start()
        and reads_flag.start() < divide.start()
    )
    run.check(
        "HIRES_C_STEP_DIVIDE",
        divide_ok,
        "AccumulateSurfaceScroll reads ctx->HiResScroll, clamps ScrollStep to "
        "[MIN, MAX], and only then divides by MM_HIRES_MULTIPLIER with a "
        "floor of 1 — a 0 detent would emit a unit on every report"
        if divide_ok
        else f"hiRes read={reads_flag is not None} clamp={clamp is not None} "
        f"divide={divide is not None}",
    )

    drv_code = strip_c_comments(_read(DRV_C))
    drv_h = _read(DRV_H)
    constants = f1_repair_contract(drv_code, drv_h)
    run.check(
        "HIRES_C_F1_REPAIR",
        constants is not None,
        "the outbound ACL branch rewrites a host SET_REPORT(Feature, 0xF1) "
        "payload back to Apple's multitouch enable, gated on ctx->HiResScroll "
        "and n >= 4"
        if constants is not None
        else "Driver.c predicate / Driver.h constants do not match the "
        "documented repair (gate on ctx->HiResScroll, 0x53 0xF1, n >= 4, "
        "write MM_MT_ENABLE_B0/B1, set forcedF1)",
    )

    wire = (0x53, 0xF1, 0x02, 0x01)
    constants_ok = constants is not None and (
        constants["MM_HID_SET_REPORT_FEATURE"],
        constants["MM_REPORT_ID_VENDOR_F1"],
        constants["MM_MT_ENABLE_B0"],
        constants["MM_MT_ENABLE_B1"],
    ) == wire
    run.check(
        "HIRES_C_F1_REPAIR_CONSTANTS",
        constants_ok,
        "Driver.h MM_HID_SET_REPORT_FEATURE / MM_REPORT_ID_VENDOR_F1 / "
        "MM_MT_ENABLE_B0 / MM_MT_ENABLE_B1 are 53 F1 02 01"
        if constants_ok
        else f"{constants} (want 53 F1 02 01)",
    )

    counter = re.search(
        r"if\s*\(\s*forcedF1\s*\)\s*\{\s*ctx->F1PayloadForced\+\+\s*;", drv_code
    )
    published = (
        re.search(r'MmDiagSetValueIfChanged\(\s*key\s*,\s*L"HiResScroll"', drv_code)
        is not None
        and re.search(
            r'MmDiagSetValueIfChanged\(\s*key\s*,\s*L"F1PayloadForced"', drv_code
        )
        is not None
    )
    counter_ok = counter is not None and published
    run.check(
        "HIRES_C_F1_FORCED_COUNTER",
        counter_ok,
        "every repair bumps ctx->F1PayloadForced and Diag publishes both "
        "HiResScroll and F1PayloadForced, so 'hi-res on but the multiplier "
        "was never set' is visible from the registry"
        if counter_ok
        else f"counter={counter is not None} diag values published={published}",
    )

    sender = _function_body(drv_code, "MmSendMtEnable")
    literal = re.search(
        r"pkt\s*\[\s*0\s*\]\s*=\s*0x53\s*;[\s\S]{0,80}?"
        r"pkt\s*\[\s*1\s*\]\s*=\s*0xF1\s*;[\s\S]{0,80}?"
        r"pkt\s*\[\s*2\s*\]\s*=\s*0x02\s*;[\s\S]{0,80}?"
        r"pkt\s*\[\s*3\s*\]\s*=\s*0x01\s*;",
        sender,
        re.I,
    )
    run.check(
        "HIRES_MT_ENABLE_LITERAL",
        literal is not None,
        "MmSendMtEnable still spells 53 F1 02 01 out literally — the enable "
        "the device needs does not depend on HiResScroll or on the repair"
        if literal is not None
        else "MmSendMtEnable no longer writes the literal 53 F1 02 01 packet",
    )

    if constants_ok and constants is not None:
        vectors: list[tuple[str, bytes, int, bool, bytes, bool]] = [
            # name, payload, n, hi_res, expected bytes, expected forced
            (
                "windows multiplier payload repaired",
                bytes([0x53, 0xF1, 0x04, 0x00]),
                4,
                True,
                bytes([0x53, 0xF1, 0x02, 0x01]),
                True,
            ),
            (
                "already 02 01 left alone",
                bytes([0x53, 0xF1, 0x02, 0x01]),
                4,
                True,
                bytes([0x53, 0xF1, 0x02, 0x01]),
                False,
            ),
            (
                "short transfer untouched",
                bytes([0x53, 0xF1, 0x04, 0x00]),
                3,
                True,
                bytes([0x53, 0xF1, 0x04, 0x00]),
                False,
            ),
            (
                "other report id untouched",
                bytes([0x53, 0xF2, 0x04, 0x00]),
                4,
                True,
                bytes([0x53, 0xF2, 0x04, 0x00]),
                False,
            ),
            (
                "not a SET_REPORT(Feature) untouched",
                bytes([0xA2, 0xF1, 0x04, 0x00]),
                4,
                True,
                bytes([0xA2, 0xF1, 0x04, 0x00]),
                False,
            ),
            (
                "unreachable with HiResScroll off",
                bytes([0x53, 0xF1, 0x04, 0x00]),
                4,
                False,
                bytes([0x53, 0xF1, 0x04, 0x00]),
                False,
            ),
        ]
        bad: list[str] = []
        for name, payload, n, hi_res, want, want_forced in vectors:
            buf = bytearray(payload)
            forced = f1_repair(buf, n, hi_res, constants)
            if bytes(buf) != want or forced != want_forced:
                bad.append(f"{name}: got {bytes(buf).hex()} forced={forced}")
        run.check(
            "HIRES_F1_REPAIR_VECTORS",
            not bad,
            f"{len(vectors)} vectors: only a >= 4 byte 53 F1 … with "
            "HiResScroll set is rewritten, and it is rewritten to 02 01"
            if not bad
            else "; ".join(bad),
        )
    else:
        run.check(
            "HIRES_F1_REPAIR_VECTORS",
            False,
            "repair contract unusable, vectors disabled",
        )

    ih_code = strip_c_comments(_read(IH_C))
    overlay = _function_body(ih_code, "SdpRewrite_Process")
    both_sizes = re.search(
        r"g_HidDescriptorSize\s*!=\s*SDP_HID_OVERLAY_LEN\s*\|\|\s*"
        r"g_HidDescriptorHiResSize\s*!=\s*SDP_HID_OVERLAY_LEN",
        overlay,
    )
    select = re.search(
        r"const\s+UCHAR\s*\*\s*desc\s*=\s*HiRes\s*\?\s*"
        r"g_HidDescriptorHiRes\s*:\s*g_HidDescriptor\s*;",
        overlay,
    )
    copy = re.search(
        r"RtlCopyMemory\s*\(\s*buf\s*\+\s*descOffset\s*,\s*desc\s*,\s*"
        r"SDP_HID_OVERLAY_LEN\s*\)",
        overlay,
    )
    sizes_ok = (
        both_sizes is not None
        and select is not None
        and copy is not None
        and both_sizes.start() < select.start() < copy.start()
    )
    run.check(
        "HIRES_SDP_BOTH_SIZES_VALIDATED",
        sizes_ok,
        "SdpRewrite_Process re-checks BOTH g_HidDescriptorSize and "
        "g_HidDescriptorHiResSize against SDP_HID_OVERLAY_LEN before it "
        "selects desc and copies — the same-size overlay cannot become a "
        "resize through the new flag"
        if sizes_ok
        else f"both sizes={both_sizes is not None} select={select is not None} "
        f"copy={copy is not None}",
    )

    passes_flag = re.search(
        r"SdpRewrite_Process\s*\([\s\S]{0,200}?ctx->HiResScroll\s*,\s*&newLen\s*\)",
        drv_code,
    )
    run.check(
        "HIRES_SDP_CTX_FLAG_PASSED",
        passes_flag is not None,
        "Driver.c passes ctx->HiResScroll into SdpRewrite_Process, so the "
        "descriptor the host binds follows the registry value"
        if passes_flag is not None
        else "OnSdpQueryComplete does not forward ctx->HiResScroll",
    )

    inf = _read(INF)
    inf_default = re.search(
        r'Parameters"\s*,\s*"HiResScroll"\s*,\s*0x00010001\s*,\s*0\s*$',
        inf,
        re.M,
    )
    run.check(
        "HIRES_INF_DEFAULT_0",
        inf_default is not None,
        "the INF writes Parameters!HiResScroll as REG_DWORD 0: hi-res is "
        "opt-in, the shipped default is the hardware-proven classic path"
        if inf_default is not None
        else "INF does not write HiResScroll 0x00010001 with value 0",
    )

    ctx_default = re.search(r"ctx->HiResScroll\s*=\s*FALSE\s*;", drv_code)
    reads_value = re.search(
        r'RtlInitUnicodeString\(\s*&valName\s*,\s*L"HiResScroll"\s*\)'
        r"[\s\S]{0,300}?ctx->HiResScroll\s*=\s*\(\s*hiResVal\s*!=\s*0\s*\)",
        drv_code,
    )
    default_ok = (
        ctx_default is not None
        and reads_value is not None
        and ctx_default.start() < reads_value.start()
    )
    run.check(
        "HIRES_CTX_DEFAULT_FALSE",
        default_ok,
        "EvtDeviceAdd sets ctx->HiResScroll = FALSE before reading "
        "Parameters!HiResScroll, so a missing or unreadable value leaves the "
        "classic path"
        if default_ok
        else f"default FALSE={ctx_default is not None} "
        f"registry read={reads_value is not None}",
    )


def main() -> int:
    run = _Run()
    test_descriptor(run)
    test_arithmetic(run)
    test_c_source(run)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
