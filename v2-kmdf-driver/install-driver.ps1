# install-driver.ps1 — Install a pre-signed driver package via pnputil.
# Standalone: powershell -ExecutionPolicy Bypass -File install-driver.ps1 -InfPath <path>
# Via queue: INSTALL-DRIVER|<nonce>|<inf-path>
# Pre-requisite: driver package must already be signed (use sign-driver.ps1 first).
# Pre-requisite: CN=MagicMouseFix cert must be in LocalMachine\TrustedPublisher.
# Note: if applewirelessmouse LowerFilter is active, verify no RID sweep is running first
#       (prior BSOD 0x0000013A from brute-force RID sweep with LowerFilter active 2026-05-09).
param(
    [Parameter(Mandatory)][string]$InfPath
)

if (-not (Test-Path $InfPath)) {
    Write-Error "INF not found: $InfPath"
    exit 2
}

Write-Host "Installing driver from $InfPath ..."
& pnputil /add-driver $InfPath /install
$rc = $LASTEXITCODE
if ($rc -eq 0) {
    Write-Host "Driver installed successfully."
} elseif ($rc -eq 3010) {
    Write-Host "Driver installed — REBOOT REQUIRED to activate."
} else {
    Write-Error "pnputil failed ($rc)"
}
exit $rc
