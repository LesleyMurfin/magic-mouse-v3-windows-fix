#!/usr/bin/env bash
# mm-dev.sh - WSL wrapper for the Magic Mouse driver dev cycle
#
# USAGE (from WSL, inside the repo):
#   ./scripts/mm-dev.sh state          # snapshot current PnP + driver state
#   ./scripts/mm-dev.sh build          # EWDK msbuild
#   ./scripts/mm-dev.sh sign           # signtool
#   ./scripts/mm-dev.sh install        # remove old + install new + restart device
#   ./scripts/mm-dev.sh capture        # (re)start DebugView
#   ./scripts/mm-dev.sh full           # state -> build -> sign -> install -> state
#   ./scripts/mm-dev.sh log            # tail session log
#   ./scripts/mm-dev.sh debug          # tail MagicMouse entries from DebugView log
#   ./scripts/mm-dev.sh commit "msg"   # stage driver/ and commit via git.py
#   ./scripts/mm-dev.sh diff           # show uncommitted driver changes
#
# The loop:
#   1. Edit driver source (WSL)
#   2. ./scripts/mm-dev.sh full
#   3. ./scripts/mm-dev.sh capture
#   4. Test mouse gestures
#   5. ./scripts/mm-dev.sh debug
#   6. ./scripts/mm-dev.sh commit "fix: ..."
#   7. Repeat from 1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
GIT_PY="/home/lesley/projects/scripts/git.py"
SESSION_LOG="/mnt/c/mm-dev-session.log"
DEBUG_LOG="/mnt/c/mm3-debug.log"

# Windows-side build directory. WSL repo is SSOT - we sync into here.
# The .vcxproj lives at the root of WIN_DRIVER_DIR (NOT in a driver/ subfolder).
WIN_DRIVER_DIR="${WIN_DRIVER_DIR:-/mnt/d/mm3-driver}"

# Scheduled task for headless (no-UAC) execution.
# Registered once via mm-task-setup.ps1 — see TASK SETUP section in --help.
TASK_NAME="${MM_TASK_NAME:-MM-Dev-Cycle}"
QUEUE_DIR="/mnt/c/mm-dev-queue"
TASK_TIMEOUT="${MM_TASK_TIMEOUT:-600}"   # 10 min default

