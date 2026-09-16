# mm-auto-f1-watcher-install.ps1
#
# Installs mm-auto-f1-watcher.ps1 as a Scheduled Task so PID 0323 scroll
# survives a Bluetooth HID reconnect (tray toggle, unpair/re-pair,
# sleep/wake, reboot) without anyone running mm-f1-once.ps1 by hand.
#
# Userspace only. Does not touch the driver, the service, or any .sys
# file. Safe to run repeatedly - re-registers the task idempotently.
#
# .PARAMETER Uninstall
# Remove the scheduled task and stop the running watcher, if any.

[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$TaskName    = 'MmAutoF1Watcher'
$DataDir     = 'C:\ProgramData\MagicMouseDriver'
$WatcherDest = Join-Path $DataDir 'mm-auto-f1-watcher.ps1'
$Here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatcherSrc  = Join-Path $Here 'mm-auto-f1-watcher.ps1'

function Test-MmIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-MmIsAdmin)) {
    Write-Output 'FATAL must run elevated (Administrator)'
    exit 3
}

if ($Uninstall) {
    Write-Output "=== removing scheduled task $TaskName ==="
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output 'task removed'
    } else {
        Write-Output 'task not present'
    }
    exit 0
}

Write-Output '===== mm-auto-f1-watcher install start ====='

if (-not (Test-Path -LiteralPath $WatcherSrc)) {
    Write-Output ('FATAL missing watcher source ' + $WatcherSrc)
    exit 2
}

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
Copy-Item -LiteralPath $WatcherSrc -Destination $WatcherDest -Force
Write-Output ('installed watcher script to ' + $WatcherDest)

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Output 'existing task found, stopping and unregistering before re-register'
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $WatcherDest + '"')
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description `
    'Re-sends HidD_SetFeature F1 on PID 0323 COL01 when it reconnects, so 2-finger scroll survives a Bluetooth re-enumeration without a manual script run.' `
    | Out-Null
Write-Output ('registered scheduled task ' + $TaskName)

Write-Output '=== starting task now (do not wait for next reboot) ==='
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
Write-Output ('LastTaskResult=' + $info.LastTaskResult + ' State=' + (Get-ScheduledTask -TaskName $TaskName).State)

Write-Output '===== mm-auto-f1-watcher install done ====='
exit 0
