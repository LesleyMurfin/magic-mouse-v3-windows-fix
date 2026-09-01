#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
MT enable fail-closed vs Driver.c.

Linux hid-magicmouse feature_mt_mouse2 Feature SET_REPORT { 0xF1, 0x02, 0x01 }
BT HID wire 53 F1 02 01 (HIDP SET_REPORT|FEATURE = 0x53).

After SdpPatchSuccess the kernel must send that packet
(MmSendMtEnable / MtEnable / MtPkt). Missing 0x53 F1 packet or those
symbols → FAIL. No WDK. No .sys load. Exit 0 only if Driver.c has the enable.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRV_C = ROOT / "Driver.c"

# Linux feature_mt_mouse2 Feature SET_REPORT payload, then BT HID wire type.
FEATURE_MT = (0xF1, 0x02, 0x01)
WIRE_MT = (0x53, 0xF1, 0x02, 0x01)


def _code(text: str) -> str:
    """Strip // and /* */ so comments cannot green the gate."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def _has_ordered_hex(code: str, seq: tuple[int, ...], window: int = 400) -> bool:
    """True if 0xNN literals appear in order inside a bounded window."""
    pats = [rf"0x0*{b:X}\b" for b in seq]
    for m0 in re.finditer(pats[0], code, re.I):
        chunk = code[m0.start() : m0.start() + window]
        pos = 0
        ok = True
        for p in pats:
            m = re.search(p, chunk[pos:], re.I)
            if not m:
                ok = False
                break
            pos += m.end()
        if ok:
            return True
    return False


def _near(code: str, a: str, b: str, window: int = 1200) -> bool:
    for m in re.finditer(re.escape(a), code):
        lo = max(0, m.start() - window)
        hi = min(len(code), m.end() + window)
        if b in code[lo:hi]:
            return True
    return False


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


def main() -> int:
    run = _Run()
    if not DRV_C.is_file():
        run.check("MT_ENABLE_F1_02_01", False, f"missing {DRV_C}")
        run.check("MT_ENABLE_WIRE_53", False, f"missing {DRV_C}")
        run.check("MT_ENABLE_AFTER_SDP", False, f"missing {DRV_C}")
        return 1

    drv = DRV_C.read_text(encoding="utf-8")
    code = _code(drv)

    has_f10201 = _has_ordered_hex(code, FEATURE_MT)
    has_wire = _has_ordered_hex(code, WIRE_MT)
    has_send = "MmSendMtEnable" in code
    has_mt = "MtEnable" in code
    has_pkt = "MtPkt" in code
    has_sdp = "SdpPatchSuccess" in code
    has_sym = has_send or has_mt or has_pkt
    after_sdp = has_sdp and has_sym and (
        _near(code, "SdpPatchSuccess", "MmSendMtEnable")
        or _near(code, "SdpPatchSuccess", "MtEnable")
        or _near(code, "SdpPatchSuccess", "MtPkt")
    )

    run.check(
        "MT_ENABLE_F1_02_01",
        has_f10201,
        "Driver.c Feature SET_REPORT { 0xF1, 0x02, 0x01 }"
        if has_f10201
        else "Driver.c missing feature_mt_mouse2 0xF1 0x02 0x01",
    )
    run.check(
        "MT_ENABLE_WIRE_53",
        has_wire,
        "Driver.c BT HID wire 53 F1 02 01 (0x53)"
        if has_wire
        else "Driver.c missing 0x53 F1 packet 53 F1 02 01",
    )
    run.check(
        "MT_ENABLE_AFTER_SDP",
        after_sdp,
        "MmSendMtEnable/MtEnable/MtPkt after SdpPatchSuccess"
        if after_sdp
        else (
            f"SdpPatchSuccess={has_sdp} MmSendMtEnable={has_send} "
            f"MtEnable={has_mt} MtPkt={has_pkt} (must send after SdpPatchSuccess)"
        ),
    )
    has_bytes = "LastAclBytes" in code
    run.check(
        "MT_ENABLE_ACL_BYTES",
        has_bytes,
        "LastAclBytes copied from interrupt ACL IN"
        if has_bytes
        else "Driver.c must copy last interrupt ACL payload to LastAclBytes",
    )
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
