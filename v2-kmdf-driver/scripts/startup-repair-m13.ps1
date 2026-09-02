# startup-repair-m13.ps1 - MagicMouseDriver (M13/M14) WDF filter repair
# SPDX-License-Identifier: MIT
# ASCII-only script (no UTF-8 BOM required for Windows PowerShell 5.x compatibility).
#
# Sets LowerFilters for MagicMouseDriver on paired v3 (0323) and v1 (030D/0310)
# BTHENUM devices, then pnputil /restart-device to bind the filter without reboot.
#
# Usage: powershell -ExecutionPolicy Bypass -File startup-repair-m13.ps1

param(
    [string]$LogFile = "C:\mm-dev-queue\startup-repair-detail.log",
    [int]$SettleSeconds = 8
)

$ErrorActionPreference = 'SilentlyContinue'

$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log { param([string]$Msg)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
    Add-Content -Path $LogFile -Value $line -Encoding ASCII
    Write-Host $line
}

Write-Log "startup-repair-m13: begin"

$targetPids  = @("0323","030D","0310")
$svcName     = "MagicMouseDriver"
$anyReboot   = $false
$anyRepaired = $false

foreach ($pid4 in $targetPids) {
    ${pidUpper} = $pid4.ToUpper()

    # Find the BTHENUM HID parent device for this PID.
    # Hardware ID format: BTHENUM\{00001124...}_VID&NNNN_PID&NNNN
    $btDevice = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match "BTHENUM" -and
            $_.InstanceId -match "00001124" -and
            $_.InstanceId -like ("*PID&" + $pid4 + "*") -and
            $_.Status -eq 'OK'
        } |
        Select-Object -First 1

    if (-not $btDevice) {
        Write-Log "PID 0x${pidUpper}: not paired or not ready - skipping"
        continue
    }

    Write-Log "PID 0x${pidUpper}: BTHENUM = $($btDevice.InstanceId)"

    # Count HIDClass child devices.
    $hidDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Class -eq 'HIDClass' -and
            $_.InstanceId -like ("*" + $pid4 + "*") -and
            $_.Status -eq 'OK'
        })
    $hidCount = $hidDevices.Count
    Write-Log "PID 0x${pidUpper}: HID count = $hidCount"

    # Ensure LowerFilters contains MagicMouseDriver.
    # pnputil /add-driver should have set this, but verify.
    $devRegPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $btDevice.InstanceId
    if (Test-Path $devRegPath) {
        $lf = (Get-ItemProperty -Path $devRegPath -Name "LowerFilters" -ErrorAction SilentlyContinue)."LowerFilters"
        if ($lf -notcontains $svcName) {
            Write-Log "PID 0x${pidUpper}: adding $svcName to LowerFilters"
            $newLf = @($lf) + $svcName | Where-Object { $_ }
            Set-ItemProperty -Path $devRegPath -Name "LowerFilters" -Value $newLf -Type MultiString -ErrorAction SilentlyContinue
        } else {
            Write-Log "PID 0x${pidUpper}: LowerFilters already contains $svcName"
        }
    }

    # Restart device to bind filter.
    Write-Log "PID 0x${pidUpper}: pnputil /restart-device $($btDevice.InstanceId)"
    $restartOut = & pnputil /restart-device "$($btDevice.InstanceId)" 2>&1
    $restartOut | ForEach-Object { Write-Log "  $_" }
    Start-Sleep -Seconds $SettleSeconds

    # Recount HID devices after restart.
    $hidAfter = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Class -eq 'HIDClass' -and
            $_.InstanceId -like ("*" + $pid4 + "*") -and
            $_.Status -eq 'OK'
        })
    $hidCountAfter = $hidAfter.Count

    if ($hidCountAfter -ge 1) {
        Write-Log "PID 0X${pidUpper}: HID OK ($hidCountAfter)"
        $anyRepaired = $true
    } else {
        Write-Log "PID 0X${pidUpper}: HID FAIL ($hidCountAfter) after restart"
    }
}

if ($anyRepaired) {
    Write-Log "startup-repair-m13: complete - at least one device repaired"
    exit 0
} else {
    Write-Log "startup-repair-m13: no paired devices found or all repaired already"
    exit 0
}
