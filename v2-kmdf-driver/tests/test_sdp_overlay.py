#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Host-mode same-size SDP overlay. No WDK. No .sys. No SdpWalkStream.

Native v3 CachedServices 00010000 (351B) from
bthport-discovery-d0c050cc8c4d.json. Prefix
09 02 06 35 8D 35 8B 08 22 25 87 is 11 bytes; HID string length 0x87 = 135.

Kernel overlay: find prefix; if absent or sizeof != 0x87, no-op (buffer
unchanged). If present, memcpy 135 HID bytes after the prefix. *newLen =
usedLen. NEVER write 0x35 / 0x36 / 0x25 / buf[4].

Exit 0 only if every check prints PASS:.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HID_C = ROOT / "HidDescriptor.c"

# Native v3 prefix (do not change these 11 bytes):
# 09 02 06 35 8D 35 8B 08 22 25 87
PREFIX = bytes.fromhex("09 02 06 35 8D 35 8B 08 22 25 87")
HID_LEN = 0x87  # 135

# Native v3 CachedServices 00010000 (351 bytes). Source: apple-peripherals
# magic-tray test-run 2026-04-27 bthport-discovery-d0c050cc8c4d.json
# Hex starts 36015C... ends 09020E2801.
NATIVE_351_HEX = (
    "36015C0900000A000100000900013503191124090004350D3506190100090011"
    "35031900110900053503191002090006350909656E09006A0901000900093508"
    "350619112409010009000D350F350D3506190100090013350319001109010025"
    "0B4D61676963204D6F75736509010125054D6F757365090102250A4170706C65"
    "20496E632E090200090314090201090111090202088009020308000902042801"
    "0902052801090206358D358B0822258705010902A10185120509190129021500"
    "250195027501810295017506810305010901A1001601F826FF073601FB46FF04"
    "6513550D09300931751095028106750895028101C00602FF09558555150026FF"
    "0075089540B1A2C00600FF0914A1018590058475019503150025010961058509"
    "44094681029505810175089501150026FF0009658102C0090207350835060904"
    "0909010009020A280109020B09010009020C090FA009020D280109020E2801"
)


def hid_descriptor_bytes() -> bytes:
    """Parse g_HidDescriptor[] `{`…`};` hex from HidDescriptor.c."""
    text = HID_C.read_text(encoding="utf-8")
    marker = "g_HidDescriptor[]"
    if marker not in text:
        raise ValueError("g_HidDescriptor[] not found")
    rest = text.split(marker, 1)[1]
    if "{" not in rest or "};" not in rest:
        raise ValueError("g_HidDescriptor[] `{`…`};` not found")
    body = rest.split("{", 1)[1].split("};", 1)[0]
    stripped = re.sub(r"//.*?$", "", body, flags=re.M)
    nums = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})\b", stripped)]
    return bytes(nums)


def apply_overlay(buf: bytearray, hid: bytes) -> bool:
    """Memcpy-only overlay. No length-field writes. No SdpWalkStream."""
    if len(hid) != HID_LEN:
        return False
    idx = bytes(buf).find(PREFIX)
    if idx < 0:
        return False
    start = idx + len(PREFIX)
    if start + HID_LEN > len(buf):
        return False
    buf[start : start + HID_LEN] = hid
    return True


