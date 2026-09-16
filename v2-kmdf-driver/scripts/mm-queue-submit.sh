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
  local stage="/tmp/mm-queue-request.$$.txt"
  printf '%s\n' "$line" > "$stage"
  local unc
  unc="$(wslpath -w "$stage")"
  "$ps" -NoProfile -NonInteractive -Command \
    "Set-Content -LiteralPath 'C:\\mm-dev-queue\\request.txt' -Value (Get-Content -LiteralPath '$unc' -Raw).Trim() -Encoding ASCII"
  rm -f "$stage"
}

trigger_task() {
  local st ps
  if st="$(find_win32 schtasks.exe)"; then
    "$st" /run /tn 'MM-Dev-Cycle' >/dev/null
    return 0
  fi
  ps="$(find_win32 powershell.exe)" || {
    echo "$0: schtasks.exe / powershell.exe not executable. Apply WSL-FACTORY-MIRROR." >&2
    return 1
  }
  "$ps" -NoProfile -NonInteractive -Command \
    "Start-Process -FilePath schtasks.exe -ArgumentList '/run','/tn','MM-Dev-Cycle' -Wait -NoNewWindow" >/dev/null
}

NONCE="$(date +%s%N)"
LINE="$PHASE|$NONCE"
if [[ "$#" -gt 0 ]]; then
  IFS='|'
  LINE="$LINE|$*"
  unset IFS
fi

write_request "$LINE"
trigger_task

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
