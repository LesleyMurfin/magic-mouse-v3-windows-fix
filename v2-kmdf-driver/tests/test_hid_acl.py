#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Host-mode fail-closed ACL/HID contract tests. No WDK. No .sys. No network.

Reimplements OnAclTransferComplete + TranslateAclHidReport against sample
buffers:

  - 0x90 never rewritten (raw 0x90 and HID DATA A1 90; COL02 battery).
  - 6→8 refused without SdpPatchSuccess/capacity (pointer-safe no-grow).
  - Output is always 8-byte RID 0x12, never RID 0x02. Wheel / AC Pan come
    from the 14+8*N touch block (hostmodel AccumulateSurfaceScroll); native
    report[6]/[7] are never copied, so compact 8-byte 0x12 yields zero.
  - Feature 0x47 is absent from the injected descriptor.
  - Unique SCM MagicMouseDriver204Scroll (not live MagicMouseDriver).
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hostmodel import (  # noqa: E402
    MM2_HEADER_LEN,
    MM_SCROLL_STEP,
    TOUCH_STATE_DRAG,
    TOUCH_STATE_START,
    Ctx,
    accumulate_surface_scroll,
    clamp_i8,
    make_mt,
    pack_touch,
)

HID_MSG_DATA_INPUT = 0xA1
MM_REPORT_ID_MOUSE = 0x12
MM_REPORT_ID_BATTERY = 0x90
MM_MOUSE_REPORT_LEN = 8
MM_BTN_MASK = 0x03

ROOT = Path(__file__).resolve().parents[1]
HID_C = ROOT / "HidDescriptor.c"
INF = ROOT / "MagicMouseDriver-kmdf-204-scroll.inf"
ACL_C = ROOT / "AclTranslate.c"
DRV_C = ROOT / "Driver.c"



def _i16le(lo: int, hi: int) -> int:
    v = (lo | (hi << 8)) & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def translate_acl_hid_report(
    buf: bytearray, received_len: int, capacity: int, ctx: Ctx
) -> tuple[int, bool]:
    """Host model of TranslateAclHidReport. Mutates buf only on rewrite.

    Returns (new_len, rewritten). Fail closed: battery 0x90 is never
    rewritten; 6-byte 0x12 stays 6 bytes when capacity < need (8, or 9
    with 0xA1).
    """
    new_len = received_len
    if not buf or received_len < 1 or capacity < 1:
        return new_len, False

    parse_len = received_len if received_len <= capacity else capacity

    # Battery: live HidD_GetInputReport(0x90) on COL02. Do not rewrite.
    if buf[0] == MM_REPORT_ID_BATTERY:
        return new_len, False
    if (
        buf[0] == HID_MSG_DATA_INPUT
        and parse_len >= 2
        and buf[1] == MM_REPORT_ID_BATTERY
    ):
        return new_len, False

    if parse_len < 6:
        return new_len, False

    hid_hdr = False
    report_off = 0
    report_len = parse_len
    if buf[0] == HID_MSG_DATA_INPUT and parse_len >= 7 and buf[1] in (
        MM_REPORT_ID_MOUSE,
        0x27,
    ):
        hid_hdr = True
        report_off = 1
        report_len = parse_len - 1
    elif buf[0] not in (MM_REPORT_ID_MOUSE, 0x27):
        return new_len, False

    need = (1 + MM_MOUSE_REPORT_LEN) if hid_hdr else MM_MOUSE_REPORT_LEN
    if capacity < need:
        # Cannot grow in-place. Native 6-byte X/Y stays (pointer-safe).
        return new_len, False

    report = buf[report_off : report_off + report_len]
    if len(report) < 6:
        return new_len, False

    buttons = report[1] & MM_BTN_MASK
    x_lo, x_hi = report[2], report[3]
    y_lo, y_hi = report[4], report[5]
    # TranslateMouse2ToHid fills Wheel / AC Pan from the 14+8*N touch block
    # only, and skips AccumulateSurfaceScroll below MM2_HEADER_LEN. Native
    # report[6]/[7] are never copied through, so a compact 8-byte 0x12
    # translates to AC Pan 0 / Wheel 0.
    ac_pan = 0
    wheel = 0
    if report_len >= MM2_HEADER_LEN:
        # ctx is the persistent DEVICE_CONTEXT: a notch needs the anchor a
        # PREVIOUS report left behind, so a per-report context could never
        # produce one.
        wheel, ac_pan = accumulate_surface_scroll(bytes(report), ctx)
        wheel = clamp_i8(wheel)
        ac_pan = clamp_i8(ac_pan)

    translated = bytearray(MM_MOUSE_REPORT_LEN)
    translated[0] = MM_REPORT_ID_MOUSE  # never RID 0x02
    translated[1] = buttons
    translated[2] = x_lo
    translated[3] = x_hi
    translated[4] = y_lo
    translated[5] = y_hi
    translated[6] = ac_pan & 0xFF
    translated[7] = wheel & 0xFF

    if hid_hdr:
        buf[0] = HID_MSG_DATA_INPUT
        buf[1 : 1 + MM_MOUSE_REPORT_LEN] = translated
        return 1 + MM_MOUSE_REPORT_LEN, True

    buf[:MM_MOUSE_REPORT_LEN] = translated
    return MM_MOUSE_REPORT_LEN, True