def hid_count1_acpan_wheel(hid: bytes) -> tuple[bool, bool, bool, str]:
    """Count 1 after X/Y, AC Pan 0A 38 02, then Wheel 09 38. Not Count-2 inherit."""
    y = hid.find(b"\x09\x31")
    wheel = hid.find(b"\x09\x38")
    acpan = hid.find(b"\x0a\x38\x02")
    inherit = b"\x75\x08\x09\x38\x81\x06" in hid
    if y < 0 or wheel < 0:
        return False, False, False, f"y={y} wheel={wheel} acpan={acpan}"
    count1 = hid.find(b"\x95\x01", y, wheel)
    count1_ok = count1 >= 0 and not inherit
    acpan_ok = acpan >= 0
    order_ok = acpan >= 0 and acpan < wheel
    return count1_ok, acpan_ok, order_ok, f"count1={count1} acpan={acpan} wheel={wheel} inherit={inherit}"


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
    native = bytes.fromhex(NATIVE_351_HEX)
    run.check("NATIVE_351_LEN", len(native) == 351, f"len={len(native)}")
    run.check(
        "NATIVE_STARTS_36015C",
        native[:3] == bytes.fromhex("36015C"),
        native[:3].hex(),
    )
    run.check(
        "NATIVE_ENDS_09020E2801",
        native[-5:] == bytes.fromhex("09020E2801"),
        native[-5:].hex(),
    )

    idx = native.find(PREFIX)
    run.check(
        "PREFIX_PRESENT",
        idx >= 0,
        "09 02 06 35 8D 35 8B 08 22 25 87",
    )
    hid_off = idx + len(PREFIX) if idx >= 0 else -1
    native_hid_len = native[idx + 10] if idx >= 0 else -1
    run.check(
        "NATIVE_HID_LEN_0x87",
        native_hid_len == HID_LEN,
        f"0x25={native_hid_len}",
    )
    fit = hid_off >= 0 and hid_off + HID_LEN <= len(native)
    run.check("NATIVE_HID_FITS", fit, f"off={hid_off}")

    try:
        hid = hid_descriptor_bytes()
        parse_ok = True
        parse_err = ""
    except (OSError, ValueError) as e:
        hid = b""
        parse_ok = False
        parse_err = str(e)
    run.check("HID_C_PARSE", parse_ok, parse_err or f"len={len(hid)}")
    run.check("HID_SIZE_0x87", len(hid) == HID_LEN, f"sizeof={len(hid)}")
    run.check("HID_HAS_09_38", b"\x09\x38" in hid)
    run.check("HID_HAS_85_90", b"\x85\x90" in hid)
    run.check("HID_HAS_85_F1", b"\x85\xf1" in hid)
    run.check("HID_NO_85_47", b"\x85\x47" not in hid)
    run.check("HID_NO_85_02", b"\x85\x02" not in hid)
    c1, ac, order, detail = hid_count1_acpan_wheel(hid) if hid else (False, False, False, "no hid")
    run.check("HID_COUNT1_BEFORE_WHEEL", c1, detail)
    run.check("HID_HAS_0A_38_02", ac, detail)
    run.check("HID_ACPAN_THEN_WHEEL", order, detail)

    overlaid = bytearray(native)
    applied = apply_overlay(overlaid, hid)
    run.check(
        "OVERLAY_APPLIED",
        applied,
        "memcpy 135 after prefix" if applied else "no-op (prefix missing or sizeof != 0x87)",
    )
    run.check("OVERLAY_LEN_351", len(overlaid) == 351, f"len={len(overlaid)}")

    prefix_ok = False
    if idx >= 0:
        prefix_ok = bytes(overlaid[idx : idx + len(PREFIX)]) == PREFIX
    run.check(
        "PREFIX_UNCHANGED",
        prefix_ok,
        "09 02 06 35 8D 35 8B 08 22 25 87",
    )

    if fit:
        changed = [
            i
            for i in range(len(native))
            if overlaid[i] != native[i]
        ]
        hid_span = set(range(hid_off, hid_off + HID_LEN))
        outside = [i for i in changed if i not in hid_span]
        run.check(
            "ONLY_135_BYTES_DIFFER",
            not outside,
            f"outside={outside[:8]} n={len(outside)}" if outside else "prefix+tail unchanged",
        )
        copied = bytes(overlaid[hid_off : hid_off + HID_LEN])
        run.check(
            "OVERLAY_COPIED_135",
            applied and copied == hid,
            f"applied={applied} hid_len={len(hid)}",
        )
        region = copied if applied else bytes(native[hid_off : hid_off + HID_LEN])
        run.check("OVERLAY_HAS_09_38", b"\x09\x38" in region)
        run.check("OVERLAY_HAS_85_90", b"\x85\x90" in region)
        run.check("OVERLAY_HAS_85_F1", b"\x85\xf1" in region)
        run.check("OVERLAY_NO_85_47", b"\x85\x47" not in region)
        run.check("OVERLAY_NO_85_02", b"\x85\x02" not in region)
        oc1, oac, oorder, odetail = hid_count1_acpan_wheel(region)
        run.check("OVERLAY_COUNT1_BEFORE_WHEEL", oc1, odetail)
        run.check("OVERLAY_HAS_0A_38_02", oac, odetail)
        run.check("OVERLAY_ACPAN_THEN_WHEEL", oorder, odetail)
    else:
        run.check("ONLY_135_BYTES_DIFFER", False, "native HID span invalid")
        run.check("OVERLAY_COPIED_135", False, "native HID span invalid")
        run.check("OVERLAY_HAS_09_38", False, "native HID span invalid")
        run.check("OVERLAY_HAS_85_90", False, "native HID span invalid")
        run.check("OVERLAY_HAS_85_F1", False, "native HID span invalid")
        run.check("OVERLAY_NO_85_47", False, "native HID span invalid")
        run.check("OVERLAY_NO_85_02", False, "native HID span invalid")
        run.check("OVERLAY_COUNT1_BEFORE_WHEEL", False, "native HID span invalid")
        run.check("OVERLAY_HAS_0A_38_02", False, "native HID span invalid")
        run.check("OVERLAY_ACPAN_THEN_WHEEL", False, "native HID span invalid")

    missing = bytearray(native)
    if idx >= 0:
        missing[idx] ^= 0xFF
    before = bytes(missing)
    missing_applied = apply_overlay(missing, hid)
    run.check(
        "MISSING_PREFIX_NO_MUTATION",
        (not missing_applied) and bytes(missing) == before,
        f"applied={missing_applied}",
    )

    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
