#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
BSOD regression — named after dumps, not a host SdpWalkStream.

0x50  090126-17390-01.dmp / 090126-18750-01.dmp
      IMAGE_NAME BTHport.sys  SYMBOL_NAME BTHport!SdpWalkStream+57
      Cause: 108-byte g_HidDescriptor + PatchSdpHidDescriptor length
      rewrite (0x25 / 0x35 / 0x36 / buf[4]). Overlay memcpy 135 only.

Event 41  unsigned activate / live SCM hijack / 6→8 without capacity.

0xD1  PATH-A applewirelessmouse.sys.

No WDK. No .sys load. Exit 0 only if every check prints PASS:.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HID_C = ROOT / "HidDescriptor.c"
IH_C = ROOT / "InputHandler.c"
ACL_C = ROOT / "AclTranslate.c"
DRV_C = ROOT / "Driver.c"
INF = ROOT / "MagicMouseDriver-kmdf-204-scroll.inf"
INSTALL = ROOT / "Install-KMDF.ps1"
COMMON = ROOT / "scripts" / "Kmdf-Common.ps1"


def _code(text: str) -> str:
    """Strip // and /* */ so comment mentions of buf[4] are not stores."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


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


def hid_len() -> int:
    text = HID_C.read_text(encoding="utf-8")
    marker = "g_HidDescriptor[]"
    rest = text.split(marker, 1)[1]
    body = rest.split("{", 1)[1].split("};", 1)[0]
    stripped = re.sub(r"//.*?$", "", body, flags=re.M)
    nums = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})\b", stripped)]
    return len(nums)


def main() -> int:
    run = _Run()
    ih = IH_C.read_text(encoding="utf-8") if IH_C.is_file() else ""
    hid_c = HID_C.read_text(encoding="utf-8") if HID_C.is_file() else ""
    acl = ACL_C.read_text(encoding="utf-8") if ACL_C.is_file() else ""
    drv = DRV_C.read_text(encoding="utf-8") if DRV_C.is_file() else ""
    inf = INF.read_text(encoding="utf-8") if INF.is_file() else ""
    inst = INSTALL.read_text(encoding="utf-8") if INSTALL.is_file() else ""
    common = COMMON.read_text(encoding="utf-8") if COMMON.is_file() else ""
    ih_code = _code(ih)

    # --- 0x50 SdpWalkStream (090126-18750 / 090126-17390) ---
    n = hid_len() if HID_C.is_file() else -1
    run.check(
        "BSOD_50_HID_NOT_108",
        n == 0x87,
        f"sizeof={n} dumps=090126-17390-01,090126-18750-01",
    )
    run.check(
        "BSOD_50_C_ASSERT_0x87",
        "0x87" in hid_c and "C_ASSERT" in hid_c,
        "HidDescriptor.c C_ASSERT sizeof == 0x87",
    )
    run.check(
        "BSOD_50_NO_BUF4_STORE",
        "buf[4]" not in ih_code,
        "InputHandler.c must not write AttributeLists buf[4]",
    )
    run.check(
        "BSOD_50_NO_PATCHSDP",
        "PatchSdpHidDescriptor" not in ih and "PatchSdpHidDescriptor" not in drv,
        "length-rewrite helper must stay gone",
    )
    run.check(
        "BSOD_50_NO_BUF_ASSIGN",
        re.search(r"buf\s*\[[^\]]+\]\s*=", ih) is None,
        "InputHandler.c writes only via RtlCopyMemory",
    )
    run.check(
        "BSOD_50_RTLCOPY_ONLY",
        "RtlCopyMemory" in ih and "g_HidDescriptor" in ih,
        "memcpy overlay of g_HidDescriptor",
    )
    run.check(
        "BSOD_50_PREFIX_IN_C",
        "0x09, 0x02, 0x06" in ih and "0x25, 0x87" in ih,
        "native prefix 09 02 06 … 25 87 (do not rewrite 0x25)",
    )
    run.check(
        "BSOD_50_NEWLEN_UNCHANGED",
        "*newLen=usedLen" in ih.replace(" ", "").replace("\t", ""),
        "Δ=0; *newLen stays usedLen",
    )

    # --- Event 41 ---
    run.check(
        "BSOD_41_SDP_GATE",
        "SdpPatchSuccess" in drv and "sdpOk" in drv,
        "Driver.c must not grow 6→8 unless overlay succeeded",
    )
    run.check(
        "BSOD_41_CAPACITY",
        re.search(r"capacity\s*<\s*need|capacity\s*<", acl) is not None
        and "MmGetMdlByteCount" in drv,
        "AclTranslate capacity<need; Driver uses MDL byte count not BufferSize",
    )
    run.check(
        "BSOD_41_UNIQUE_SCM",
        "MagicMouseDriver204Scroll" in inf
        and re.search(r"AddService\s*=\s*MagicMouseDriver\s*,", inf) is None,
        "live MagicMouseDriver SCM hijack is Event 41",
    )
    run.check(
        "BSOD_41_INSTALL_REFUSES_UNSIGNED",
        "unsigned" in inst.lower() and "16940C0F" in inst,
        "Install-KMDF.ps1 must throw on unsigned .sys",
    )
    run.check(
        "BSOD_41_NO_SYSTEM32_COPY",
        "Copy-Item" not in inst or "System32" in inst and "Does not Copy-Item" in inst,
        "no Copy-Item onto System32/DriverStore",
    )

    # --- 0xD1 PATH-A ---
    dest_ok = "MagicMouseDriver-kmdf-204-scroll.sys" in inf
    patha = re.search(
        r"CopyFiles.*applewirelessmouse|ServiceBinary.*applewirelessmouse",
        inf,
        re.I,
    )
    patha_ban = (
        "applewirelessmouse" in common.lower()
        and "Test-KmdfForbiddenSys" in inst
    )
    run.check(
        "BSOD_D1_NO_PATHA",
        dest_ok and patha is None and patha_ban,
        "unique dest; PATH-A applewirelessmouse refused in Kmdf-Common + install",
    )

    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