def apply_acl(
    buf: bytearray,
    received_len: int,
    capacity: int,
    sdp_ok: bool,
    ctx: Ctx | None = None,
) -> tuple[int, bool]:
    """Host model of OnAclTransferComplete then TranslateAclHidReport.

    Grow 6→8 only when sdpOk (SdpPatchSuccess) is true AND capacity >= 8.
    When sdpOk is false, the 6-byte native 0x12 stays (pointer-safe).
    """
    if not sdp_ok:
        return received_len, False
    # Driver.c: never call translate unless proven capacity >= 8.
    if capacity < 8:
        return received_len, False
    return translate_acl_hid_report(
        buf, received_len, capacity, ctx if ctx is not None else Ctx()
    )


def _inf_code(text: str) -> str:
    out = []
    for line in text.splitlines():
        code = line.split(";", 1)[0]
        if code.strip():
            out.append(code)
    return "\n".join(out)


class _Run:
    def __init__(self) -> None:
        self.failed: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"PASS: {name}")
        else:
            extra = f" — {detail}" if detail else ""
            print(f"FAIL: {name}{extra}")
            self.failed.append(name)


def test_battery_passthrough(run: _Run) -> None:
    """BATTERY_PASSTHROUGH: buffer starting 0x90 (and A1 90) must not be rewritten."""
    raw = bytearray([0x90, 0x04, 0x2F, 0x00, 0x00, 0x00, 0x00, 0x00])
    raw_orig = bytes(raw)
    n, rewritten = apply_acl(raw, received_len=4, capacity=8, sdp_ok=True)
    raw_ok = (not rewritten) and n == 4 and bytes(raw) == raw_orig and raw[2] == 0x2F

    hdr = bytearray([0xA1, 0x90, 0x04, 0x2F, 0x00, 0x00, 0x00, 0x00, 0x00])
    hdr_orig = bytes(hdr)
    n2, rewritten2 = apply_acl(hdr, received_len=5, capacity=9, sdp_ok=True)
    hdr_ok = (
        (not rewritten2)
        and n2 == 5
        and bytes(hdr) == hdr_orig
        and hdr[0] == HID_MSG_DATA_INPUT
        and hdr[1] == MM_REPORT_ID_BATTERY
    )

    run.check(
        "BATTERY_PASSTHROUGH",
        raw_ok and hdr_ok,
        f"raw rewritten={rewritten} len={n}; A1 90 rewritten={rewritten2} len={n2}",
    )


def test_no_grow_without_capacity(run: _Run) -> None:
    """NO_GROW_WITHOUT_CAPACITY: 6-byte 0x12 with capacity 6 stays 6 bytes."""
    sentinel = 0xAA
    native = [0x12, 0x01, 0x0A, 0x00, 0xF6, 0xFF]
    buf = bytearray(native + [sentinel, sentinel])
    # sdpOk true is not enough: capacity 6 refuses 6→8 (pointer-safe).
    n, rewritten = apply_acl(buf, received_len=6, capacity=6, sdp_ok=True)
    ok = (
        (not rewritten)
        and n == 6
        and list(buf[:6]) == native
        and buf[6] == sentinel
        and buf[7] == sentinel
    )
    run.check(
        "NO_GROW_WITHOUT_CAPACITY",
        ok,
        f"rewritten={rewritten} len={n} buf={list(buf)}",
    )


