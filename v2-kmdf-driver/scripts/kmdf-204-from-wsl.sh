#!/usr/bin/env bash
# IaC: sync the unique KMDF sources off WSL ext4 onto C:\mm-dev-queue
# and EWDK-build the unsigned unique package. Never pnputil. Never INSTALL-DRIVER.
set -euo pipefail

# Not an override: the queued KMDF-204-BUILD phase is submitted as a bare
# 'rebuild' token (below) and carries no version argument, so the Windows side
# always builds scripts/kmdf-204-scroll-build.ps1's own -Version default. This
# constant must be updated in lockstep with that default; it only selects the
# work dir C:\mm-dev-queue\kmdf-204-bld-<version without dots> we read back.
MM_VERSION='2.0.4.3'
MM_VERTAG="${MM_VERSION//./}"
QUEUE_DIR="${MM_QUEUE_DIR:-/mnt/c/mm-dev-queue}"

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$(cd "$HERE/.." && pwd)"
SUBMIT="$HERE/mm-queue-submit.sh"

if [[ ! -x "$SUBMIT" ]]; then
  chmod +x "$SUBMIT"
fi

WIN_SRC="$(wslpath -w "$DRIVER")"
echo "KMDF-204-SYNC $WIN_SRC"
MM_QUEUE_TIMEOUT="${MM_QUEUE_TIMEOUT:-60}" "$SUBMIT" KMDF-204-SYNC "$WIN_SRC"

echo "KMDF-204-BUILD rebuild"
MM_QUEUE_TIMEOUT="${MM_QUEUE_TIMEOUT:-480}" "$SUBMIT" KMDF-204-BUILD rebuild

echo "live oem16 hash (must stay AD5D244B):"
sha256sum /mnt/c/Windows/System32/drivers/MagicMouseDriver.sys
echo "frozen unsigned:"
cat "$QUEUE_DIR/kmdf-204-bld-${MM_VERTAG}/FROZEN-UNSIGNED.txt"
