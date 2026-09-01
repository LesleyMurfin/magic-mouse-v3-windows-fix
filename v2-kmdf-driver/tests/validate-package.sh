#!/usr/bin/env bash
# Linux-side package checks. Does not build a .sys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

ok()  { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=1; }

echo "Validating $ROOT"

if grep -q 'PID&0323' "$ROOT/MagicMouseDriver.inf"; then ok "0323 hardware ID in INF"; else bad "0323 hardware ID in INF"; fi
if grep -qE 'PID&030[Dd]|PID&0269|PID&0310' "$ROOT/MagicMouseDriver.inf"; then
  bad "INF hardware IDs must not include 030D/0269/0310"
else
  ok "INF hardware IDs are 0323-only"
fi
if grep -q 'LowerFilters",0x00010000,"MagicMouseDriver"' "$ROOT/MagicMouseDriver.inf"; then
  ok "sole LowerFilters=MagicMouseDriver"
else
  bad "sole LowerFilters=MagicMouseDriver"
fi
if grep -q 'LowerFilters.*,"applewirelessmouse"' "$ROOT/MagicMouseDriver.inf"; then
  bad "INF must not set applewirelessmouse as a filter"
else
  ok "INF does not set applewirelessmouse LowerFilters"
fi
test -f "$ROOT/Install-KMDF.cmd" && ok "one-click cmd exists" || bad "one-click cmd exists"
test -f "$ROOT/scripts/Invoke-KmdfInstall.ps1" && ok "SYSTEM install runner exists" || bad "SYSTEM install runner exists"
test -f "$ROOT/scripts/Invoke-KmdfPostBoot.ps1" && ok "post-boot runner exists" || bad "post-boot runner exists"
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
test -f "$ROOT/Driver.c" && ok "Driver.c present" || bad "Driver.c present"
test -f "$ROOT/AclTranslate.c" && ok "AclTranslate.c present" || bad "AclTranslate.c present"
grep -q '0x85, 0x12' "$ROOT/HidDescriptor.c" && ok "descriptor COL01 RID 0x12" || bad "descriptor COL01 RID 0x12"
grep -q '0x85, 0x90' "$ROOT/HidDescriptor.c" && ok "descriptor COL02 RID 0x90" || bad "descriptor COL02 RID 0x90"
grep -q '0x09, 0x38' "$ROOT/HidDescriptor.c" && ok "descriptor Wheel usage 0x38" || bad "descriptor Wheel usage 0x38"
if grep -q '0x85, 0x47' "$ROOT/HidDescriptor.c"; then
  bad "descriptor must not inject Feature 0x47"
else
  ok "descriptor has no Feature 0x47"
fi
if grep -q 'out\[0\] = 0x02' "$ROOT/GestureEngine.c"; then
  bad "GestureEngine must not convert to RID 0x02"
else
  ok "GestureEngine does not emit RID 0x02"
fi
grep -q 'out\[0\] = MM_REPORT_ID_MOUSE' "$ROOT/GestureEngine.c" && ok "GestureEngine stays on RID 0x12" || bad "GestureEngine stays on RID 0x12"
grep -q '#define MM_MOUSE_REPORT_LEN 8' "$ROOT/Driver.h" && ok "0x12 report is 8 bytes" || bad "0x12 report is 8 bytes"
grep -q 'ReadI16Le' "$ROOT/GestureEngine.c" && ok "optical X/Y copied as INT16" || bad "optical X/Y copied as INT16"
grep -q "UserId 'SYSTEM'" "$ROOT/Install-KMDF.ps1" && ok "SYSTEM principal" || bad "SYSTEM principal"
grep -q 'MM-Kmdf-Install' "$ROOT/scripts/Kmdf-Common.ps1" && ok "task name MM-Kmdf-Install" || bad "task name MM-Kmdf-Install"
grep -qi 'magic-tray' "$ROOT/MAGIC-TRAY.md" && ok "magic-tray pull note" || bad "magic-tray pull note"
grep -q '559B136A' "$ROOT/scripts/Kmdf-Common.ps1" && ok "May 20 pointer-dead SHA banned" || bad "May 20 pointer-dead SHA banned"
grep -q 'CN=MagicMouseFix' "$ROOT/scripts/Kmdf-Common.ps1" && ok "signs as MagicMouseFix" || bad "signs as MagicMouseFix"
if grep -q 'ServiceBinary = %12%\\MagicMouseDriver.sys' "$ROOT/MagicMouseDriver.inf" && \
   grep -q 'MagicMouseDriver.sys = 1' "$ROOT/MagicMouseDriver.inf"; then
  ok "INF still installs MagicMouseDriver.sys"
else
  bad "INF still installs MagicMouseDriver.sys"
fi
grep -q 'MagicMouseDriver-kmdf-2.0.4-scroll.sys' "$ROOT/scripts/Kmdf-Common.ps1" && ok "scroll artifact name" || bad "scroll artifact name"
grep -q 'MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys' "$ROOT/scripts/Kmdf-Common.ps1" && ok "Apr 30 pointer artifact name" || bad "Apr 30 pointer artifact name"
grep -q 'MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys' "$ROOT/scripts/Kmdf-Common.ps1" && ok "May 20 pointer-dead artifact name" || bad "May 20 pointer-dead artifact name"
grep -q 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys' "$ROOT/scripts/Kmdf-Common.ps1" && ok "PATH-A ship-blocker name" || bad "PATH-A ship-blocker name"
grep -q 'FILEVERSION    2,0,4,0' "$ROOT/MagicMouseDriver.rc" && ok "FileVersion 2.0.4.0 in VERSIONINFO" || bad "FileVersion 2.0.4.0 in VERSIONINFO"
grep -q 'OriginalFilename", "MagicMouseDriver-kmdf-2.0.4-scroll.sys' "$ROOT/MagicMouseDriver.rc" && ok "OriginalFilename is scroll artifact" || bad "OriginalFilename is scroll artifact"
if grep -q '<TargetName>MagicMouseDriver</TargetName>' "$ROOT/MagicMouseDriver.vcxproj"; then
  ok "vcxproj TargetName still MagicMouseDriver"
else
  bad "vcxproj TargetName still MagicMouseDriver"
fi
REPO="$(cd "$ROOT/.." && pwd)"
if grep -q 'MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys' "$REPO/README.md" && \
   grep -q 'MagicMouseDriver-kmdf-2.0.4-scroll.sys' "$REPO/README.md" && \
   grep -q 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys' "$REPO/README.md"; then
  ok "root README names pointer-only vs scroll vs SHIP-BLOCKER"
else
  bad "root README names pointer-only vs scroll vs SHIP-BLOCKER"
fi
if grep -q 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys' "$REPO/v1-binary-patch/installer/Install-MagicMousePatch.ps1" && \
   grep -q 'System32\\drivers\\applewirelessmouse.sys' "$REPO/v1-binary-patch/installer/Install-MagicMousePatch.ps1"; then
  ok "PATH-A package name vs Windows install name"
else
  bad "PATH-A package name vs Windows install name"
fi

exit "$fail"
