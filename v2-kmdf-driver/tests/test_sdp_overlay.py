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
INPUT_C = ROOT / "InputHandler.c"
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


def hid_descriptor_bytes(name: str = "g_HidDescriptor") -> bytes:
    """Parse one `const UCHAR <name>[] = { … };` hex blob from HidDescriptor.c.

    Anchored on the full declaration, not on a bare `g_HidDescriptor`
    substring: since issue #48 the file also declares g_HidDescriptorHiRes,
    and a prefix split would pick whichever happened to come first.
    """
    text = HID_C.read_text(encoding="utf-8")
    match = re.search(
        r"const\s+UCHAR\s+" + re.escape(name) + r"\s*\[\s*\]\s*=\s*\{(.*?)\n\s*\};",
        text,
        re.S,
    )
    if match is None:
        raise ValueError(f"const UCHAR {name}[] = {{ … }}; not found")
    stripped = re.sub(r"//.*?$", "", match.group(1), flags=re.M)
    nums = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})\b", stripped)]
    if not nums:
        raise ValueError(f"{name}[] has no 0xNN bytes")
    return bytes(nums)

def _code(text: str) -> str:
    """Strip comments before inspecting the production implementation."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


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


def _production_overlay_contract() -> tuple[bytes, int] | None:
    """Get constants only when the real SdpRewrite_Process path is intact.

    The test remains host-mode (there is no WDK on the test host), but vectors
    use the same prefix, length, guard, destination, source, and copy length
    that the production C function exposes. A control/data-flow regression
    therefore disables the vector rather than allowing an independent model to
    pass.
    """
    if not INPUT_C.is_file():
        return None
    code = _code(INPUT_C.read_text(encoding="utf-8"))
    body = _function_body(code, "SdpRewrite_Process")
    prefix_match = re.search(
        r"g_SdpHidPrefix\s*\[[^\]]+\]\s*=\s*\{([^}]*)\}", code, re.S
    )
    size_match = re.search(
        r"#define\s+SDP_HID_OVERLAY_LEN\s+0x([0-9A-Fa-f]+)\b", code
    )
    # The copy source is a pointer selected from the two same-size blobs.
    # Destination and length are unchanged; the selection itself is pinned so
    # the overlay can never source a blob whose size was not checked.
    copy_ok = re.search(
        r"RtlCopyMemory\s*\(\s*buf\s*\+\s*descOffset\s*,\s*"
        r"desc\s*,\s*SDP_HID_OVERLAY_LEN\s*\)",
        body,
    )
    desc_ok = re.search(
        r"const\s+UCHAR\s*\*\s*desc\s*=\s*HiRes\s*\?\s*"
        r"g_HidDescriptorHiRes\s*:\s*g_HidDescriptor\s*;",
        body,
    )
    both_sizes_ok = re.search(
        r"g_HidDescriptorSize\s*!=\s*SDP_HID_OVERLAY_LEN\s*\|\|\s*"
        r"g_HidDescriptorHiResSize\s*!=\s*SDP_HID_OVERLAY_LEN",
        body,
    )
    prefix_ok = re.search(
        r"buf\s*\[\s*i\s*\+\s*n\s*\]\s*!=\s*g_SdpHidPrefix\s*\[\s*n\s*\]",
        body,
    )
    not_found_ok = re.search(
        r"if\s*\(\s*!found\s*\)\s*\{.*?STATUS_NOT_FOUND", body, re.S
    )
    fit_ok = re.search(
        r"descOffset\s*\+\s*SDP_HID_OVERLAY_LEN\s*>\s*usedLen"
        r".*?descOffset\s*\+\s*SDP_HID_OVERLAY_LEN\s*>\s*allocLen",
        body,
        re.S,
    )
    new_len_ok = re.search(
        r"RtlCopyMemory\s*\([^;]+\)\s*;\s*\*newLen\s*=\s*usedLen\s*;",
        body,
        re.S,
    )
    if not (
        prefix_match
        and size_match
        and copy_ok
        and desc_ok
        and both_sizes_ok
        and prefix_ok
        and not_found_ok
        and fit_ok
        and new_len_ok
    ):
        return None
    prefix = bytes(
        int(value, 16)
        for value in re.findall(r"0x([0-9A-Fa-f]{2})\b", prefix_match.group(1))
    )
    overlay_len = int(size_match.group(1), 16)
    if len(prefix) != len(PREFIX) or overlay_len != HID_LEN:
        return None
    return prefix, overlay_len


def apply_production_overlay(
    buf: bytearray, hid: bytes, contract: tuple[bytes, int] | None
) -> bool:
    """Host execution of the guarded SdpRewrite_Process copy path."""
    if contract is None:
        return False
    prefix, overlay_len = contract
    if len(hid) != overlay_len:
        return False
    idx = bytes(buf).find(prefix)
    if idx < 0:
        return False
    start = idx + len(prefix)
    if start + overlay_len > len(buf):
        return False
    buf[start : start + overlay_len] = hid
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

    contract = _production_overlay_contract()

    def overlay_mode(tag: str, name: str) -> bytes:
        """Run the production copy path with one of the two 0x87 blobs.

        `tag` is "" for the classic descriptor (the historical check names)
        and "HIRES_" for g_HidDescriptorHiRes. Both are overlaid into the
        same native 351-byte CachedServices blob, because the whole point of
        keeping the hi-res variant at 0x87 is that the overlay stays
        same-size and the SDP length stores stay untouched in both modes.
        """
        try:
            hid = hid_descriptor_bytes(name)
            parse_ok = True
            parse_err = ""
        except (OSError, ValueError) as exc:
            hid = b""
            parse_ok = False
            parse_err = str(exc)
        run.check(f"{tag}HID_C_PARSE", parse_ok, parse_err or f"{name} len={len(hid)}")
        run.check(
            f"{tag}HID_SIZE_0x87", len(hid) == HID_LEN, f"{name} sizeof={len(hid)}"
        )
        run.check(f"{tag}HID_HAS_09_38", b"\x09\x38" in hid)
        run.check(f"{tag}HID_HAS_85_90", b"\x85\x90" in hid)
        run.check(f"{tag}HID_HAS_85_F1", b"\x85\xf1" in hid)
        run.check(f"{tag}HID_NO_85_47", b"\x85\x47" not in hid)
        run.check(f"{tag}HID_NO_85_02", b"\x85\x02" not in hid)
        c1, ac, order, detail = (
            hid_count1_acpan_wheel(hid) if hid else (False, False, False, "no hid")
        )
        run.check(f"{tag}HID_COUNT1_BEFORE_WHEEL", c1, detail)
        run.check(f"{tag}HID_HAS_0A_38_02", ac, detail)
        run.check(f"{tag}HID_ACPAN_THEN_WHEEL", order, detail)

        overlaid = bytearray(native)
        applied = apply_production_overlay(overlaid, hid, contract)
        run.check(
            f"{tag}OVERLAY_APPLIED",
            applied,
            "memcpy 135 after prefix"
            if applied
            else "no-op (prefix missing or sizeof != 0x87)",
        )
        run.check(
            f"{tag}OVERLAY_LEN_351", len(overlaid) == 351, f"len={len(overlaid)}"
        )

        prefix_kept = idx >= 0 and bytes(overlaid[idx : idx + len(PREFIX)]) == PREFIX
        run.check(
            f"{tag}PREFIX_UNCHANGED",
            prefix_kept,
            "09 02 06 35 8D 35 8B 08 22 25 87",
        )
        # The four length stores the 0x50 SdpWalkStream dumps came from:
        # outer SEQ 35 8D, inner SEQ 35 8B, TEXT_STRING 25 87, and the
        # AttributeLists length at buf[4]. None of them is a function of
        # which descriptor was selected.
        len_stores_kept = idx >= 0 and (
            bytes(overlaid[idx + 3 : idx + 7]) == bytes.fromhex("358D358B")
            and bytes(overlaid[idx + 9 : idx + 11]) == bytes.fromhex("2587")
            and overlaid[4] == native[4]
        )
        run.check(
            f"{tag}SDP_LEN_STORES_UNTOUCHED",
            len_stores_kept,
            "35 8D / 35 8B / 25 87 / buf[4] identical to native"
            if len_stores_kept
            else f"idx={idx} prefix region={bytes(overlaid[idx:idx+11]).hex()}",
        )

        if fit:
            changed = [i for i in range(len(native)) if overlaid[i] != native[i]]
            hid_span = set(range(hid_off, hid_off + HID_LEN))
            outside = [i for i in changed if i not in hid_span]
            run.check(
                f"{tag}ONLY_135_BYTES_DIFFER",
                not outside,
                f"outside={outside[:8]} n={len(outside)}"
                if outside
                else "prefix+tail unchanged",
            )
            copied = bytes(overlaid[hid_off : hid_off + HID_LEN])
            run.check(
                f"{tag}OVERLAY_COPIED_135",
                applied and copied == hid,
                f"applied={applied} hid_len={len(hid)}",
            )
            region = copied if applied else bytes(native[hid_off : hid_off + HID_LEN])
            run.check(f"{tag}OVERLAY_HAS_09_38", b"\x09\x38" in region)
            run.check(f"{tag}OVERLAY_HAS_85_90", b"\x85\x90" in region)
            run.check(f"{tag}OVERLAY_HAS_85_F1", b"\x85\xf1" in region)
            run.check(f"{tag}OVERLAY_NO_85_47", b"\x85\x47" not in region)
            run.check(f"{tag}OVERLAY_NO_85_02", b"\x85\x02" not in region)
            oc1, oac, oorder, odetail = hid_count1_acpan_wheel(region)
            run.check(f"{tag}OVERLAY_COUNT1_BEFORE_WHEEL", oc1, odetail)
            run.check(f"{tag}OVERLAY_HAS_0A_38_02", oac, odetail)
            run.check(f"{tag}OVERLAY_ACPAN_THEN_WHEEL", oorder, odetail)
        else:
            for suffix in (
                "ONLY_135_BYTES_DIFFER",
                "OVERLAY_COPIED_135",
                "OVERLAY_HAS_09_38",
                "OVERLAY_HAS_85_90",
                "OVERLAY_HAS_85_F1",
                "OVERLAY_NO_85_47",
                "OVERLAY_NO_85_02",
                "OVERLAY_COUNT1_BEFORE_WHEEL",
                "OVERLAY_HAS_0A_38_02",
                "OVERLAY_ACPAN_THEN_WHEEL",
            ):
                run.check(f"{tag}{suffix}", False, "native HID span invalid")

        missing = bytearray(native)
        if idx >= 0:
            missing[idx] ^= 0xFF
        before = bytes(missing)
        missing_applied = apply_production_overlay(missing, hid, contract)
        run.check(
            f"{tag}MISSING_PREFIX_NO_MUTATION",
            (not missing_applied) and bytes(missing) == before,
            f"applied={missing_applied}",
        )
        return hid

    hid = overlay_mode("", "g_HidDescriptor")
    hid_hires = overlay_mode("HIRES_", "g_HidDescriptorHiRes")
    run.check(
        "HIRES_SAME_SIZE_AS_CLASSIC",
        len(hid) == len(hid_hires) == HID_LEN,
        f"classic={len(hid)} hires={len(hid_hires)} (the overlay is same-size "
        "in both modes, so no SDP length store is a function of HiRes)",
    )
    run.check(
        "HIRES_IS_A_DIFFERENT_BLOB",
        bool(hid) and hid != hid_hires,
        "g_HidDescriptorHiRes is not a copy of g_HidDescriptor",
    )
    run.check(
        "HIRES_HAS_09_48",
        b"\x09\x48" in hid_hires and b"\x09\x48" not in hid,
        "Resolution Multiplier usage 0x48 only in the hi-res blob",
    )

    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