def test_no_grow_without_sdp(run: _Run) -> None:
    """NO_GROW_WITHOUT_SDP: 6→8 only if sdpOk AND capacity>=8; else 6-byte stays."""
    native = [0x12, 0x01, 0x0A, 0x00, 0xF6, 0xFF]
    room = bytearray(native + [0x00, 0x00, 0x00, 0x00])

    # sdpOk false, capacity >= 8: refuse grow.
    no_sdp = bytearray(room)
    n_false, rw_false = apply_acl(no_sdp, received_len=6, capacity=8, sdp_ok=False)

    # sdpOk true, capacity >= 8: grow allowed.
    yes_sdp = bytearray(room)
    n_true, rw_true = apply_acl(yes_sdp, received_len=6, capacity=8, sdp_ok=True)

    # sdpOk true, capacity 6: still refuse (both flags required).
    tight = bytearray(native + [0xCC, 0xCC])
    n_tight, rw_tight = apply_acl(tight, received_len=6, capacity=6, sdp_ok=True)

    ok = (
        (not rw_false)
        and n_false == 6
        and list(no_sdp[:6]) == native
        and rw_true
        and n_true == 8
        and (not rw_tight)
        and n_tight == 6
    )
    run.check(
        "NO_GROW_WITHOUT_SDP",
        ok,
        f"sdpOk=false → rewritten={rw_false} len={n_false}; "
        f"sdpOk=true cap=8 → rewritten={rw_true} len={n_true}; "
        f"sdpOk=true cap=6 → rewritten={rw_tight} len={n_tight}",
    )


def test_wheel_on_0x12(run: _Run) -> None:
    """WHEEL_ON_0x12: after 8-byte rewrite, RID 0x12, X/Y INT16 at 2-5, wheel byte 7."""
    # Native 6-byte 0x12: buttons=1, X=10, Y=-10.
    # [6]/[7] hold stale bytes the translation must overwrite, not pass on.
    native = bytearray([0x12, 0x01, 0x0A, 0x00, 0xF6, 0xFF, 0x7F, 0x81])
    n, rewritten = apply_acl(native, received_len=6, capacity=8, sdp_ok=True)

    grow_ok = (
        rewritten
        and n == 8
        and native[0] == MM_REPORT_ID_MOUSE
        and native[0] != 0x02
        and _i16le(native[2], native[3]) == 10
        and _i16le(native[4], native[5]) == -10
        and native[6] == 0  # 6-byte report: no touch block → AC Pan 0
        and native[7] == 0  # stale 0x81 overwritten, not copied through
    )

    # Compact 8-byte 0x12 is shorter than MM2_HEADER_LEN, so the touch loop
    # never runs: keep RID 0x12 and X/Y, and zero [6]/[7] instead of copying
    # the native bytes through.
    compact = bytearray([0x12, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0x03])
    n2, rw2 = apply_acl(compact, received_len=8, capacity=8, sdp_ok=True)
    compact_ok = (
        rw2
        and n2 == 8
        and compact[0] == MM_REPORT_ID_MOUSE
        and compact[0] != 0x02
        and _i16le(compact[2], compact[3]) == 5
        and _i16le(compact[4], compact[5]) == 0
        and compact[6] == 0  # AC Pan: no touch block → 0
        and compact[7] == 0  # Wheel (0x0038): no touch block → 0
    )

    run.check(
        "WHEEL_ON_0x12",
        grow_ok and compact_ok,
        f"grow rewritten={rewritten} rid={native[0]:#x} len={n}; "
        f"compact rewritten={rw2} rid={compact[0]:#x} wheel={compact[7]}",
    )


