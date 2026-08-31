#!/usr/bin/env bash
# Linux-side package checks. Does not build a .sys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
fail=0

ok()  { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=1; }

INF="$ROOT/MagicMouseDriver-kmdf-204-scroll.inf"

echo "Validating $ROOT"

# --- unique package identity ---
if test -f "$INF"; then ok "unique INF present"; else bad "unique INF present"; fi
if test -f "$ROOT/MagicMouseDriver.inf"; then
  bad "retired MagicMouseDriver.inf must not ship (oem26 identity)"
else
  ok "retired MagicMouseDriver.inf is gone"
fi
if grep -q 'CatalogFile *= *MagicMouseDriver-kmdf-204-scroll.cat' "$INF"; then
  ok "unique CatalogFile"
else
  bad "unique CatalogFile"
fi
if grep -q 'DriverVer *= *09/01/2026,2.0.4.1' "$INF"; then
  ok "DriverVer 09/01/2026,2.0.4.1"
else
  bad "DriverVer 09/01/2026,2.0.4.1"
fi
if grep -E '^DriverVer' "$INF" | grep -qE '08/30/2026,2\.0\.4\.0|08/31/2026,2\.0\.4\.0'; then
  bad "INF must not reuse failed 2.0.4 DriverVer"
else
  ok "INF does not reuse failed 2.0.4 DriverVer"
fi
if grep -q 'ServiceBinary = %12%\\MagicMouseDriver-kmdf-204-scroll.sys' "$INF" && \
   grep -q 'MagicMouseDriver-kmdf-204-scroll.sys = 1' "$INF"; then
  ok "INF dest is unique .sys (not MagicMouseDriver.sys)"
else
  bad "INF dest is unique .sys (not MagicMouseDriver.sys)"
fi
if grep -q 'ServiceBinary = %12%\\MagicMouseDriver.sys' "$INF"; then
  bad "INF must not CopyFiles/ServiceBinary MagicMouseDriver.sys"
else
  ok "INF does not target live restore name"
fi
if grep -q 'PID&0323' "$INF"; then ok "0323 hardware ID in INF"; else bad "0323 hardware ID in INF"; fi
if grep -qE 'PID&030[Dd]|PID&0269|PID&0310' "$INF"; then
  bad "INF hardware IDs must not include 030D/0269/0310"
else
  ok "INF hardware IDs are 0323-only"
fi
if grep -q 'LowerFilters",0x00010000,"MagicMouseDriver"' "$INF"; then
  ok "sole LowerFilters=MagicMouseDriver"
else
  bad "sole LowerFilters=MagicMouseDriver"
fi
if grep -q 'LowerFilters.*,"applewirelessmouse"' "$INF"; then
  bad "INF must not set applewirelessmouse as a filter"
else
  ok "INF does not set applewirelessmouse LowerFilters"
fi

# --- install story: pnputil only, no System32 copy-over ---
if test -f "$ROOT/scripts/Invoke-KmdfInstall.ps1" || test -f "$ROOT/scripts/Invoke-KmdfPostBoot.ps1"; then
  bad "SYSTEM unsigned-activate runners must not ship"
else
  ok "no SYSTEM unsigned-activate runners"
fi
if grep -R -n --include='*.ps1' --include='*.cmd' -E 'pr3-activate|activate-204' "$ROOT" >/dev/null; then
  # mentions in ban comments are OK if they are refusals
  if grep -R -n --include='*.ps1' -E 'pr3-activate-204\.ps1|function.*Activate-204' "$ROOT" >/dev/null; then
    bad "unsigned activate script present"
  else
    ok "no unsigned activate implementation"
  fi
else
  ok "no unsigned activate implementation"
fi
if grep -R -n --include='*.ps1' --include='*.cmd' -E 'Copy-Item[^\n]*-Destination[^\n]*(System32\\drivers|DriverStore)' "$ROOT" >/dev/null; then
  bad "scripts must not Copy-Item onto System32\\drivers or DriverStore"
else
  ok "no Copy-Item onto System32/DriverStore"
fi
if grep -R -n --include='*.ps1' 'delete-driver.*MagicMouseDriver\.inf|/delete-driver \$oem' "$ROOT/scripts" "$ROOT/Install-KMDF.ps1" >/dev/null 2>&1; then
  # allow unique-package-only delete
  if grep -n 'delete-driver' "$ROOT/Install-KMDF.ps1" | grep -v '204-scroll' | grep -q 'MagicMouseDriver\.inf'; then
    bad "uninstall must not delete Apr 30 MagicMouseDriver.inf / oem16"
  else
    ok "uninstall does not delete Apr 30 MagicMouseDriver.inf"
  fi