task_exists() {
    # Tasks set with RunLevel=Highest require admin to query. From a non-admin
    # WSL shell, schtasks /query returns "Access is denied" even when the task
    # IS registered. Distinguish "doesn't exist" from "exists but can't read":
    #   - "ERROR: The system cannot find ..." -> truly missing -> return 1
    #   - "ERROR: Access is denied" -> exists, treat as found -> return 0
    #   - success -> exists -> return 0
    local out
    out=$(schtasks.exe /query /tn "$TASK_NAME" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    if echo "$out" | grep -qiE "cannot find|does not exist|not found"; then
        return 1
    fi
    # Any other error (Access denied etc.) -> assume task exists
    return 0
}

# Sync WSL repo driver/ + scripts/ into Windows build dir.
# Idempotent; safe to call before every phase. Build artefacts (x64/, *.cer)
# in WIN_DRIVER_DIR are preserved (we only overwrite source + scripts).
sync_to_windows() {
    if [[ ! -d "$WIN_DRIVER_DIR" ]]; then
        echo "[mm-dev] ERROR: $WIN_DRIVER_DIR does not exist." >&2
        echo "[mm-dev] Create it and copy the initial files (vcxproj, *.cer) — then re-run." >&2
        return 1
    fi
    # Source files (driver/* → WIN_DRIVER_DIR/)
    cp -f "$REPO_ROOT/driver/"*.c    "$WIN_DRIVER_DIR/" 2>/dev/null || true
    cp -f "$REPO_ROOT/driver/"*.h    "$WIN_DRIVER_DIR/" 2>/dev/null || true
    cp -f "$REPO_ROOT/driver/"*.inf  "$WIN_DRIVER_DIR/" 2>/dev/null || true
    cp -f "$REPO_ROOT/driver/MagicMouseDriver.vcxproj" "$WIN_DRIVER_DIR/" 2>/dev/null || true
    # Scripts (scripts/* → WIN_DRIVER_DIR/scripts/)
    install -d "$WIN_DRIVER_DIR/scripts"
    cp -f "$REPO_ROOT/scripts/"*.ps1 "$WIN_DRIVER_DIR/scripts/" 2>/dev/null || true
    return 0
}

# Resolve PS1 path: prefer Windows-synced copy (so $PSScriptRoot resolves to
# WIN_DRIVER_DIR\scripts and $DriverRoot lands on the vcxproj location).
# Fall back to WSL UNC path only if the sync target is unavailable.
resolve_ps1_path() {
    if [[ -f "$WIN_DRIVER_DIR/scripts/mm-dev.ps1" ]]; then
        # Convert /mnt/d/mm3-driver/scripts/mm-dev.ps1 → D:\mm3-driver\scripts\mm-dev.ps1
        wslpath -w "$WIN_DRIVER_DIR/scripts/mm-dev.ps1"
    else
        wslpath -w "$SCRIPTS_DIR/mm-dev.ps1"
    fi
}

phase="${1:-help}"

# Map lowercase phase names -> PowerShell ValidateSet casing (no GNU-sed dep)
declare -A PHASE_MAP=(
    [state]=State [build]=Build [sign]=Sign [install]=Install
    [verify]=Verify [rollback]=Rollback [capture]=Capture
    [full]=Full   [log]=Log     [debug]=Debug
)

run_via_task() {
    local phase_arg="$1"
    local nonce; nonce="$(date +%s%N)"
    install -d "$QUEUE_DIR"
    rm -f "$QUEUE_DIR/result.txt" 2>/dev/null

    # Write request (CRLF for Windows tooling robustness)
    printf '%s|%s\r\n' "$phase_arg" "$nonce" > "$QUEUE_DIR/request.txt"

    echo "[mm-dev] Triggering scheduled task '$TASK_NAME' (no UAC, runs as SYSTEM)..."
    if ! schtasks.exe /run /tn "$TASK_NAME" >/dev/null 2>&1; then
        echo "[mm-dev] schtasks /run failed - falling back to direct PowerShell" >&2
        return 200
    fi

    # Poll for result (up to TASK_TIMEOUT seconds)
    local elapsed=0
    while (( elapsed < TASK_TIMEOUT )); do
        if [[ -f "$QUEUE_DIR/result.txt" ]]; then
            local raw rc res_nonce
            raw="$(tr -d '\r\n' < "$QUEUE_DIR/result.txt")"
            rc="${raw%%|*}"
            res_nonce="${raw#*|}"
            if [[ "$res_nonce" == "$nonce" ]]; then
                return "$rc"
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        # Show running indicator every 10 seconds
        if (( elapsed % 10 == 0 )); then
            echo "[mm-dev]   ... still running (${elapsed}s elapsed)"
        fi
    done
    echo "[mm-dev] Task timeout after ${TASK_TIMEOUT}s - check C:\\mm-dev-task.log" >&2
    return 124
}

run_via_uac() {
    local phase_arg="$1"
    local win_ps1; win_ps1="$(resolve_ps1_path)"
    echo "[mm-dev] Running Phase=$phase_arg via direct PowerShell (UAC prompt expected)..."
    powershell.exe -ExecutionPolicy Bypass -File "$win_ps1" -Phase "$phase_arg"
    return $?
}

run_ps1() {
    local lookup="${1,,}"  # bash 4+ lowercase
    local phase_arg="${PHASE_MAP[$lookup]}"
    if [[ -z "$phase_arg" ]]; then
        echo "[mm-dev] ERROR: unknown phase '$1'" >&2
        return 2
    fi
    # Sync source/scripts into Windows build dir so $PSScriptRoot resolves correctly
    if ! sync_to_windows; then
        return 1
    fi
    # Capture line count BEFORE the phase so we can print only this phase's output.
    # (bash can't reliably write to /mnt/c/mm-dev-session.log - PS owns ACL on it.)
    local before_lines=0
    [[ -f "$SESSION_LOG" ]] && before_lines=$(wc -l < "$SESSION_LOG" 2>/dev/null || echo 0)

    local rc
    if task_exists; then
        run_via_task "$phase_arg"
        rc=$?
        # 200 = task trigger failed; fall back to UAC path
        if [[ $rc -eq 200 ]]; then
            run_via_uac "$phase_arg"
            rc=$?
        fi
    else
        echo "[mm-dev] No scheduled task '$TASK_NAME' registered - using UAC path." >&2
        echo "[mm-dev] To eliminate UAC prompts, run ONCE from admin PowerShell:" >&2
        echo "[mm-dev]   $WIN_DRIVER_DIR/scripts/mm-task-setup.ps1" >&2
        run_via_uac "$phase_arg"
        rc=$?
    fi

    # Show all session log lines written since this phase began
    if [[ -f "$SESSION_LOG" ]]; then
        local after_lines; after_lines=$(wc -l < "$SESSION_LOG" 2>/dev/null || echo 0)
        if (( after_lines > before_lines )); then
            echo "----- session log (Phase=$phase_arg, $((after_lines - before_lines)) new lines) -----"
            sed -n "$((before_lines + 1)),${after_lines}p" "$SESSION_LOG"
            echo "------------------------------------"
        else
            echo "[mm-dev] WARN: no new session log lines (phase may have crashed before logging)" >&2
        fi
    fi
    if [[ $rc -ne 0 ]]; then
        echo "[mm-dev] Windows phase FAILED (exit=$rc) - full log: $SESSION_LOG" >&2
    else
        echo "[mm-dev] Windows phase OK (exit=0)"
    fi
    return $rc
}

case "$phase" in
    state|build|sign|install|verify|rollback|capture|full|log|debug)
        run_ps1 "$phase"
        exit $?
        ;;

    commit)
        msg="${2:-chore: driver update}"
        echo "[mm-dev] Staging driver/ ..."
        git -C "$REPO_ROOT" add driver/
        echo "[mm-dev] Committing: $msg"
        python3 "$GIT_PY" commit --branch main --message "$msg

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
        echo "[mm-dev] Committed."
        ;;

    diff)
        echo "[mm-dev] Uncommitted driver changes:"
        git -C "$REPO_ROOT" diff driver/
        git -C "$REPO_ROOT" status driver/
        ;;

    read-log)
        lines="${2:-50}"
        echo "[mm-dev] Session log (last $lines lines):"
        tail -n "$lines" "$SESSION_LOG" 2>/dev/null || echo "(no session log yet)"
        ;;

    read-debug)
        lines="${2:-40}"
        echo "[mm-dev] MagicMouse debug entries (last $lines):"
        grep "MagicMouse" "$DEBUG_LOG" 2>/dev/null | tail -n "$lines" || echo "(no entries yet)"
        ;;

    help|*)
        cat <<EOF