def test_wheel_notch_across_reports(run: _Run) -> None:
    """WHEEL_NOTCH_ACROSS_REPORTS: a notch needs the anchor of a prior report.

    One DEVICE_CONTEXT, two 14+16 reports through the ACL path: the first
    lands two contacts (anchors only), the second drags both by one detent, so
    each dragging contact emits its own notch into byte 7. The same second
    report replayed against a device that never saw the first must emit
    nothing — which is why a per-report context makes any Wheel assertion
    unfalsifiable.
    """
    contacts = 2
    ctx = Ctx()
    land = make_mt(
        [
            pack_touch(0, 0, 0, TOUCH_STATE_START),
            pack_touch(40, 0, 1, TOUCH_STATE_START),
        ]
    )
    drag = make_mt(
        [
            pack_touch(0, -MM_SCROLL_STEP, 0, TOUCH_STATE_DRAG),
            pack_touch(40, -MM_SCROLL_STEP, 1, TOUCH_STATE_DRAG),
        ]
    )

    n_land, rw_land = apply_acl(
        bytearray(land), received_len=len(land), capacity=len(land), sdp_ok=True, ctx=ctx
    )

    notch = bytearray(drag)
    n_drag, rw_drag = apply_acl(
        notch, received_len=len(drag), capacity=len(drag), sdp_ok=True, ctx=ctx
    )

    cold = bytearray(drag)
    apply_acl(
        cold, received_len=len(drag), capacity=len(drag), sdp_ok=True, ctx=Ctx()
    )

    ok = (
        rw_land
        and n_land == MM_MOUSE_REPORT_LEN
        and rw_drag
        and n_drag == MM_MOUSE_REPORT_LEN
        and notch[0] == MM_REPORT_ID_MOUSE
        # Wheel: one notch per contact that crossed the detent.
        and notch[7] == contacts
        and notch[6] == 0  # AC Pan: no horizontal travel
        and cold[7] == 0  # no persisted anchor → no notch
        and cold[6] == 0
    )
    run.check(
        "WHEEL_NOTCH_ACROSS_REPORTS",
        ok,
        f"shared ctx wheel={notch[7]} acpan={notch[6]} len={n_drag}; "
        f"fresh ctx wheel={cold[7]} acpan={cold[6]}",
    )


def test_no_feature_47(run: _Run) -> None:
    """NO_FEATURE_47: HidDescriptor.c has 0x85, 0x90 and 0x09, 0x38; no 0x85, 0x47."""
    if not HID_C.is_file():
        run.check("NO_FEATURE_47", False, f"missing {HID_C}")
        return
    text = HID_C.read_text(encoding="utf-8")
    has_battery = "0x85, 0x90" in text
    has_wheel = "0x09, 0x38" in text
    has_feat47 = "0x85, 0x47" in text
    run.check(
        "NO_FEATURE_47",
        has_battery and has_wheel and not has_feat47,
        f"0x85, 0x90={has_battery} 0x09, 0x38={has_wheel} 0x85, 0x47={has_feat47}",
    )


def test_unique_scm(run: _Run) -> None:
    """UNIQUE_SCM: INF AddService/LowerFilters MagicMouseDriver204Scroll, not live."""
    if not INF.is_file():
        run.check("UNIQUE_SCM", False, f"missing {INF}")
        return
    code = _inf_code(INF.read_text(encoding="utf-8"))
    add_unique = (
        re.search(
            r"AddService\s*=\s*MagicMouseDriver204Scroll\s*,",
            code,
        )
        is not None
    )
    add_live = (
        re.search(r"AddService\s*=\s*MagicMouseDriver\s*,", code) is not None
    )
    lower_unique = 'LowerFilters",0x00010000,"MagicMouseDriver204Scroll"' in code
    lower_live = bool(
        re.search(
            r'LowerFilters",0x00010000,"MagicMouseDriver"\s*$',
            code,
            re.M,
        )
    )
    run.check(
        "UNIQUE_SCM",
        add_unique and lower_unique and not add_live and not lower_live,
        f"AddService unique={add_unique} live={add_live}; "
        f"LowerFilters unique={lower_unique} live={lower_live}",
    )


