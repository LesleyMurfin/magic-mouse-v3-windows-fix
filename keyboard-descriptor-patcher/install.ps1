# install.ps1 — pnputil /add-driver MagicKbDesc.inf /install /force.
# Reuses the M12 SYSTEM scheduled task runner so the install runs with
# elevated PnP rights. Self-elevates if not already admin.

param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$infPath = Join-Path $PSScriptRoot 'x64\Release\MagicKbDesc\MagicKbDesc.inf'

if (-not (Test-Path $infPath)) {
    throw "INF not found at $infPath. Run build.ps1 first."
}

# self-elevate
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$pp = New-Object System.Security.Principal.WindowsPrincipal($id)
if (-not $pp.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") -Verb RunAs -Wait
    exit
}

if ($Uninstall) {
    Write-Host "Looking for installed MagicKbDesc.inf..."
    $rx = pnputil /enum-drivers | Select-String -Pattern 'MagicKbDesc' -Context 0,3 | Select-Object -First 1
    if ($rx) {
        $oem = ($rx.Context.PostContext | Where-Object { $_ -match 'oem\d+\.inf' } | Select-Object -First 1) -replace '.*?(oem\d+\.inf).*', '$1'
        if ($oem) {
            Write-Host "Removing $oem..."
            pnputil /delete-driver $oem /uninstall /force
        } else {
            Write-Host "Could not parse oemNN.inf name from pnputil output."
        }
    } else {
        Write-Host "MagicKbDesc not installed."
    }
    exit
}

Write-Host "Installing $infPath ..."
pnputil /add-driver $infPath /install /force

Write-Host ""
Write-Host "Verify the filter is in the keyboard's stack:"
Write-Host '  Get-PnpDeviceProperty -InstanceId "BTHENUM\{00001124-...}_VID&000205AC_PID&0239\..." -KeyName DEVPKEY_Device_Stack'
Write-Host "Expect: \Driver\HidBth, \Driver\MagicKbDesc, \Driver\BthEnum"