mm-dev.sh - Magic Mouse driver dev cycle (WSL wrapper)

LOOP:
  1. Edit driver/ in WSL
  2. ./scripts/mm-dev.sh full          ← build + sign + install + state snapshot
  3. ./scripts/mm-dev.sh capture       ← (re)start DebugView
  4. Test mouse gestures on Windows
  5. ./scripts/mm-dev.sh debug         ← read what happened
  6. ./scripts/mm-dev.sh commit "msg"  ← commit the change
  7. Repeat

COMMANDS:
  state       Snapshot PnP devices, driver, registry, debug log tail
  build       EWDK msbuild Rebuild
  sign        signtool sign .sys + .cat
  install     Remove old driver, install new, restart device
  verify      Post-install health check (LowerFilters, COL01 Started)
  rollback    Remove our filter driver entirely (recovery path)
  capture     (Re)start DebugView -> C:\mm3-debug.log
  full        state + build + sign + install + verify + state
  log         Tail C:\mm-dev-session.log
  debug       Tail MagicMouse lines from C:\mm3-debug.log
  commit MSG  Stage driver/ and commit via git.py
  diff        Show uncommitted changes in driver/
  read-log N  Read last N lines of session log (default 50)
  read-debug N Read last N MagicMouse debug lines (default 40)

EXIT CODES: 0=ok, 1=phase failure (build/sign/install/verify failed), 2=usage,
            124=task timeout, 200=task trigger failed (fell back to UAC path)

TASK SETUP (one-time, eliminates all future UAC prompts):
  1. Open admin PowerShell (UAC prompt OK once)
  2. cd D:\mm3-driver\scripts
  3. .\mm-task-setup.ps1
  After that, schtasks /run /tn MM-Dev-Cycle works from WSL with NO UAC.
  This wrapper auto-detects the task and uses it instead of the UAC path.

ENV OVERRIDES:
  WIN_DRIVER_DIR    Windows build dir (default: /mnt/d/mm3-driver)
  MM_TASK_NAME      Scheduled task name (default: MM-Dev-Cycle)
  MM_TASK_TIMEOUT   Task wait timeout in seconds (default: 600)
EOF
        ;;
esac