else
  ok "uninstall does not delete Apr 30 MagicMouseDriver.inf"
fi
if grep -q 'pnputil.exe /add-driver' "$ROOT/Install-KMDF.ps1"; then
  ok "install uses pnputil /add-driver"
else
  bad "install uses pnputil /add-driver"
fi
if grep -q '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE' "$ROOT/scripts/Kmdf-Common.ps1"; then
  ok "sign thumb 16940C0F documented in scripts"
else
  bad "sign thumb 16940C0F documented in scripts"
fi
if grep -q '845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3' "$ROOT/scripts/Kmdf-Common.ps1"; then
  ok "failed 2.0.4 SHA banned"
else
  bad "failed 2.0.4 SHA banned"
fi
if grep -q 'AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B' "$ROOT/scripts/Kmdf-Common.ps1"; then
  ok "Apr 30 SHA is the restore baseline (refused as this package)"
else
  bad "Apr 30 SHA is the restore baseline (refused as this package)"
fi
if test -f "$ROOT/scripts/Freeze-KmdfArtifact.ps1"; then ok "freeze-hash script exists"; else bad "freeze-hash script exists"; fi
if grep -q 'MagicMouseDriver-kmdf-2.0.4-scroll-' "$ROOT/scripts/Freeze-KmdfArtifact.ps1" && \
   grep -q 'sha8' "$ROOT/FREEZE-HASH.md"; then
  ok "named artifact MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys"
else
  bad "named artifact MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys"
fi
if test -f "$ROOT/mm-dev.ps1" || test -f "$ROOT/scripts/mm-dev.ps1"; then
  bad "mm-dev.ps1 must not ship"
else
  ok "no mm-dev.ps1"
fi
if grep -R -n --include='*.ps1' --include='*.cmd' 'Phase=Full' "$ROOT" >/dev/null; then
  bad "Phase=Full leftover"
else
  ok "no Phase=Full leftover"
fi
if grep -R -n --include='*.ps1' "MagicMouseDriver', 'applewirelessmouse" "$ROOT" >/dev/null; then
  bad "dual-filter array in scripts"
else
  ok "no dual-filter array in scripts"
fi

# --- HID contract ---
test -f "$ROOT/Driver.c" && ok "Driver.c present" || bad "Driver.c present"
test -f "$ROOT/AclTranslate.c" && ok "AclTranslate.c present" || bad "AclTranslate.c present"
test -f "$ROOT/HID-CONTRACT.md" && ok "HID-CONTRACT.md present" || bad "HID-CONTRACT.md present"
grep -q '0x85, 0x12' "$ROOT/HidDescriptor.c" && ok "descriptor COL01 RID 0x12" || bad "descriptor COL01 RID 0x12"
grep -q '0x09, 0x30' "$ROOT/HidDescriptor.c" && ok "descriptor keeps X usage 0x0030" || bad "descriptor keeps X usage 0x0030"
grep -q '0x09, 0x31' "$ROOT/HidDescriptor.c" && ok "descriptor keeps Y usage 0x0031" || bad "descriptor keeps Y usage 0x0031"
grep -q '0x09, 0x38' "$ROOT/HidDescriptor.c" && ok "descriptor adds Wheel usage 0x0038" || bad "descriptor adds Wheel usage 0x0038"
grep -q '0x85, 0x90' "$ROOT/HidDescriptor.c" && ok "descriptor COL02 RID 0x90" || bad "descriptor COL02 RID 0x90"
if grep -q '0x85, 0x47' "$ROOT/HidDescriptor.c"; then
  bad "descriptor must not inject Feature 0x47"
else
  ok "descriptor has no Feature 0x47"
