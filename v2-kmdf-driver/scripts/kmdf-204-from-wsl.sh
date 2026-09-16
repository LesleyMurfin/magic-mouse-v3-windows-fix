#!/usr/bin/env bash
# IaC: sync unique 2.0.4.1 KMDF sources off WSL ext4 onto C:\mm-dev-queue
# and EWDK-build the unsigned unique package. Never pnputil. Never INSTALL-DRIVER.
set -euo pipefail

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
cat /mnt/c/mm-dev-queue/kmdf-204-bld/FROZEN-UNSIGNED.txt
