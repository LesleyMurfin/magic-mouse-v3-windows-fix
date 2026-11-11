#!/usr/bin/env python3
"""Spec 4 executable gate — unique 2.0.4.6 KMDF scroll + 135-byte SDP overlay.

RED-first. Unique INF / kernel already at 7087f4b is not a pass (tautology).
Keyword presence in a Python self-model is not a pass.

This gate RUNS the seven host gate tests as subprocesses and pins the check
names each one prints. A check that is deleted, renamed, commented out or
quietly skipped stops being printed, so it turns this red; prose that
survives the deletion cannot green it. The names are compared exactly as
printed, which also covers the f-string-composed names (`f"{tag}HID_C_PARSE"`
-> HIRES_HID_C_PARSE) that a source grep for check("...") never sees. Any
non-zero exit from a gate test is a failure here too.

What this gate deliberately does NOT do: re-assert the driver contracts, or
grep the test sources for tokens. The tests own the contracts — descriptor
parsing, gain equivalence, the 0xF1 repair, the 135-byte overlay — and this
file owns the fact that they all still run and still publish their results.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "v2-kmdf-driver" / "tests"
WALK = TESTS / "test_sdp_walk.py"
MT = TESTS / "test_mt_enable.py"

RESULT_LINE = re.compile(r"^(?:PASS|FAIL): ([A-Za-z0-9_]+)", re.MULTILINE)
FAIL_LINE = re.compile(r"^FAIL: ([A-Za-z0-9_]+)", re.MULTILINE)

# Every name each gate test must still print. Produced by running them; keep
# it in step with the tests, never by relaxing it to what happens to pass.
EXPECTED: dict[str, frozenset[str]] = {
    "v2-kmdf-driver/tests/test_sdp_overlay.py": frozenset(
        {
            # classic g_HidDescriptor blob + the overlaid region
            "HID_ACPAN_THEN_WHEEL",
            "HID_COUNT1_BEFORE_WHEEL",
            "HID_C_PARSE",
            "HID_HAS_09_38",
            "HID_HAS_0A_38_02",
            "HID_HAS_85_90",
            "HID_HAS_85_F1",
            "HID_NO_85_02",
            "HID_NO_85_47",
            "HID_SIZE_0x87",
            "MISSING_PREFIX_NO_MUTATION",
            "NATIVE_351_LEN",
            "NATIVE_ENDS_09020E2801",
            "NATIVE_HID_FITS",
            "NATIVE_HID_LEN_0x87",
            "NATIVE_STARTS_36015C",
            "ONLY_135_BYTES_DIFFER",
            "OVERLAY_ACPAN_THEN_WHEEL",
            "OVERLAY_APPLIED",
            "OVERLAY_COPIED_135",
            "OVERLAY_COUNT1_BEFORE_WHEEL",
            "OVERLAY_HAS_09_38",
            "OVERLAY_HAS_0A_38_02",
            "OVERLAY_HAS_85_90",
            "OVERLAY_HAS_85_F1",
            "OVERLAY_LEN_351",
            "OVERLAY_NO_85_02",
            "OVERLAY_NO_85_47",
            "PREFIX_PRESENT",
            "PREFIX_UNCHANGED",
            # issue #48: the same pass re-run over g_HidDescriptorHiRes
            "HIRES_HAS_09_48",
            "HIRES_HID_ACPAN_THEN_WHEEL",
            "HIRES_HID_COUNT1_BEFORE_WHEEL",
            "HIRES_HID_C_PARSE",
            "HIRES_HID_HAS_09_38",
            "HIRES_HID_HAS_0A_38_02",
            "HIRES_HID_HAS_85_90",
            "HIRES_HID_HAS_85_F1",
            "HIRES_HID_NO_85_02",
            "HIRES_HID_NO_85_47",
            "HIRES_HID_SIZE_0x87",
            "HIRES_IS_A_DIFFERENT_BLOB",
            "HIRES_MISSING_PREFIX_NO_MUTATION",
            "HIRES_ONLY_135_BYTES_DIFFER",
            "HIRES_OVERLAY_ACPAN_THEN_WHEEL",
            "HIRES_OVERLAY_APPLIED",
            "HIRES_OVERLAY_COPIED_135",
            "HIRES_OVERLAY_COUNT1_BEFORE_WHEEL",
            "HIRES_OVERLAY_HAS_09_38",
            "HIRES_OVERLAY_HAS_0A_38_02",
            "HIRES_OVERLAY_HAS_85_90",
            "HIRES_OVERLAY_HAS_85_F1",
            "HIRES_OVERLAY_LEN_351",
            "HIRES_OVERLAY_NO_85_02",
            "HIRES_OVERLAY_NO_85_47",
            "HIRES_PREFIX_UNCHANGED",
        }
    ),
    "v2-kmdf-driver/tests/test_hid_acl.py": frozenset(
        {
            "BATTERY_PASSTHROUGH",
            "C_SOURCE_ACL_CONTRACT",
            "C_SOURCE_ACL_RESIDUE",
            "C_SOURCE_CONTROL_CHANNEL_GATE",
            "C_SOURCE_CONTROL_CHANNEL_LATCH",
            "NO_FEATURE_47",
            "NO_GROW_WITHOUT_CAPACITY",
            "NO_GROW_WITHOUT_SDP",
            "UNIQUE_SCM",
            "WHEEL_NOTCH_ACROSS_REPORTS",
            "WHEEL_ON_0x12",
        }
    ),
    "v2-kmdf-driver/tests/test_bsod_regress.py": frozenset(
        {
            "BSOD_41_CAPACITY",
            "BSOD_41_INSTALL_REFUSES_UNSIGNED",
            "BSOD_41_NO_SYSTEM32_COPY",
            "BSOD_41_SDP_GATE",
            "BSOD_41_UNIQUE_SCM",
            "BSOD_50_HID_NOT_108",
            "BSOD_50_NEWLEN_UNCHANGED",
            "BSOD_50_NO_BUF4_STORE",
            "BSOD_50_NO_BUF_ASSIGN",
            "BSOD_50_NO_PATCHSDP",
            "BSOD_50_PREFIX_IN_C",
            "BSOD_50_RTLCOPY_ONLY",
            "BSOD_D1_NO_PATHA",
            "BSOD_OOB_READ_PARSE_LEN",
        }
    ),
    "v2-kmdf-driver/tests/test_mt_enable.py": frozenset(
        {
            "MT_ENABLE_ACL_BYTES",
            "MT_ENABLE_AFTER_SDP",
            "MT_ENABLE_F1_02_01",
            "MT_ENABLE_WIRE_53",
        }
    ),
    "v2-kmdf-driver/tests/test_scroll_threshold.py": frozenset(
        {
            "COMPACT_GARBAGE_NO_WHEEL",
            "COMPACT_NO_NATIVE_WHEEL",
            "DOWN_LT_2",
            "FRONT_GATE_FOREIGN_RID_0x11",
            "FRONT_GATE_SHORT_5",
            "FRONT_GATE_UNALIGNED_18",
            "MM_SCROLL_STEP_DEFAULT",
            "ONE_SLOT_DRAG_15",
            "ONE_SLOT_DRAG_16",
            "ONE_SLOT_DRAG_20",
            "SCROLL_STEP_8",
            "SCROLL_STEP_CLAMP_HIGH",
            "SCROLL_STEP_CLAMP_LOW",
            "TWO_FINGER",
            "TWO_FINGER_TRAVEL_NOTCHES",
        }
    ),
    "v2-kmdf-driver/tests/test_two_finger_scroll.py": frozenset(
        {
            "COMPACT_GARBAGE_NO_WHEEL",
            "COMPACT_NO_NATIVE_WHEEL",
            "DOWN_LT_2",
            "ONE_FINGER_ANCHOR_REFRESH",
            "ONE_FINGER_DRAG_NO_WHEEL",
            "ONE_FINGER_TRAVEL_NOT_BANKED",
            "PINCH_EMITS_NOTHING",
            "STATIONARY_LOW_ID_STILL_SCROLLS",
            "TWO_FINGER",
            "TWO_FINGER_START_DRAG_WHEEL",
        }
    ),
    "v2-kmdf-driver/tests/test_hires_scroll.py": frozenset(
        {
            "HIRES_ACPAN_MIRRORS_WHEEL",
            "HIRES_COL02_BATTERY_UNCHANGED",
            "HIRES_CTX_DEFAULT_FALSE",
            "HIRES_C_DETENT_UNITS",
            "HIRES_C_F1_FORCED_COUNTER",
            "HIRES_C_F1_REPAIR",
            "HIRES_C_F1_REPAIR_CONSTANTS",
            "HIRES_C_HOST_MULTIPLIER_CAPTURED",
            "HIRES_C_REPORT_SATURATION_CAP",
            "HIRES_C_STEP_DIVIDE",
            "HIRES_DESC_BOTH_0x87",
            "HIRES_DESC_COLLECTIONS_BALANCED",
            "HIRES_DESC_ITEMS_PARSE",
            "HIRES_DETENT_IS_STEP_OVER_HOST_MULTIPLIER",
            "HIRES_FLICK_NOT_COLLAPSED",
            "HIRES_GAIN_EXACT_ON_MULTIPLE",
            "HIRES_INF_WRITES_NO_HIRES_VALUE",
            "HIRES_MORE_SMALLER_STEPS",
            "HIRES_MULTIPLIER_IN_LOGICAL_COLLECTION",
            "HIRES_MULTIPLIER_IS_FEATURE",
            "HIRES_MULTIPLIER_MATCHES_HEADER",
            "HIRES_MULTIPLIER_RANGE_1_4",
            "HIRES_NEGATIVE_MIRRORS",
            "HIRES_NEVER_DELIVERS_LESS",
            "HIRES_REPORT_12_LAYOUT_IDENTICAL",
            "HIRES_REPORT_F1_TWO_BYTES",
            "HIRES_REPORT_SATURATION_KEPT_IN_ANCHOR",
            "HIRES_RESIDUE_SMALLER",
            "HIRES_SDP_CTX_FLAG_PASSED",
            "HIRES_STEP_ROUNDS_TO_NEAREST",
            "HIRES_SUBDETENT_NUDGE_EMITS",
            "HIRES_TRUNCATES_TOWARD_ZERO",
            "HIRES_UNARMED_HOST_NOT_FASTER",
        }
    ),
}

fails = 0


def pass_(msg: str) -> None:
    print(f"PASS: {msg}")


def fail_(msg: str) -> None:
    global fails
    fails += 1
    print(f"FAIL: {msg}")


def run_gate(rel: str, required: frozenset[str]) -> None:
    """Run one gate test and compare the names it printed with `required`."""
    path = ROOT / rel
    if not path.is_file():
        fail_(f"{rel} missing — {len(required)} checks are unasserted")
        return

    proc = subprocess.run(
        [sys.executable, str(path)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    printed = set(RESULT_LINE.findall(proc.stdout))
    gone = sorted(required - printed)
    if gone:
        fail_(f"{rel} no longer prints " + ", ".join(gone))
    else:
        pass_(f"{rel} prints all {len(required)} required checks")

    if proc.returncode == 0:
        pass_(f"{rel} exits 0 ({len(printed)} checks)")
    else:
        failed = sorted(set(FAIL_LINE.findall(proc.stdout)))
        detail = ", ".join(failed) if failed else (
            proc.stderr.strip().splitlines() or ["no output"]
        )[-1]
        fail_(f"{rel} exits {proc.returncode}: {detail}")


def check_walk_absent() -> None:
    """Survivor: no gate test is run from a file that does not exist, so only
    a source check can keep a resurrected test_sdp_walk.py from re-gating the
    108-byte length rewrite that caused 090126-18750 (0x50)."""
    if not WALK.is_file():
        pass_("test_sdp_walk.py absent (no host SdpWalkStream)")
        return
    src = WALK.read_text(encoding="utf-8", errors="replace")
    if "PATCHED_0x25_IS_108" in src or "HID_DESC_108" in src:
        fail_(
            "test_sdp_walk.py gates the 108-byte length rewrite "
            "(090126-18750 0x50) — delete it; the overlay and "
            "test_bsod_regress.py own that length now"
        )
    else:
        pass_("test_sdp_walk.py is not a 108-byte rewrite gate")


def check_mt_scoped() -> None:
    """Survivor: MT_ENABLE_WIRE_53 passing says the bytes 53 F1 02 01 were
    found, not where — issue #48 added a second SET_REPORT(Feature, 0xF1)
    site to Driver.c, so only the source proves the search is still scoped to
    MmSendMtEnable's own body."""
    if not MT.is_file():
        return  # run_gate already reported the missing file
    src = MT.read_text(encoding="utf-8", errors="replace")
    if re.search(
        r"_function_body\(\s*code\s*,\s*[\"']MmSendMtEnable[\"']\s*\)", src
    ):
        pass_(
            "test_mt_enable.py scopes 53 F1 02 01 to MmSendMtEnable's own "
            "body (the hi-res 0xF1 repair cannot green it)"
        )
    else:
        fail_(
            "test_mt_enable.py searches the whole of Driver.c for "
            "53 F1 02 01 — the issue #48 SET_REPORT(Feature, 0xF1) repair "
            "would green it even with MmSendMtEnable gone"
        )


def main() -> int:
    # Unique INF / dest / SCM / HidDescriptor already present at 7087f4b.
    # Checking them here would green this gate on a tautology.
    for rel, required in EXPECTED.items():
        run_gate(rel, required)
    check_walk_absent()
    check_mt_scoped()
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