fi
# X/Y must appear before Wheel in the blob (extra, not replacement).
HID_C="$ROOT/HidDescriptor.c" python3 - <<'PY' || { echo "FAIL HID usage order X/Y then Wheel"; fail=1; }
from pathlib import Path
import os
p = Path(os.environ["HID_C"])
text = p.read_text()
# pull hex bytes from the C array
import re
body = text.split("g_HidDescriptor[] = {",1)[1].split("};",1)[0]
nums = [int(x,16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", body)]
# find Report ID 0x12 then usages 0x30, 0x31, 0x38 in that collection
idx12 = None
for i in range(len(nums)-1):
    if nums[i]==0x85 and nums[i+1]==0x12:
        idx12 = i
        break
if idx12 is None:
    raise SystemExit(1)
def find_usage(start, usage):
    for i in range(start, len(nums)-1):
        if nums[i]==0x09 and nums[i+1]==usage:
            return i
        if nums[i]==0x85 and nums[i+1]==0x90:
            return None
    return None
x = find_usage(idx12, 0x30)
y = find_usage(idx12, 0x31)
w = find_usage(idx12, 0x38)
if x is None or y is None or w is None:
    raise SystemExit(1)
if not (x < y < w):
    raise SystemExit(1)
print("OK  HID 0x12 keeps X/Y then adds Wheel (order)")
PY
if grep -q 'out\[0\] = 0x02' "$ROOT/GestureEngine.c"; then
  bad "GestureEngine must not convert to RID 0x02"
else
  ok "GestureEngine does not emit RID 0x02"
fi
grep -q 'out\[0\] = MM_REPORT_ID_MOUSE' "$ROOT/GestureEngine.c" && ok "GestureEngine stays on RID 0x12" || bad "GestureEngine stays on RID 0x12"
grep -q '#define MM_MOUSE_REPORT_LEN 8' "$ROOT/Driver.h" && ok "0x12 report is 8 bytes" || bad "0x12 report is 8 bytes"
grep -q 'ReadI16Le' "$ROOT/GestureEngine.c" && ok "optical X/Y copied as INT16" || bad "optical X/Y copied as INT16"
if grep -q 'capacity < need' "$ROOT/AclTranslate.c"; then
  ok "ACL rewrite is capacity-safe"
else
  bad "ACL rewrite is capacity-safe"
fi

# --- versions / names ---
grep -q 'FILEVERSION    2,0,4,1' "$ROOT/MagicMouseDriver.rc" && ok "FileVersion 2.0.4.1 in VERSIONINFO" || bad "FileVersion 2.0.4.1 in VERSIONINFO"
if grep -q '<TargetName>MagicMouseDriver-kmdf-204-scroll</TargetName>' "$ROOT/MagicMouseDriver.vcxproj"; then
  ok "vcxproj TargetName is unique dest"
else
  bad "vcxproj TargetName is unique dest"
fi
if grep -q '<TargetName>MagicMouseDriver</TargetName>' "$ROOT/MagicMouseDriver.vcxproj"; then
  bad "vcxproj must not emit live-named MagicMouseDriver.sys"
else
  ok "vcxproj does not emit live-named MagicMouseDriver.sys"
fi
if grep -q 'MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys' "$REPO/README.md" && \
   grep -q 'MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys' "$REPO/README.md" && \
   grep -q 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys' "$REPO/README.md"; then
  ok "root README names sha8 artifact vs Apr 30 vs SHIP-BLOCKER"
else
  bad "root README names sha8 artifact vs Apr 30 vs SHIP-BLOCKER"
fi
if grep -q 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys' "$REPO/v1-binary-patch/installer/Install-MagicMousePatch.ps1" && \
   grep -q 'System32\\drivers\\applewirelessmouse.sys' "$REPO/v1-binary-patch/installer/Install-MagicMousePatch.ps1"; then
  ok "PATH-A package name vs Windows install name (historical only)"
else
  bad "PATH-A package name vs Windows install name (historical only)"
fi
if grep -qi 'magic-tray' "$ROOT/MAGIC-TRAY.md"; then ok "magic-tray pull note"; else bad "magic-tray pull note"; fi
if grep -q '16940C0F' "$ROOT/SIGN-AND-INSTALL.md" && grep -q 'pnputil /add-driver' "$ROOT/SIGN-AND-INSTALL.md"; then
  ok "SIGN-AND-INSTALL.md documents human sign + pnputil"
else
  bad "SIGN-AND-INSTALL.md documents human sign + pnputil"
fi
if find "$REPO" -iname '*.pfx' -o -iname '*.p12' | grep -v '/\.git/' | grep -q .; then
  bad "no PFX / private keys in tree"
else
  ok "no PFX / private keys in tree"
fi

exit "$fail"
