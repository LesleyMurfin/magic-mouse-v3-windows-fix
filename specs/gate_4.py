#!/usr/bin/env python3
"""Spec 4 executable gate — unique 2.0.4.6 KMDF scroll + 135-byte SDP overlay.

RED-first. Unique INF / kernel already at 7087f4b is not a pass (tautology).
Keyword presence in a Python self-model is not a pass.

This is a META-gate: it does not re-assert the driver contracts, it asserts
that the gate files which DO assert them are still there, still reading
driver source, and still PUBLISHING the named checks. The distinction
matters — every requirement below is expressed as "this name is passed to a
check() call", not "this string appears in the file", so a check that is
deleted, renamed or demoted to a comment turns this red instead of being
greened by the prose that survives it.

Groups:
  * v2-kmdf-driver/tests/test_sdp_overlay.py quotes native prefix
    09 02 06 35 8D 35 8B 08 22 25 87 unchanged after overlay and HID sizeof
    0x87, for BOTH overlay sources (issue #48 added g_HidDescriptorHiRes).
  * v2-kmdf-driver/tests/test_hid_acl.py fail-closed-asserts 0x90 passthrough
    and 6-byte no-grow against driver source (AclTranslate.c and Driver.c)
  * v2-kmdf-driver/tests/test_bsod_regress.py quotes 090126-18750 / BSOD_50 /
    buf[4] / 0x87 / applewirelessmouse, and counts BOTH descriptor arrays
  * tests/test_sdp_walk.py must not gate PATCHED_0x25_IS_108 (that 0x50'd)
  * v2-kmdf-driver/tests/test_mt_enable.py binds 53 F1 02 01 to MmSendMtEnable
  * v2-kmdf-driver/tests/test_scroll_threshold.py binds SCROLL_STEP_8 to
    GestureEngine.c (that test owns the detent / one-finger assertions, which
    it makes against comment-stripped source; re-grepping the tokens here
    would only re-pass on prose)
  * v2-kmdf-driver/tests/test_hires_scroll.py owns issue #48: the hi-res
    descriptor parse, the gain equivalence, and the 0xF1 payload repair.

Deliberate change for issue #48: this gate used to pin the Count-1 AC Pan
shape by grepping the overlay test's source for the raw bytes 95 01 and
0A 38 02. That is exactly the "file contains string" failure mode — it could
not tell a real assertion from a comment, and it hard-coded the CLASSIC
descriptor's spelling, in which AC Pan and Wheel sit directly in the Physical
collection. The hi-res blob keeps Report Count 1 and keeps AC Pan before
Wheel, but wraps both in a Collection (Logical) so the Resolution Multiplier
has a scope. The property is unchanged; the byte neighbourhood is not. It is
now pinned as published check names covering BOTH blobs, and the descriptor
is proven by a real HID item parser in test_hires_scroll.py rather than by
substring search.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "v2-kmdf-driver" / "tests"
TEST = TESTS / "test_hid_acl.py"
OVERLAY = TESTS / "test_sdp_overlay.py"
BSOD = TESTS / "test_bsod_regress.py"
WALK = TESTS / "test_sdp_walk.py"
MT = TESTS / "test_mt_enable.py"
SCROLL_THRESHOLD = TESTS / "test_scroll_threshold.py"
HIRES = TESTS / "test_hires_scroll.py"
AGENTS = ROOT / "AGENTS.md"
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


_CHECK_CALL = re.compile(r"\bcheck\(\s*f?[\"']([^\"']+)[\"']")


def check_names(src: str) -> set[str]:
    """Names actually passed to a check() call in that gate file.

    A name that only appears in a docstring, a comment or a failure message
    is NOT a check. f-string names (`f"{tag}OVERLAY_APPLIED"`) are reduced to
    their literal part, which is the name the untagged run prints.
    """
    names: set[str] = set()
    for raw in _CHECK_CALL.findall(src):
        name = re.sub(r"\{[^}]*\}", "", raw).strip()
        if name:
            names.add(name)
    return names


def missing(src: str, required: set[str]) -> list[str]:
    return sorted(required - check_names(src))


def readable(path: Path, label: str, consequence: str) -> str | None:
    """Return the source, or None after reporting why the group cannot pass."""
    if not path.is_file():
        fail_(f"{label} {path.relative_to(ROOT)} missing")
        fail_(consequence)
        return None
    src = path.read_text(encoding="utf-8", errors="replace")
    if not src.strip():
        fail_(f"{label} {path.relative_to(ROOT)} is empty")
        fail_(consequence)
        return None
    return src


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


def check_overlay() -> None:
    src = readable(
        OVERLAY,
        "overlay test",
        "native prefix 09 02 06 35 8D 35 8B 08 22 25 87 unchanged after "
        "overlay and HID sizeof 0x87 not asserted",
    )
    if src is None:
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

    # Count-1 AC Pan before Wheel, and no Count-2 inherit, published as
    # checks rather than grepped as bytes — see the module docstring.
    want_shape = {
        "HID_COUNT1_BEFORE_WHEEL",
        "HID_HAS_0A_38_02",
        "HID_ACPAN_THEN_WHEEL",
        "OVERLAY_COUNT1_BEFORE_WHEEL",
        "OVERLAY_HAS_0A_38_02",
        "OVERLAY_ACPAN_THEN_WHEEL",
    }
    gap = missing(src, want_shape)
    if gap:
        fail_(
            "overlay test no longer publishes "
            + ", ".join(gap)
            + " — Count-1 AC Pan before Wheel (Count-2 Wheel inherit is "
            "ExpertHid CHANGES-NEEDED) is unasserted"
        )
    else:
        pass_(
            "overlay test publishes Count 1 + AC Pan before Wheel for the "
            "parsed blob and for the overlaid region"
        )

    want_f1 = {"HID_HAS_85_F1", "OVERLAY_HAS_85_F1"}
    gap = missing(src, want_f1)
    compact = re.sub(r"[\s,xX\\]", "", src.upper())
    if gap or "85F1" not in compact:
        fail_(
            "overlay test does not publish HID_HAS_85_F1 / OVERLAY_HAS_85_F1 "
            "for Feature report 85 F1"
        )
    else:
        pass_("overlay test publishes Feature 85 F1 for blob and overlay")

    # Issue #48: the overlay now has two sources and both must be proven
    # same-size, with the SDP length stores untouched either way.
    want_hires = {
        "HID_SIZE_0x87",
        "ONLY_135_BYTES_DIFFER",
        "PREFIX_UNCHANGED",
        "SDP_LEN_STORES_UNTOUCHED",
        "HIRES_SAME_SIZE_AS_CLASSIC",
    }
    gap = missing(src, want_hires)
    runs_both = "g_HidDescriptorHiRes" in src and '"HIRES_"' in src
    if gap or not runs_both:
        fail_(
            "overlay test does not run the same-size overlay for both "
            "descriptors: missing "
            + (", ".join(gap) if gap else "the HIRES_ pass over "
               "g_HidDescriptorHiRes")
        )
    else:
        pass_(
            "overlay test runs the overlay for g_HidDescriptor and "
            "g_HidDescriptorHiRes: both 0x87, prefix and SDP length stores "
            "untouched, only 135 bytes differ"
        )


def check_hid_acl() -> None:
    src = readable(
        TEST,
        "host test",
        "0x90 passthrough and 6-byte no-grow not asserted against "
        "AclTranslate.c / Driver.c",
    )
    if src is None:
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

    gap = missing(
        src,
        {
            "BATTERY_PASSTHROUGH",
            "NO_GROW_WITHOUT_CAPACITY",
            "NO_GROW_WITHOUT_SDP",
            "WHEEL_ON_0x12",
            "C_SOURCE_ACL_CONTRACT",
        },
    )
    if gap:
        fail_("host test no longer publishes " + ", ".join(gap))
    else:
        pass_(
            "host test publishes BATTERY_PASSTHROUGH / NO_GROW_* / "
            "WHEEL_ON_0x12 / C_SOURCE_ACL_CONTRACT"
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

    src = readable(
        BSOD,
        "BSOD regression test",
        "090126-18750 / BSOD_50 / buf[4] / HID 0x87 / applewirelessmouse "
        "not asserted",
    )
    if src is None:
        return

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

    gap = missing(
        src,
        {
            "BSOD_50_HID_NOT_108",
            "BSOD_50_RTLCOPY_ONLY",
            "BSOD_50_PREFIX_IN_C",
            "BSOD_50_NEWLEN_UNCHANGED",
            "BSOD_50_NO_BUF4_STORE",
        },
    )
    if gap:
        fail_("BSOD regression no longer publishes " + ", ".join(gap))
    else:
        pass_(
            "BSOD regression publishes BSOD_50_HID_NOT_108 / RTLCOPY_ONLY / "
            "PREFIX_IN_C / NEWLEN_UNCHANGED / NO_BUF4_STORE"
        )

    # The 0x50 cause was a descriptor whose size did not match the SDP length
    # store. With two descriptors, sizing only the first one re-opens it.
    counts_both = "g_HidDescriptorHiRes" in src and "g_HidDescriptor" in src
    if counts_both:
        pass_(
            "BSOD regression sizes both g_HidDescriptor and "
            "g_HidDescriptorHiRes against 0x87"
        )
    else:
        fail_(
            "BSOD regression does not size g_HidDescriptorHiRes — the second "
            "overlay source could drift off 0x87 unchecked (090126-18750 class)"
        )


def check_mt() -> None:
    src = readable(
        MT,
        "MT enable test",
        "Linux feature_mt_mouse2 F1 02 01 / wire 53 F1 02 01 not asserted "
        "against Driver.c",
    )
    if src is None:
        return

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

    gap = missing(
        src,
        {"MT_ENABLE_F1_02_01", "MT_ENABLE_WIRE_53", "MT_ENABLE_AFTER_SDP"},
    )
    if gap:
        fail_("MT enable test no longer publishes " + ", ".join(gap))
    else:
        pass_(
            "MT enable test publishes MT_ENABLE_F1_02_01 / WIRE_53 / AFTER_SDP"
        )

    # Issue #48 added a second site that handles SET_REPORT(Feature, 0xF1):
    # the hi-res payload repair. The enable packet must still be proven
    # inside MmSendMtEnable, not anywhere in the file.
    scoped = search(src, r"MmSendMtEnable") and search(
        src, r"_function_body\(\s*code\s*,\s*[\"']MmSendMtEnable[\"']\s*\)"
    )
    if scoped:
        pass_(
            "MT enable test scopes 53 F1 02 01 to MmSendMtEnable's own body "
            "(the hi-res 0xF1 repair cannot green it)"
        )
    else:
        fail_(
            "MT enable test searches the whole of Driver.c for 53 F1 02 01 — "
            "the issue #48 SET_REPORT(Feature, 0xF1) repair would green it "
            "even with MmSendMtEnable gone"
        )


def check_scroll_threshold() -> None:
    # Do not green because this file mentions SCROLL_STEP_8.
    src = readable(
        SCROLL_THRESHOLD,
        "scroll threshold test",
        "SCROLL_STEP_8 not quoted against GestureEngine.c",
    )
    if src is None:
        return

    if "SCROLL_STEP_8" in src and "GestureEngine.c" in src:
        pass_(
            "test_scroll_threshold.py quotes SCROLL_STEP_8 against GestureEngine.c"
        )
    else:
        fail_(
            "test_scroll_threshold.py does not quote SCROLL_STEP_8 / GestureEngine.c"
        )

    gap = missing(
        src,
        {
            "SCROLL_STEP_8",
            "DOWN_LT_2",
            "TWO_FINGER",
            "MM_SCROLL_STEP_DEFAULT",
            "SCROLL_STEP_CLAMP_LOW",
            "SCROLL_STEP_CLAMP_HIGH",
            "TWO_FINGER_TRAVEL_NOTCHES",
        },
    )
    if gap:
        fail_("test_scroll_threshold.py no longer publishes " + ", ".join(gap))
    else:
        pass_(
            "test_scroll_threshold.py publishes SCROLL_STEP_8 / DOWN_LT_2 / "
            "TWO_FINGER / the ULONG clamp pair / TWO_FINGER_TRAVEL_NOTCHES"
        )

    # The detent moved into DetentUnits. The source binding must follow it,
    # or SCROLL_STEP_8 degrades to a token hunt in a comment.
    if "DetentUnits" in src:
        pass_(
            "test_scroll_threshold.py binds the detent to DetentUnits, where "
            "AccumulateSurfaceScroll now computes it"
        )
    else:
        fail_(
            "test_scroll_threshold.py does not mention DetentUnits — the "
            "detent assertion is no longer bound to the code that emits"
        )


def check_hires() -> None:
    src = readable(
        HIRES,
        "hi-res scroll test",
        "issue #48 Resolution Multiplier descriptor, gain equivalence and "
        "0xF1 payload repair not asserted",
    )
    if src is None:
        return

    # 1. The descriptor is proven by parsing, not by substring search.
    parses = (
        reads_driver_source(src, "HidDescriptor.c")
        and "g_HidDescriptorHiRes" in src
        and search(src, r"def\s+parse_items\s*\(")
        and search(src, r"def\s+walk_descriptor\s*\(")
        and search(src, r"\(\s*0\s*,\s*1\s*,\s*2\s*,\s*4\s*\)")
    )
    gap = missing(
        src,
        {
            "HIRES_DESC_BOTH_0x87",
            "HIRES_DESC_ITEMS_PARSE",
            "HIRES_DESC_COLLECTIONS_BALANCED",
            "HIRES_MULTIPLIER_IS_FEATURE",
            "HIRES_MULTIPLIER_IN_LOGICAL_COLLECTION",
            "HIRES_MULTIPLIER_RANGE_1_4",
            "HIRES_MULTIPLIER_MATCHES_HEADER",
            "HIRES_REPORT_12_LAYOUT_IDENTICAL",
            "HIRES_REPORT_F1_TWO_BYTES",
            "HIRES_COL02_BATTERY_UNCHANGED",
        },
    )
    if parses and not gap:
        pass_(
            "hi-res test parses both descriptors as HID items (short-item "
            "bSize 0/1/2/3 -> 0/1/2/4) and publishes the multiplier, "
            "collection, report 0x12, report 0xF1 and COL02 checks"
        )
    else:
        fail_(
            "hi-res test does not prove the descriptor by parsing it: "
            + (", ".join(gap) if gap else "no parse_items / walk_descriptor / "
               "short-item size table over HidDescriptor.c")
        )

    # 2. Gain equivalence is measured against the host model, not asserted
    #    in prose, and the sub-detent / truncation cases are covered.
    gap = missing(
        src,
        {
            "HIRES_DETENT_IS_STEP_OVER_MULTIPLIER",
            "HIRES_DEFAULT_IS_CLASSIC",
            "HIRES_GAIN_EXACT_ON_MULTIPLE",
            "HIRES_NEVER_DELIVERS_LESS",
            "HIRES_RESIDUE_SMALLER",
            "HIRES_MORE_SMALLER_STEPS",
            "HIRES_SUBDETENT_NUDGE_EMITS",
            "HIRES_FLICK_NOT_COLLAPSED",
            "HIRES_NEGATIVE_MIRRORS",
            "HIRES_TRUNCATES_TOWARD_ZERO",
        },
    )
    uses_model = (
        search(src, r"from\s+hostmodel\s+import")
        and "detent_units" in src
        and "MM_HIRES_MULTIPLIER" in src
        and "WHEEL_DELTA" in src
    )
    if uses_model and not gap:
        pass_(
            "hi-res test measures gain equivalence through hostmodel "
            "(exact on a detent multiple, never worse otherwise, smaller "
            "residue, sub-detent nudge, flick, negative, truncate-to-zero)"
        )
    else:
        fail_(
            "hi-res test does not measure gain equivalence against the host "
            "model: "
            + (", ".join(gap) if gap else "no hostmodel detent_units / "
               "MM_HIRES_MULTIPLIER / WHEEL_DELTA")
        )

    # 3. The 0xF1 payload repair, both directions.
    gap = missing(
        src,
        {
            "HIRES_C_DETENT_UNITS",
            "HIRES_C_STEP_DIVIDE",
            "HIRES_C_F1_REPAIR",
            "HIRES_C_F1_REPAIR_CONSTANTS",
            "HIRES_F1_REPAIR_VECTORS",
            "HIRES_MT_ENABLE_LITERAL",
            "HIRES_SDP_BOTH_SIZES_VALIDATED",
            "HIRES_SDP_CTX_FLAG_PASSED",
            "HIRES_INF_DEFAULT_0",
            "HIRES_CTX_DEFAULT_FALSE",
        },
    )
    reads_c = (
        reads_driver_source(src, "Driver.c")
        and reads_driver_source(src, "Driver.h")
        and reads_driver_source(src, "InputHandler.c")
        and reads_driver_source(src, "GestureEngine.c")
    )
    if reads_c and not gap:
        pass_(
            "hi-res test binds the 0xF1 repair, the SdpRewrite_Process "
            "two-size guard and the HiResScroll defaults to driver source, "
            "and proves the repair is unreachable with HiResScroll off"
        )
    else:
        fail_(
            "hi-res test does not bind the 0xF1 repair / SDP selection / "
            "HiResScroll defaults to driver source: "
            + (", ".join(gap) if gap else "does not read Driver.c, Driver.h, "
               "InputHandler.c and GestureEngine.c")
        )

    # 4. A gate nobody runs is not a gate.
    if not AGENTS.is_file():
        fail_("AGENTS.md missing — cannot confirm the documented test command")
        return
    agents = AGENTS.read_text(encoding="utf-8", errors="replace")
    line = next(
        (
            ln
            for ln in agents.splitlines()
            if "specs/gate_4.py" in ln and "python3" in ln
        ),
        "",
    )
    wanted = [
        "specs/gate_4.py",
        "v2-kmdf-driver/tests/test_bsod_regress.py",
        "v2-kmdf-driver/tests/test_hid_acl.py",
        "v2-kmdf-driver/tests/test_mt_enable.py",
        "v2-kmdf-driver/tests/test_scroll_threshold.py",
        "v2-kmdf-driver/tests/test_sdp_overlay.py",
        "v2-kmdf-driver/tests/test_two_finger_scroll.py",
        "v2-kmdf-driver/tests/test_hires_scroll.py",
    ]
    absent = [name for name in wanted if name not in line]
    if line and not absent:
        pass_(
            "AGENTS.md documents one test command line that runs every gate, "
            "test_hires_scroll.py included"
        )
    else:
        fail_(
            "AGENTS.md test command line does not run "
            + (", ".join(absent) if absent else "any gate (line not found)")
        )


def main() -> int:
    # Unique INF / dest / SCM / HidDescriptor already present at 7087f4b.
    # Checking them here would green this gate on a tautology.
    check_overlay()
    check_hid_acl()
    check_bsod()
    check_mt()
    check_scroll_threshold()
    check_hires()
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
