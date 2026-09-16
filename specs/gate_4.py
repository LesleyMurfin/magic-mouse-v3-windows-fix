#!/usr/bin/env python3
"""Spec 4 executable gate — unique 2.0.4.1 KMDF scroll + 135-byte SDP overlay.

RED-first. Unique INF / kernel already at 7087f4b is not a pass (tautology).
Keyword presence in a Python self-model is not a pass.

Fails until:
  * v2-kmdf-driver/tests/test_sdp_overlay.py quotes native prefix
    09 02 06 35 8D 35 8B 08 22 25 87 unchanged after overlay and HID sizeof 0x87
  * v2-kmdf-driver/tests/test_hid_acl.py fail-closed-asserts 0x90 passthrough
    and 6-byte no-grow against driver source (AclTranslate.c and Driver.c)
  * v2-kmdf-driver/tests/test_bsod_regress.py quotes 090126-18750 / BSOD_50 /
    buf[4] / 0x87 / applewirelessmouse
  * tests/test_sdp_walk.py must not gate PATCHED_0x25_IS_108 (that 0x50'd)
  * v2-kmdf-driver/tests/test_scroll_threshold.py quotes SCROLL_STEP_8
    against GestureEngine.c (missing token is RED)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / "v2-kmdf-driver" / "tests" / "test_hid_acl.py"
OVERLAY = ROOT / "v2-kmdf-driver" / "tests" / "test_sdp_overlay.py"
BSOD = ROOT / "v2-kmdf-driver" / "tests" / "test_bsod_regress.py"
WALK = ROOT / "v2-kmdf-driver" / "tests" / "test_sdp_walk.py"
MT = ROOT / "v2-kmdf-driver" / "tests" / "test_mt_enable.py"
SCROLL_THRESHOLD = ROOT / "v2-kmdf-driver" / "tests" / "test_scroll_threshold.py"
GESTURE = ROOT / "v2-kmdf-driver" / "GestureEngine.c"
NATIVE_PREFIX = "09 02 06 35 8D 35 8B 08 22 25 87"

fails = 0


def pass_(msg: str) -> None:
    print(f"PASS: {msg}")


def fail_(msg: str) -> None:
    global fails
    fails += 1
    print(f"FAIL: {msg}")


def search(text: str, pattern: str) -> bool:
    return re.search(pattern, text, re.IGNORECASE | re.MULTILINE) is not None


def reads_driver_source(src: str, name: str) -> bool:
    """True if the host test loads that C file via a quoted path."""
    q = re.escape(name)
    return search(
        src,
        r'(ROOT\s*/\s*["\']' + q + r'["\']'
        r'|Path\([^)]*["\']' + q + r'["\']'
        r'|open\(\s*["\'][^"\']*' + q + r'["\']'
        r'|joinpath\(\s*["\']' + q + r'["\']'
        r'|/\s*["\']' + q + r'["\'])',
    )


def asserts_c_0x90_passthrough(src: str) -> bool:
    """Host test must fail if AclTranslate.c drops 0x90 passthrough."""
    if not reads_driver_source(src, "AclTranslate.c"):
        return False
    has_rid = search(src, r"0x90|MM_REPORT_ID_BATTERY")
    has_pass = search(
        src,
        r"passthrough|never\s+rewrit|not\s+rewrit|do\s+not\s+rewrit|"
        r"return FALSE|unchanged",
    )
    return has_rid and has_pass


def asserts_c_6byte_nogrow(src: str) -> bool:
    """Host test must fail if C grows 6→8 without SdpPatchSuccess/capacity."""
    reads_acl = reads_driver_source(src, "AclTranslate.c")
    reads_drv = reads_driver_source(src, "Driver.c")
    if not (reads_acl or reads_drv):
        return False
    has_six = search(src, r"\b6\b|6-byte|6\s*byte")
    has_nogrow = search(
        src,
        r"no[-_ ]grow|nogrow|capacity\s*<|cannot\s+grow|pointer[- ]safe|"
        r"refuse",
    )
    has_gate = search(src, r"SdpPatchSuccess|sdpOk|sdp_ok|capacity")
    return has_six and has_nogrow and has_gate


def asserts_overlay_prefix_and_size(src: str) -> bool:
    """Overlay test must quote the 11-byte native prefix and HID size 0x87."""
    compact = re.sub(r"[\s,xX\\]", "", src.upper())
    has_prefix = "090206358D358B08222587" in compact
    has_size = search(src, r"0x87")
    return has_prefix and has_size


def asserts_overlay_count1_acpan(src: str) -> bool:
    """Overlay test must fail Count-2 Wheel (ExpertHid CHANGES-NEEDED)."""
    compact = re.sub(r"[\s,xX\\]", "", src.upper())
    has_count1 = "9501" in compact
    has_acpan = "0A3802" in compact
    has_names = search(src, r"HID_COUNT1_BEFORE_WHEEL") and search(
        src, r"HID_HAS_0A_38_02"
    )
    return has_count1 and has_acpan and has_names


def asserts_overlay_f1(src: str) -> bool:
    compact = re.sub(r"[\s,xX\\]", "", src.upper())
    return "85F1" in compact and search(src, r"HID_HAS_85_F1")


def check_overlay() -> None:
    if not OVERLAY.is_file():
        fail_("overlay test v2-kmdf-driver/tests/test_sdp_overlay.py missing")
        fail_(
            "native prefix 09 02 06 35 8D 35 8B 08 22 25 87 unchanged after "
            "overlay and HID sizeof 0x87 not asserted (no overlay test)"
        )
        return

    src = OVERLAY.read_text(encoding="utf-8", errors="replace")
    if not src.strip():
        fail_("overlay test v2-kmdf-driver/tests/test_sdp_overlay.py is empty")
        fail_(
            "native prefix 09 02 06 35 8D 35 8B 08 22 25 87 / HID 0x87 "
            "not quoted (empty overlay test)"
        )
        return

    if asserts_overlay_prefix_and_size(src):
        pass_(
            "overlay test quotes prefix 09 02 06 35 8D 35 8B 08 22 25 87 "
            "and HID sizeof 0x87"
        )
    else:
        fail_(
            "overlay test does not quote prefix "
            "09 02 06 35 8D 35 8B 08 22 25 87 unchanged after overlay "
            "and HID sizeof 0x87"
        )

    if asserts_overlay_count1_acpan(src):
        pass_("overlay test quotes Count 1 + AC Pan 0A 38 02 before Wheel")
    else:
        fail_(
            "overlay test does not quote Count 1 (95 01) and AC Pan "
            "0A 38 02 (HID_COUNT1_BEFORE_WHEEL / HID_HAS_0A_38_02) — "
            "Count-2 Wheel inherit is ExpertHid CHANGES-NEEDED"
        )

    if asserts_overlay_f1(src):
        pass_("overlay test quotes Feature 85 F1 / HID_HAS_85_F1")
    else:
        fail_("overlay test does not quote Feature 85 F1 / HID_HAS_85_F1")


def check_hid_acl() -> None:
    if not TEST.is_file():
        fail_("host test v2-kmdf-driver/tests/test_hid_acl.py missing")
        fail_(
            "0x90 passthrough not asserted against AclTranslate.c "
            "(no host test)"
        )
        fail_(
            "6-byte no-grow without SdpPatchSuccess/capacity not asserted "
            "against Driver.c/AclTranslate.c (no host test)"
        )
        return

    src = TEST.read_text(encoding="utf-8", errors="replace")
    if not src.strip():
        fail_("host test v2-kmdf-driver/tests/test_hid_acl.py is empty")
        return

    if asserts_c_0x90_passthrough(src):
        pass_("host test asserts 0x90 passthrough against AclTranslate.c")
    else:
        fail_(
            "host test does not assert 0x90 passthrough against AclTranslate.c "
            "(Python self-model is not fail-closed on driver source)"
        )

    if asserts_c_6byte_nogrow(src):
        pass_(
            "host test asserts 6-byte no-grow without SdpPatchSuccess/capacity "
            "against Driver.c/AclTranslate.c"
        )
    else:
        fail_(
            "host test does not assert 6-byte no-grow without "
            "SdpPatchSuccess/capacity against Driver.c/AclTranslate.c "
            "(Python self-model is not fail-closed on driver source)"
        )


def check_bsod() -> None:
    if WALK.is_file():
        walk_src = WALK.read_text(encoding="utf-8", errors="replace")
        if "PATCHED_0x25_IS_108" in walk_src or "HID_DESC_108" in walk_src:
            fail_(
                "test_sdp_walk.py still gates 108-byte length rewrite "
                "(090126-18750 0x50) — delete it; overlay + test_bsod_regress.py"
            )
        else:
            pass_("test_sdp_walk.py is not a 108-byte rewrite gate")
    else:
        pass_("test_sdp_walk.py absent (no host SdpWalkStream)")

    if not BSOD.is_file():
        fail_("BSOD regression test v2-kmdf-driver/tests/test_bsod_regress.py missing")
        fail_(
            "090126-18750 / BSOD_50 / buf[4] / HID 0x87 / applewirelessmouse "
            "not asserted (no BSOD test)"
        )
        return

    src = BSOD.read_text(encoding="utf-8", errors="replace")
    compact = re.sub(r"[\s,xX\\]", "", src.upper())
    ok = (
        "090126-18750" in src
        and "BSOD_50" in src
        and "buf[4]" in src
        and "0x87" in src
        and "applewirelessmouse" in src.lower()
        and "108" in src
    )
    if ok:
        pass_(
            "BSOD regression quotes 090126-18750 / BSOD_50 / buf[4] / "
            "HID 0x87 / applewirelessmouse"
        )
    else:
        fail_(
            "BSOD regression does not quote 090126-18750 / BSOD_50 / buf[4] / "
            "HID 0x87 not-108 / applewirelessmouse"
        )

def check_mt() -> None:
    if not MT.is_file():
        fail_("MT enable test v2-kmdf-driver/tests/test_mt_enable.py missing")
        fail_(
            "Linux feature_mt_mouse2 F1 02 01 / wire 53 F1 02 01 not asserted "
            "against Driver.c (no MT test)"
        )
        return
    src = MT.read_text(encoding="utf-8", errors="replace")
    compact = re.sub(r"[\s,xX\\]", "", src.upper())
    ok = (
        "LastAclBytes" in src
        and "Driver.c" in src
        and "MT_ENABLE_ACL_BYTES" in src
    )
    if ok:
        pass_("MT enable test quotes LastAclBytes / MT_ENABLE_ACL_BYTES against Driver.c")
    else:
        fail_(
            "MT enable test does not quote MT_ENABLE_ACL_BYTES "
            "(last interrupt ACL payload in Diag)"
        )


def check_scroll_threshold() -> None:
    # Do not green because this file mentions SCROLL_STEP_8.
    if not SCROLL_THRESHOLD.is_file():
        fail_(
            "scroll threshold test "
            "v2-kmdf-driver/tests/test_scroll_threshold.py missing"
        )
        fail_(
            "SCROLL_STEP_8 not quoted against GestureEngine.c "
            "(no test_scroll_threshold)"
        )
        return
    src = SCROLL_THRESHOLD.read_text(encoding="utf-8", errors="replace")
    quotes = "SCROLL_STEP_8" in src and "GestureEngine.c" in src
    if quotes:
        pass_(
            "test_scroll_threshold.py quotes SCROLL_STEP_8 against GestureEngine.c"
        )
    else:
        fail_(
            "test_scroll_threshold.py does not quote SCROLL_STEP_8 / GestureEngine.c"
        )
    ge = ""
    if GESTURE.is_file():
        ge = GESTURE.read_text(encoding="utf-8", errors="replace")
    if "SCROLL_STEP_8" in ge and "TWO_FINGER" in ge:
        pass_("GestureEngine.c has SCROLL_STEP_8 and TWO_FINGER")
    else:
        fail_(
            "GestureEngine.c missing SCROLL_STEP_8 and/or TWO_FINGER "
            "(1-finger must not emit; detent 8)"
        )

def main() -> int:
    # Unique INF / dest / SCM / HidDescriptor already present at 7087f4b.
    # Checking them here would green this gate on a tautology.
    check_overlay()
    check_hid_acl()
    check_bsod()
    check_mt()
    check_scroll_threshold()
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