def test_c_source_acl_contract(run: _Run) -> None:
    """Fail-closed vs AclTranslate.c/Driver.c: 0x90 passthrough, 6-byte no-grow.

    Python self-model is not enough. Rewriting MM_REPORT_ID_BATTERY in C,
    dropping return FALSE passthrough, growing 6-byte reports when
    capacity < need, or losing SdpPatchSuccess/sdpOk must turn this red.
    """
    if not ACL_C.is_file():
        run.check("C_SOURCE_ACL_CONTRACT", False, f"missing {ACL_C}")
        return
    if not DRV_C.is_file():
        run.check("C_SOURCE_ACL_CONTRACT", False, f"missing {DRV_C}")
        return

    acl = ACL_C.read_text(encoding="utf-8")
    drv = DRV_C.read_text(encoding="utf-8")

    has_rid = "MM_REPORT_ID_BATTERY" in acl or "0x90" in acl
    # Battery path is passthrough: never rewrite; return FALSE; buffer unchanged.
    has_pass = (
        re.search(
            r"(MM_REPORT_ID_BATTERY|0x90)[\s\S]{0,500}return FALSE",
            acl,
        )
        is not None
        and re.search(
            r"passthrough|never\s+rewrit|not\s+rewrit|do\s+not\s+rewrit|"
            r"passed through|unchanged",
            acl,
            re.I,
        )
        is not None
    )

    has_sdp = "SdpPatchSuccess" in drv and "sdpOk" in drv

    # Refuse 6→8 when capacity < need (cannot grow; pointer-safe no-grow).
    has_six = re.search(r"\b6-byte\b|\b6 byte\b|\b6\b", acl) is not None
    has_nogrow = (
        re.search(r"capacity\s*<\s*need|capacity\s*<", acl) is not None
        and re.search(
            r"cannot\s+grow|pointer[- ]safe|no[-_ ]grow|nogrow|refuse",
            acl,
            re.I,
        )
        is not None
    )

    ok = has_rid and has_pass and has_sdp and has_six and has_nogrow
    run.check(
        "C_SOURCE_ACL_CONTRACT",
        ok,
        f"0x90/MM_REPORT_ID_BATTERY={has_rid} passthrough/return FALSE={has_pass}; "
        f"SdpPatchSuccess/sdpOk={has_sdp}; 6-byte no-grow capacity<need={has_six and has_nogrow}",
    )


def test_c_source_control_channel_learned_both_ways(run: _Run) -> None:
    """Fail-closed vs Driver.c: the control channel must be learned from
    device-initiated reconnects, not only host-initiated opens.

    The diversion gate alone does not keep the battery readable. The only path
    that makes this filter transparent to the control channel is the
    pass-through taken when an inbound ACL transfer's ChannelHandle equals
    ctx->MtControlHandle. That handle was learned solely from
    BRB_L2CA_OPEN_CHANNEL - the HOST-initiated open - while an Apple mouse
    coming back from an idle drop reconnects on its own and arrives as
    BRB_L2CA_OPEN_CHANNEL_RESPONSE. With that case unhandled the handle stays
    NULL for the life of the connection, every control-channel read is
    processed by the filter, and GET_REPORT(Input, 0x90) is destroyed.

    Measured on hardware 2026-09-17 with the gate fix already installed and
    2.0.4.4 confirmed live: the wire carried A1 90 04 10 (0x10 = 16%) on every
    one of 112 captured frames while userspace read 90 00 00. Deleting either
    BRB type from the request intercept or from OnOpenChannelComplete must
    turn this red.
    """
    if not DRV_C.is_file():
        run.check("C_SOURCE_CONTROL_CHANNEL_LEARNED_BOTH_WAYS", False, f"missing {DRV_C}")
        return

    drv = DRV_C.read_text(encoding="utf-8")

    # Both BRB types must appear, and RESPONSE must be paired with the control
    # PSM rather than mentioned only in a comment.
    n_open = len(re.findall(r"BrbHeader\.Type\s*==\s*BRB_L2CA_OPEN_CHANNEL(?![_A-Z])", drv))
    n_resp = len(re.findall(r"BrbHeader\.Type\s*==\s*BRB_L2CA_OPEN_CHANNEL_RESPONSE", drv))
    # Two sites must handle both: the request intercept and the completion.
    both_sites = n_open >= 2 and n_resp >= 2
    psm_guarded = (
        re.search(
            r"BRB_L2CA_OPEN_CHANNEL_RESPONSE[\s\S]{0,200}?"
            r"BrbL2caOpenChannel\.Psm\s*==\s*MM_HID_CONTROL_PSM",
            drv,
        )
        is not None
    )
    # The pass-through that the learned handle enables must still exist.
    passthrough = (
        re.search(
            r"ChannelHandle\s*==\s*ctlHandle[\s\S]{0,200}?ForwardPassthrough",
            drv,
        )
        is not None
    )
    ok = both_sites and psm_guarded and passthrough
    run.check(
        "C_SOURCE_CONTROL_CHANNEL_LEARNED_BOTH_WAYS",
        ok,
        f"OPEN_CHANNEL sites={n_open} OPEN_CHANNEL_RESPONSE sites={n_resp} "
        f"(both>=2: {both_sites}); RESPONSE guarded by control PSM={psm_guarded}; "
        f"ctlHandle passthrough present={passthrough}",
    )


