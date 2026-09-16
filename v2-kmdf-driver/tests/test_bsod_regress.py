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


# Anything that can land bytes at a DESTINATION, including the forms that
# hide the destination: `cmd /c copy`, `cmd /c mklink`, hard/symbolic links,
# and a raw byte write. pnputil /add-driver is the only permitted install
# path (contract 6).
_COPY_VERB = re.compile(
    r"Copy-Item|Move-Item|Set-Content"
    r"|New-Item[^\r\n]*?-ItemType\s+(?:Hard|Symbolic)Link"
    r"|\[(?:System\.)?IO\.File\]::(?:Copy|Move|WriteAll\w+)"
    r"|\bcmd(?:\.exe)?\s*/c\b|\bmklink\b"
    r"|\bcopy\b|\bxcopy\b|\brobocopy\b",
    re.I,
)

# Destinations no script may write: the live driver directory or the
# DriverStore.
_BANNED_DEST = re.compile(r"System32[\\/]+drivers|DriverStore", re.I)

_ASSIGN = re.compile(
    r"^\s*\$(?:script:|global:|local:|private:)?(\w+)\s*=\s*(.+?)\s*;?\s*$"
)
_VAR = re.compile(r"\$(?:\{(\w+)\}|(\w+))")
_CMD_COMMENT = re.compile(r"^\s*(?:@?rem\b|::)", re.I)


def _glue(text: str) -> str:
    """Splice path fragments the way Join-Path splices them.

    `Join-Path $root 'System32' | Join-Path -ChildPath 'drivers'` becomes
    `$root\\System32\\drivers`, so a destination assembled from pieces still
    shows the banned path on one line.
    """
    # `\b` does not exist between a space and a dash, so parameter names get
    # their own alternative.
    text = re.sub(
        r"(?i)\bJoin-Path\b"
        r"|-(?:ChildPath|LiteralPath|Path|Destination|Target|Value|Resolve)\b",
        " ",
        text,
    )
    return re.sub(r"[\s,;'\"()|&+]+", lambda _: "\\", text).strip("\\")


def _subst(text: str, variables: dict[str, str]) -> str:
    """Resolve simple literal variable assignments seen earlier in the file."""

    def repl(hit: re.Match[str]) -> str:
        name = (hit.group(1) or hit.group(2)).lower()
        return variables.get(name, hit.group(0))

    for _ in range(3):
        expanded = _VAR.sub(repl, text)
        if expanded == text:
            break
        text = expanded
    return text


def _script_lines(text: str, cmd_syntax: bool) -> list[tuple[str, str]] | None:
    """Logical lines as (code, code-with-string-contents-blanked), or None.

    Comments can neither green nor red the gate: PowerShell `#` and nested
    `<# #>`, and cmd `REM` / `::`, are removed. String CONTENTS are blanked
    in the second element, so a guard message ("Refusing: this would copy
    onto ...System32\\drivers") carries no verb, while the first element
    keeps the literal so a real destination is still visible. Backtick (and
    cmd caret) line continuations are joined, so a command split from its
    destination is still one line. None = unparseable; the caller must fail.
    """
    if cmd_syntax:
        text = "\n".join(
            "" if _CMD_COMMENT.match(line) else line for line in text.splitlines()
        )

    code: list[str] = []
    blank: list[str] = []
    i = 0
    n = len(text)
    depth = 0
    while i < n:
        ch = text[i]
        if depth:
            if text.startswith("<#", i):
                depth += 1
                i += 2
                continue
            if text.startswith("#>", i):
                depth -= 1
                i += 2
                continue
            code.append("\n" if ch == "\n" else " ")
            blank.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if text.startswith("<#", i):
            depth += 1
            i += 2
            continue
        if ch == "#" and (i == 0 or text[i - 1] != "`"):
            # Line comment: a stray `#>` in prose lands here, not in a block.
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "@" and i + 1 < n and text[i + 1] in "'\"":
            quote = text[i + 1]
            end = text.find(quote + "@", i + 2)
            if end < 0:
                return None
            body = text[i : end + 2]
            code.extend(body)
            blank.extend("\n" if c == "\n" else " " for c in body)
            i = end + 2
            continue
        if ch in "'\"":
            j = i + 1
            while j < n:
                if ch == '"' and text[j] == "`":
                    j += 2
                    continue
                if text[j] == ch:
                    if j + 1 < n and text[j + 1] == ch:
                        j += 2
                        continue
                    break
                j += 1
            if j >= n:
                return None
            body = text[i : j + 1]
            code.extend(body)
            blank.append(ch)
            blank.extend("\n" if c == "\n" else " " for c in body[1:-1])
            blank.append(ch)
            i = j + 1
            continue
        code.append(ch)
        blank.append(ch)
        i += 1
    if depth:
        return None

    joined = "".join(code)
    cont = re.compile(r"[`^][ \t]*\r?\n[ \t]*" if cmd_syntax else r"`[ \t]*\r?\n[ \t]*")
    spans = [m.span() for m in cont.finditer(joined)]

    def splice(raw: str) -> str:
        out: list[str] = []
        prev = 0
        for start, end in spans:
            out.append(raw[prev:start])
            out.append(" ")
            prev = end
        out.append(raw[prev:])
        return "".join(out)

    return list(zip(splice(joined).splitlines(), splice("".join(blank)).splitlines()))


