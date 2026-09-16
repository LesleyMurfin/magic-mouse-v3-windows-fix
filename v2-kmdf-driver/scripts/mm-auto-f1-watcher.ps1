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
# F1 script location, in order of preference:
#   1. the copy mm-auto-f1-watcher-install.ps1 places beside this script in
#      ProgramData - the community install, where nothing else exists
#   2. a sibling in the folder this script was launched from (running the
#      release ZIP's scripts folder directly, before install)
#   3. C:\mm-dev-queue - the maintainer dev box
# Hard-coding (3) alone made the installed watcher fail with "FATAL missing F1
# script" on every machine but one.
$global:MmWatcherF1Script = $null
$MmWatcherF1Candidates = @(Join-Path $global:MmWatcherLogDir 'mm-f1-once.ps1')
if ($PSCommandPath) {
    $MmWatcherF1Candidates += (Join-Path (Split-Path -Parent $PSCommandPath) 'mm-f1-once.ps1')
}
$MmWatcherF1Candidates += 'C:\mm-dev-queue\mm-f1-once.ps1'
foreach ($cand in $MmWatcherF1Candidates) {
    if ($cand -and (Test-Path -LiteralPath $cand)) {
        $global:MmWatcherF1Script = $cand
        break
    }
}
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

if (-not $global:MmWatcherF1Script) {
    Write-MmWatcherLog ('FATAL no mm-f1-once.ps1 found in: ' + ($MmWatcherF1Candidates -join ' ; '))
    exit 2
}
Write-MmWatcherLog ('using F1 script ' + $global:MmWatcherF1Script)

# Drop any stale subscription from a previous run in the same session
# (harmless if none exists).
Get-EventSubscriber -SourceIdentifier 'MmAutoF1Watcher' -ErrorAction SilentlyContinue |
    Unregister-Event -ErrorAction SilentlyContinue

# Fires once per PID_0323 PnP entity (re-)creation: the BTHENUM node
# itself and/or its COL01/COL02 HID children, depending on how deep the
# reconnect went. Debounced below so one physical reconnect event does
# not run F1 several times in a row.
$query = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.PNPDeviceID LIKE '%PID_0323%'"

function global:Invoke-MmF1 {
    param(
        [Parameter(Mandatory)][string]$Reason,
        # Arrival-driven fires debounce against each other; the startup
        # reconcile deliberately does NOT arm the debounce, so a genuine
        # arrival landing seconds later still gets its own F1.
        [switch]$UpdateDebounce
    )
    if ($UpdateDebounce) {
        $now = Get-Date
        $elapsed = ($now - $global:MmWatcherLastFire).TotalSeconds
        if ($elapsed -lt $global:MmWatcherDebounceSeconds) {
            Write-MmWatcherLog ('debounced, ' + [Math]::Round($elapsed, 1) + 's since last fire')
            return
        }
        $global:MmWatcherLastFire = $now
    }

    Write-MmWatcherLog ('F1 fire (' + $Reason + ')')
    try {
        $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $global:MmWatcherF1Script 2>&1
        $exit = $LASTEXITCODE
        Write-MmWatcherLog ('F1 script exit=' + $exit)
        foreach ($ln in $out) { Write-MmWatcherLog ('F1: ' + $ln) }
    } catch {
        Write-MmWatcherLog ('F1 script threw: ' + $_)
    }
}

# True when the COL01 HID collection - the one mm-f1-once.ps1 targets -
# is actually enumerated right now.
#
# Matches PID[_&]0323 with a regex, NOT -like '*PID_0323*'. The real HID
# child ID uses an ampersand:
#   HID\{00001124-...-00805F9B34FB}_VID&0001004C_PID&0323&COL01\A&...&0000
# $query above gets away with '%PID_0323%' because in WQL '_' is a
# single-character wildcard; in PowerShell -like it is a literal, so the
# same string silently matches nothing. That typo made the first version
# of this reconcile report "COL01 not present" on a present device.
function global:Test-MmCol01Present {
    try {
        $hit = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object {
                $_.PNPDeviceID -match 'PID[_&]0323' -and
                $_.PNPDeviceID -match 'COL01'
            })
        foreach ($h in $hit) {
            Write-MmWatcherLog ('COL01 present: ' + $h.PNPDeviceID + ' status=' + $h.Status)
        }
        return ($hit.Count -gt 0)
    } catch {
        Write-MmWatcherLog ('COL01 presence probe failed: ' + $_)
        return $false
    }
}

$action = {
    $devId = 'unknown'
    try { $devId = $Event.SourceEventArgs.NewEvent.TargetInstance.PNPDeviceID } catch {}
    Write-MmWatcherLog ('PID_0323 PnP entity arrival: ' + $devId)

    # Give HidBth a moment to finish re-creating COL01/COL02 before
    # SetFeature - same 3s pause kmdf-204-pnputil-once.ps1 uses before F1.
    Start-Sleep -Seconds 3
    Invoke-MmF1 -Reason ('arrival ' + $devId) -UpdateDebounce
}

$null = Register-WmiEvent -Query $query -SourceIdentifier 'MmAutoF1Watcher' -Action $action

Write-MmWatcherLog 'WMI subscription registered, entering wait loop'

# Startup reconcile - the reason a reboot silently killed scroll on
# 2026-09-15 (STATUS.md). At boot the mouse is already paired and
# enumerated before this task's WMI subscription exists, so NO arrival
# event ever fires and MT stays in compact 9-byte mode until someone runs
# mm-f1-once.ps1 by hand. Arrival events alone therefore cannot cover
# boot; current state has to be reconciled once at startup.
#
# Deliberately unconditional when COL01 is present rather than gated on
# the Diag LastAclReceived counter: that value is registry-persisted, so
# it survives a reboot still reading the previous session's healthy 23
# and would wrongly report MT as already live. HidD_SetFeature(F1) is
# idempotent - re-arming an already-multitouch device just returns
# ok=True - so firing unconditionally is the safe direction to be wrong in.
#
# If the Bluetooth link is not up yet at this point, COL01 does not exist,
# no fire happens here, and the later connect raises a real arrival event
# that the subscription above handles.
# Registration happens before this probe so an arrival during the probe is queued, not lost.
if (Test-MmCol01Present) {
    Invoke-MmF1 -Reason 'startup reconcile, COL01 already present (boot/restart)'
} else {
    Write-MmWatcherLog 'startup reconcile: COL01 not present, waiting for arrival event'
}

while ($true) {
    $ev = Wait-Event -Timeout 300
    if ($ev) {
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
    } else {
        Write-MmWatcherLog 'heartbeat alive'
    }
}