def test_c_source_control_channel_gate(run: _Run) -> None:
    """Fail-closed vs Driver.c: the IN scratch diversion must not eat short reads.

    HidBth reads the HID control channel header-first (BufferSize 1 for the
    0xA1 DATA byte). A `BufferSize > 0` diversion gate hands that 1-byte read
    a MM_ACL_MAX_PARSE scratch with ACL_SHORT_TRANSFER_OK, swallows the whole
    GET_REPORT(Input, 0x90) response and copies back min(received, origCap) = 1
    byte, so COL02 battery returns 90 00 00 / STATUS_SUCCESS. Reintroducing
    that gate, dropping the MM_MOUSE_REPORT_LEN floor, deleting the
    MM_ACL_MAX_PARSE upper bound or the sdpOk conjunct, or lowering the
    OnAclTransferComplete origCap floor must turn this red.
    """
    if not DRV_C.is_file():
        run.check("C_SOURCE_CONTROL_CHANNEL_GATE", False, f"missing {DRV_C}")
        return

    drv = DRV_C.read_text(encoding="utf-8")

    # Diversion floor: a whole report, never a header-first 1-byte read.
    has_floor = (
        re.search(
            r"BrbL2caAclTransfer\.BufferSize\s*>=\s*MM_MOUSE_REPORT_LEN",
            drv,
        )
        is not None
    )
    # No `BufferSize > 0` gate anywhere; `>= 0` / `> 1` / `> 0x10` must not hit.
    has_gt_zero = (
        re.search(
            r"BrbL2caAclTransfer\.BufferSize\s*>(?!=)\s*0(?![\dxX])",
            drv,
        )
        is not None
    )
    # Upper bound kept: the gate cannot be "fixed" by deleting it outright.
    has_upper = (
        re.search(
            r"BrbL2caAclTransfer\.BufferSize\s*<(?!=)\s*MM_ACL_MAX_PARSE",
            drv,
        )
        is not None
    )
    has_sdp_conjunct = (
        re.search(
            r"sdpOk\s*&&[\s\S]{0,200}?"
            r"BrbL2caAclTransfer\.BufferSize\s*>=\s*MM_MOUSE_REPORT_LEN",
            drv,
        )
        is not None
    )
    # OnAclTransferComplete still refuses to translate below a whole report.
    has_orig_cap = (
        re.search(r"origCap\s*>=\s*MM_MOUSE_REPORT_LEN", drv) is not None
    )

    ok = (
        has_floor
        and not has_gt_zero
        and has_upper
        and has_sdp_conjunct
        and has_orig_cap
    )
    run.check(
        "C_SOURCE_CONTROL_CHANNEL_GATE",
        ok,
        f"BufferSize>=MM_MOUSE_REPORT_LEN={has_floor} BufferSize>0={has_gt_zero}; "
        f"BufferSize<MM_ACL_MAX_PARSE={has_upper} sdpOk&&gate={has_sdp_conjunct}; "
        f"origCap>=MM_MOUSE_REPORT_LEN={has_orig_cap}",
    )


def main() -> int:
    run = _Run()
    test_battery_passthrough(run)
    test_no_grow_without_capacity(run)
    test_no_grow_without_sdp(run)
    test_wheel_on_0x12(run)
    test_wheel_notch_across_reports(run)
    test_no_feature_47(run)
    test_unique_scm(run)
    test_c_source_acl_contract(run)
    test_c_source_control_channel_gate(run)
    test_c_source_control_channel_learned_both_ways(run)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