def _copy_into_banned_dest(text: str, cmd_syntax: bool) -> tuple[str | None, str]:
    """(offending line, detail). Line is None when the script is clean."""
    lines = _script_lines(text, cmd_syntax)
    if lines is None:
        return "", "unparseable (unbalanced <# #>, here-string or quote)"
    variables: dict[str, str] = {}
    for code_line, blank_line in lines:
        assign = _ASSIGN.match(code_line)
        if assign is not None:
            variables[assign.group(1).lower()] = _glue(
                _subst(assign.group(2), variables)
            )
        # The verb must be a command, not a word inside a warning string.
        if _COPY_VERB.search(blank_line) is None:
            continue
        probe = _subst(code_line, variables)
        if _BANNED_DEST.search(probe) or _BANNED_DEST.search(_glue(probe)):
            return code_line.strip(), "destination is System32\\drivers/DriverStore"
    return None, "clean"


def script_sources() -> dict[str, str]:
    """Every .ps1/.cmd under v2-kmdf-driver, discovered — never a fixed list."""
    found: dict[str, str] = {}
    for pattern in ("*.ps1", "*.cmd"):
        for path in sorted(ROOT.rglob(pattern)):
            found[path.relative_to(ROOT).as_posix()] = path.read_text(
                encoding="utf-8", errors="replace"
            )
    return found


def no_system32_copy(sources: dict[str, str]) -> tuple[bool, str]:
    """True only if every script is parseable and copies nowhere banned."""
    if not sources:
        return False, "no .ps1/.cmd found under v2-kmdf-driver (cannot prove anything)"
    for name in sorted(sources):
        text = sources[name]
        if not text.strip():
            return False, f"{name} missing or empty (cannot prove no copy-over)"
        line, detail = _copy_into_banned_dest(text, name.lower().endswith(".cmd"))
        if line is not None:
            return False, f"{name}: {detail}: {line}"
    return (
        True,
        f"{len(sources)} scripts: no copy, link or write into "
        "System32\\drivers or the DriverStore",
    )


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
    overlay_path = _function_body(ih_code, "SdpRewrite_Process")
    copy_path = re.search(
        r"RtlCopyMemory\s*\(\s*buf\s*\+\s*descOffset\s*,\s*"
        r"g_HidDescriptor\s*,\s*SDP_HID_OVERLAY_LEN\s*\)",
        overlay_path,
    )
    prefix_path = re.search(
        r"buf\s*\[\s*i\s*\+\s*n\s*\]\s*!=\s*g_SdpHidPrefix\s*\[\s*n\s*\]",
        overlay_path,
    )
    not_found_path = re.search(
        r"if\s*\(\s*!found\s*\)\s*\{.*?STATUS_NOT_FOUND",
        overlay_path,
        re.S,
    )
    new_len_path = re.search(
        r"RtlCopyMemory\s*\([^;]+\)\s*;\s*\*newLen\s*=\s*usedLen\s*;",
        overlay_path,
        re.S,
    )

    # --- 0x50 SdpWalkStream (090126-18750 / 090126-17390) ---
    n = hid_len() if HID_C.is_file() else -1
    run.check(
        "BSOD_50_HID_NOT_108",
        n == 0x87,
        f"sizeof={n} dumps=090126-17390-01,090126-18750-01",
    )
    run.check(
        "BSOD_50_RTLCOPY_ONLY",
        copy_path is not None
        and re.search(
            r"#define\s+SDP_HID_OVERLAY_LEN\s+0x87\b", ih_code
        )
        is not None,
        "SdpRewrite_Process copies g_HidDescriptor to buf+descOffset (0x87)",
    )
    run.check(
        "BSOD_50_PREFIX_IN_C",
        prefix_path is not None and not_found_path is not None
        and "0x09, 0x02, 0x06" in ih
        and "0x25, 0x87" in ih,
        "SdpRewrite_Process scans g_SdpHidPrefix and rejects missing prefix",
    )
    run.check(
        "BSOD_50_NEWLEN_UNCHANGED",
        new_len_path is not None,
        "SdpRewrite_Process leaves *newLen equal to usedLen after copy",
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
    no_copy, copy_detail = no_system32_copy(script_sources())
    run.check("BSOD_41_NO_SYSTEM32_COPY", no_copy, copy_detail)

    # --- 0xD1 PATH-A ---
    dest_ok = "MagicMouseDriver-kmdf-204-scroll.sys" in inf
    patha = re.search(
        r"CopyFiles.*applewirelessmouse|ServiceBinary.*applewirelessmouse",
        inf,
        re.I,
    )
    patha_ban = (
        "applewirelessmouse" in common.lower()
        and "Test-KmdfForbiddenSysFile" in inst
    )
    run.check(
        "BSOD_D1_NO_PATHA",
        dest_ok and patha is None and patha_ban,
        "unique dest; PATH-A applewirelessmouse refused in Kmdf-Common + install",
    )

    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
