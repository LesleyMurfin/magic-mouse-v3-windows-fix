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
grep -q 'out\[0\] = 0x02' "$ROOT/GestureEngine.c" && ok "GestureEngine emits RID 0x02" || bad "GestureEngine emits RID 0x02"
grep -q 'ReadI16Le' "$ROOT/GestureEngine.c" && ok "optical X/Y copied" || bad "optical X/Y copied"
grep -q "UserId 'SYSTEM'" "$ROOT/Install-KMDF.ps1" && ok "SYSTEM principal" || bad "SYSTEM principal"
grep -q 'MM-Kmdf-Install' "$ROOT/scripts/Kmdf-Common.ps1" && ok "task name MM-Kmdf-Install" || bad "task name MM-Kmdf-Install"
grep -qi 'magic-tray' "$ROOT/MAGIC-TRAY.md" && ok "magic-tray pull note" || bad "magic-tray pull note"
grep -q '559B136A' "$ROOT/scripts/Kmdf-Common.ps1" && ok "May 20 pointer-dead SHA banned" || bad "May 20 pointer-dead SHA banned"
grep -q 'CN=MagicMouseFix' "$ROOT/scripts/Kmdf-Common.ps1" && ok "signs as MagicMouseFix" || bad "signs as MagicMouseFix"

exit "$fail"
