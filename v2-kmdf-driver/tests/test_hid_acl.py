#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Host-mode fail-closed ACL/HID contract tests. No WDK. No .sys. No network.

Reimplements OnAclTransferComplete + TranslateAclHidReport against sample
buffers:

  - 0x90 never rewritten (raw 0x90 and HID DATA A1 90; COL02 battery).
  - 6→8 refused without SdpPatchSuccess/capacity (pointer-safe no-grow).
  - Wheel only on 8-byte 0x12 after success. Never RID 0x02.
  - Feature 0x47 is absent from the injected descriptor.
  - Unique SCM MagicMouseDriver204Scroll (not live MagicMouseDriver).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HID_MSG_DATA_INPUT = 0xA1
MM_REPORT_ID_MOUSE = 0x12
MM_REPORT_ID_BATTERY = 0x90
MM_MOUSE_REPORT_LEN = 8
MM2_COMPACT_LEN = 8
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
    buf: bytearray, received_len: int, capacity: int
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
    ac_pan = 0
    wheel = 0
    if report_len >= MM2_COMPACT_LEN:
        ac_pan = report[6] if report[6] < 128 else report[6] - 256
        wheel = report[7] if report[7] < 128 else report[7] - 256
        ac_pan = max(-127, min(127, ac_pan))
        wheel = max(-127, min(127, wheel))

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
    buf: bytearray, received_len: int, capacity: int, sdp_ok: bool
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
    return translate_acl_hid_report(buf, received_len, capacity)


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
    native = bytearray([0x12, 0x01, 0x0A, 0x00, 0xF6, 0xFF, 0x00, 0x00])
    n, rewritten = apply_acl(native, received_len=6, capacity=8, sdp_ok=True)

    grow_ok = (
        rewritten
        and n == 8
        and native[0] == MM_REPORT_ID_MOUSE
        and native[0] != 0x02
        and _i16le(native[2], native[3]) == 10
        and _i16le(native[4], native[5]) == -10
        and native[7] == 0  # no touch block → wheel extra is 0
    )

    # Compact 8-byte 0x12 with wheel already present: keep RID 0x12, wheel at [7].
    compact = bytearray([0x12, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0x03])
    n2, rw2 = apply_acl(compact, received_len=8, capacity=8, sdp_ok=True)
    compact_ok = (
        rw2
        and n2 == 8
        and compact[0] == MM_REPORT_ID_MOUSE
        and compact[0] != 0x02
        and _i16le(compact[2], compact[3]) == 5
        and _i16le(compact[4], compact[5]) == 0
        and compact[6] == 0x02  # AC Pan extra
        and compact[7] == 0x03  # Wheel extra (0x0038)
    )

    run.check(
        "WHEEL_ON_0x12",
        grow_ok and compact_ok,
        f"grow rewritten={rewritten} rid={native[0]:#x} len={n}; "
        f"compact rewritten={rw2} rid={compact[0]:#x} wheel={compact[7]}",
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


def main() -> int:
    run = _Run()
    test_battery_passthrough(run)
    test_no_grow_without_capacity(run)
    test_no_grow_without_sdp(run)
    test_wheel_on_0x12(run)
    test_no_feature_47(run)
    test_unique_scm(run)
    test_c_source_acl_contract(run)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
