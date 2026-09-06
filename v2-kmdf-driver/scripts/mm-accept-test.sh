#!/usr/bin/env bash
# mm-accept-test.sh — Magic Mouse 2024 acceptance test (WSL entry point)
#
# Runs 8 read-only checks against the currently installed driver:
#   AC-01  LowerFilters contains MagicMouseDriver (not applewirelessmouse)
#   AC-02  COL01 (pointer) enumerated and Status=Started
#   AC-03  COL02 (battery) enumerated and Status=Started
#   AC-04  COL01 HID report declares Wheel and/or AC Pan usage
#   AC-05  COL02 has vendor battery TLC (UP=0xFF00 U=0x0014 InputLen>=3)
#   AC-06  HidD_GetInputReport(0x90) on COL02 returns buf[2]=0..100
#   AC-07  C:\mm3-debug.log has 'MagicMouse: Descriptor injected' within 60s
#   AC-08  %APPDATA%\MagicMouseTray\debug.log last line has pct=0..100
#
# USAGE:
#   ./scripts/mm-accept-test.sh            # run all checks
#   ./scripts/mm-accept-test.sh --help     # show this help
#
# OUTPUTS:
#   Stdout: results table + PASS/FAIL verdict
#   JSON:   %LOCALAPPDATA%\mm-accept-test-<ISO>.json
#
# EXIT CODES:
#   0  all checks pass
#   1  at least one check failed
#   2  usage error or environment problem
#
# NOTE: Does NOT install/uninstall/modify any driver. Read-only.
# If checks fail, consider: ./scripts/mm-dev.sh rollback

set -euo pipefail

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
    exit 0
fi

# ---------------------------------------------------------------------------
# Locate repo root and PS1 helper
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PS1_HELPER="$SCRIPT_DIR/mm-accept-test.ps1"

if [[ ! -f "$PS1_HELPER" ]]; then
    echo "[mm-accept-test] ERROR: PowerShell helper not found: $PS1_HELPER" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Verify we can reach powershell.exe
# ---------------------------------------------------------------------------
if ! command -v powershell.exe &>/dev/null; then
    echo "[mm-accept-test] ERROR: powershell.exe not found in PATH." >&2
    echo "[mm-accept-test] This script must run from WSL with Windows PowerShell accessible." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Convert WSL path to Windows path for the PS1
# ---------------------------------------------------------------------------
WIN_PS1="$(wslpath -w "$PS1_HELPER")"

# ---------------------------------------------------------------------------
# Optional: pass through WIN_DRIVER_DIR if set, so the sync step in mm-dev.sh
# keeps the PS1 at the same location the user expects.
# mm-accept-test.ps1 is self-contained and does not need mm-dev.ps1.
# ---------------------------------------------------------------------------
echo "[mm-accept-test] Running acceptance checks via PowerShell..."
echo "[mm-accept-test] Script: $WIN_PS1"
echo ""

powershell.exe \
    -NoProfile \
    -ExecutionPolicy Bypass \
    -File "$WIN_PS1" \
    "$@"

rc=$?

echo ""
if [[ $rc -eq 0 ]]; then
    echo "[mm-accept-test] All checks PASSED (exit 0)"
elif [[ $rc -eq 1 ]]; then
    echo "[mm-accept-test] One or more checks FAILED (exit 1)" >&2
    echo "[mm-accept-test] To roll back: ./scripts/mm-dev.sh rollback" >&2
else
    echo "[mm-accept-test] PowerShell exited with code $rc" >&2
fi

exit $rc
