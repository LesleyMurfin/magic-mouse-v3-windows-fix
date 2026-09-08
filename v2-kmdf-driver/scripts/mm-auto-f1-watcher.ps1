# mm-auto-f1-watcher.ps1
#
# Auto-F1 watcher for PID 0323 (Apple Magic Mouse KMDF 2.0.4 scroll).
#
# Root cause (v2-kmdf-driver/STATUS.md, incident 2026-09-08): anything that
# re-enumerates the PID_0323 Bluetooth HID connection - the Magic Tray
# "Enabled on this PC" toggle, unpair/re-pair, sleep/wake, or a reboot -
# can silently drop multitouch to compact 9-byte ACL reports and kill
# 2-finger surface scroll. Driver.c MmSendMtEnable only auto-recovers if a
# BRB_L2CA_OPEN_CHANNEL was snooped for MtControlHandle, and that does not
# always happen on reconnect (see STATUS.md "Why the kernel doesn't
# already auto-send F1"). The proven userspace fix is re-running
# HidD_SetFeature([0xF1,0x02,0x01]) on COL01 - exactly what
# C:\mm-dev-queue\mm-f1-once.ps1 already does.
#
# This script does NOT touch the driver, the service, or any .sys file.
# It watches for PID_0323 PnP entity arrival (WMI __InstanceCreationEvent
# on Win32_PnPEntity) and re-runs mm-f1-once.ps1 automatically, so scroll
# survives a reconnect without anyone running a script by hand.
#
# Runs indefinitely. Install as a Scheduled Task with
# mm-auto-f1-watcher-install.ps1 (runs at startup, SYSTEM, restarts on
# failure).

$ErrorActionPreference = 'Continue'

$global:MmWatcherLogDir          = 'C:\ProgramData\MagicMouseDriver'
$global:MmWatcherLogFile         = Join-Path $global:MmWatcherLogDir 'auto-f1-watcher.log'
$global:MmWatcherF1Script        = 'C:\mm-dev-queue\mm-f1-once.ps1'
$global:MmWatcherDebounceSeconds = 5
$global:MmWatcherLastFire        = [DateTime]'2000-01-01'

if (-not (Test-Path -LiteralPath $global:MmWatcherLogDir)) {
    New-Item -ItemType Directory -Path $global:MmWatcherLogDir -Force | Out-Null
}

function global:Write-MmWatcherLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $global:MmWatcherLogFile -Value $line -Encoding ASCII
    Write-Output $line
}

Write-MmWatcherLog 'mm-auto-f1-watcher starting'

if (-not (Test-Path -LiteralPath $global:MmWatcherF1Script)) {
    Write-MmWatcherLog ('FATAL missing F1 script ' + $global:MmWatcherF1Script)
    exit 2
}

# Drop any stale subscription from a previous run in the same session
# (harmless if none exists).
Get-EventSubscriber -SourceIdentifier 'MmAutoF1Watcher' -ErrorAction SilentlyContinue |
    Unregister-Event -ErrorAction SilentlyContinue

# Fires once per PID_0323 PnP entity (re-)creation: the BTHENUM node
# itself and/or its COL01/COL02 HID children, depending on how deep the
# reconnect went. Debounced below so one physical reconnect event does
# not run F1 several times in a row.
$query = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.PNPDeviceID LIKE '%PID_0323%'"

$action = {
    $now = Get-Date
    $elapsed = ($now - $global:MmWatcherLastFire).TotalSeconds
    if ($elapsed -lt $global:MmWatcherDebounceSeconds) {
        Write-MmWatcherLog ('debounced, ' + [Math]::Round($elapsed, 1) + 's since last fire')
        return
    }
    $global:MmWatcherLastFire = $now

    $devId = 'unknown'
    try { $devId = $Event.SourceEventArgs.NewEvent.TargetInstance.PNPDeviceID } catch {}
    Write-MmWatcherLog ('PID_0323 PnP entity arrival: ' + $devId)

    # Give HidBth a moment to finish re-creating COL01/COL02 before
    # SetFeature - same 3s pause kmdf-204-pnputil-once.ps1 uses before F1.
    Start-Sleep -Seconds 3

    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $global:MmWatcherF1Script 2>&1
        $exit = $LASTEXITCODE
        Write-MmWatcherLog ('F1 script exit=' + $exit)
        foreach ($ln in $out) { Write-MmWatcherLog ('F1: ' + $ln) }
    } catch {
        Write-MmWatcherLog ('F1 script threw: ' + $_)
    }
}

$null = Register-WmiEvent -Query $query -SourceIdentifier 'MmAutoF1Watcher' -Action $action

Write-MmWatcherLog 'WMI subscription registered, entering wait loop'

while ($true) {
    $ev = Wait-Event -Timeout 300
    if ($ev) {
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
    } else {
        Write-MmWatcherLog 'heartbeat alive'
    }
}
