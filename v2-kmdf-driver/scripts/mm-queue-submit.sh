#!/usr/bin/env bash
# IaC WSL → MM-Dev-Cycle submitter. No /tmp copies of System32.
#
# Usage:
#   scripts/mm-queue-submit.sh PHASE [arg ...]
# Examples:
#   scripts/mm-queue-submit.sh WSL-FACTORY-MIRROR
#   scripts/mm-queue-submit.sh KMDF-204-SYNC '\\\\wsl.localhost\\Ubuntu\\data\\projects\\...\\v2-kmdf-driver'
#   scripts/mm-queue-submit.sh KMDF-204-BUILD rebuild
#
# Env:
#   MM_QUEUE_DIR       default /mnt/c/mm-dev-queue
#   MM_QUEUE_TIMEOUT   seconds to poll result.txt (default 480)
set -euo pipefail

PHASE="${1:-}"
if [[ -z "$PHASE" ]]; then
  echo "Usage: $0 PHASE [arg ...]" >&2
  exit 2
fi
shift

QUEUE_DIR="${MM_QUEUE_DIR:-/mnt/c/mm-dev-queue}"
REQ="$QUEUE_DIR/request.txt"
RES="$QUEUE_DIR/result.txt"
TIMEOUT="${MM_QUEUE_TIMEOUT:-480}"

# Removed by the EXIT trap on every path, including failures.
STAGE=''
cleanup() {
  if [[ -n "$STAGE" ]]; then rm -f "$STAGE"; fi
}
trap cleanup EXIT

find_win32() {
  local name="$1"
  local c
  for c in \
    "/mnt/c/Windows/System32/${name}" \
    "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/${name}" \
    "/data/opt/wsl-win32/bin/${name}"
  do
    if [[ -x "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

write_request() {
  local line="$1"
  if [[ -d "$QUEUE_DIR" ]] && { [[ -w "$QUEUE_DIR" ]] || [[ -w "$REQ" ]]; }; then
    printf '%s\n' "$line" > "$REQ"
    return 0
  fi
  local ps
  ps="$(find_win32 powershell.exe)" || {
    echo "$0: cannot write $REQ and powershell.exe is not executable." >&2
    echo "Apply IaC: MM-Dev-Cycle phase WSL-FACTORY-MIRROR (Revive_Labs/scripts/wsl-factory-mirror)." >&2
    return 1
  }
  # WSL does not forward arbitrary env to Win32. Stage on ext4; Windows reads UNC.
  # mktemp under umask 077: a predictable PID-based name lets a local attacker
  # pre-create the path and swap the request PowerShell is about to read.
  STAGE="$(umask 077; mktemp "${TMPDIR:-/tmp}/mm-queue-request.XXXXXXXXXX")"
  printf '%s\n' "$line" > "$STAGE"
  local unc
  unc="$(wslpath -w "$STAGE")"
  # Synchronous call, so PowerShell has consumed the file before it is removed.
  "$ps" -NoProfile -NonInteractive -Command \
    "Set-Content -LiteralPath 'C:\\mm-dev-queue\\request.txt' -Value (Get-Content -LiteralPath '$unc' -Raw).Trim() -Encoding ASCII"
  rm -f "$STAGE"
  STAGE=''
}

# Exit status propagates: a missing, disabled or unrunnable MM-Dev-Cycle task
# must abort the submission, not leave the caller polling result.txt for
# MM_QUEUE_TIMEOUT seconds while holding the exclusive lock.
trigger_task() {
  local st ps
  if st="$(find_win32 schtasks.exe)"; then
    "$st" /run /tn 'MM-Dev-Cycle' >/dev/null
    return
  fi
  ps="$(find_win32 powershell.exe)" || {
    echo "$0: schtasks.exe / powershell.exe not executable. Apply WSL-FACTORY-MIRROR." >&2
    return 1
  }
  # -PassThru + exit is the only way schtasks' status leaves powershell.exe;
  # -ErrorAction Stop covers Start-Process itself failing to launch it.
  "$ps" -NoProfile -NonInteractive -Command \
    "\$ErrorActionPreference = 'Stop'; \$p = Start-Process -FilePath schtasks.exe -ArgumentList '/run','/tn','MM-Dev-Cycle' -Wait -NoNewWindow -PassThru; exit \$p.ExitCode" >/dev/null
}

NONCE="$(date +%s%N)"
LINE="$PHASE|$NONCE"
if [[ "$#" -gt 0 ]]; then
  IFS='|'
  LINE="$LINE|$*"
  unset IFS
fi

# request.txt / result.txt is a single fixed slot whose names the Windows-side
# MM-Dev-Cycle task owns, so per-invocation filenames are not ours to change:
# serialize instead. The exclusive lock is held from submission through result
# collection, so a second invocation cannot overwrite the request before the
# task has read it, nor collect a result belonging to the first.
if ! command -v flock >/dev/null 2>&1; then
  echo "$0: flock (util-linux) is required to serialize queue submissions." >&2
  exit 1
fi
LOCK_DIR="$QUEUE_DIR/.mm-queue-submit"
# Keep the lock beside request.txt/result.txt so every invocation targeting
# this queue slot shares one lock regardless of TMPDIR or effective UID.
# mkdir -p does NOT chmod a directory that already exists, and -d/-L on the
# directory still passes when an attacker pre-created it world-writable and
# planted a symlink at lock/ - `exec 9>` would then follow it and truncate the
# target. Ownership is the check that actually closes that, so assert it.
mkdir -p -m 700 "$LOCK_DIR"
if [[ -L "$LOCK_DIR" || ! -d "$LOCK_DIR" || ! -O "$LOCK_DIR" ]]; then
  echo "$0: $LOCK_DIR is not a directory we own - refusing to lock." >&2
  exit 1
fi
chmod 700 "$LOCK_DIR"
if [[ -L "$LOCK_DIR/lock" ]]; then
  echo "$0: $LOCK_DIR/lock is a symlink - refusing to lock." >&2
  exit 1
fi
exec 9>"$LOCK_DIR/lock"
LOCK_WAIT=$((TIMEOUT + 60))
if ! flock -w "$LOCK_WAIT" 9; then
  echo "$0: another mm-queue-submit still holds the queue after ${LOCK_WAIT}s" >&2
  exit 1
fi

write_request "$LINE"
if ! trigger_task; then
  echo "[mm-queue-submit] could not trigger the MM-Dev-Cycle scheduled task - not waiting ${TIMEOUT}s for a result that will never arrive" >&2
  exit 1
fi

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  sleep 1
  res="$(cat "$RES" 2>/dev/null || true)"
  res="${res//$'\r'/}"
  res="${res//$'\n'/}"
  if [[ "$res" == *"|${NONCE}" ]]; then
    rc="${res%%|*}"
    printf '%s\n' "$res"
    exit "$rc"
  fi
done

echo "[mm-queue-submit] TIMEOUT after ${TIMEOUT}s waiting for nonce ${NONCE}" >&2
exit 1
