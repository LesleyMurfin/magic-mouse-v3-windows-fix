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
$F1Dest      = Join-Path $DataDir 'mm-f1-once.ps1'
$Here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatcherSrc  = Join-Path $Here 'mm-auto-f1-watcher.ps1'
$F1Src       = Join-Path $Here 'mm-f1-once.ps1'

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

# The watcher shells out to its sibling mm-f1-once.ps1, so both have to land
# in $DataDir - staging the watcher alone leaves it with nothing to run.
if (-not (Test-Path -LiteralPath $F1Src)) {
    Write-Output ('FATAL missing F1 source ' + $F1Src)
    exit 2
}

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

# C:\ProgramData carries an inheritable CREATOR OWNER Full Control ACE, so if
# $DataDir was created by a standard user it is writable by that user - and the
# scheduled task below runs the staged scripts as SYSTEM. Take ownership back and
# replace the DACL with an explicit, protected one BEFORE anything is copied in.
try {
    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $sidUsers  = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)
    $full      = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readExec  = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $inherit   = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $noProp    = [System.Security.AccessControl.PropagationFlags]::None
    $allow     = [System.Security.AccessControl.AccessControlType]::Allow

    $acl = Get-Acl -LiteralPath $DataDir
    # $true = protect the DACL from inheritance, $false = do not keep a copy of
    # the inherited ACEs (that copy is what would preserve CREATOR OWNER).
    $acl.SetAccessRuleProtection($true, $false)
    # An explicit ACE written by whoever created the directory would survive the
    # line above, so purge every explicit identity before granting anything.
    foreach ($ace in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
        $acl.PurgeAccessRules($ace.IdentityReference)
    }
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem, $full, $inherit, $noProp, $allow)))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins, $full, $inherit, $noProp, $allow)))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidUsers, $readExec, $inherit, $noProp, $allow)))
    # The owner holds WRITE_DAC implicitly and could undo the ACEs above, so a
    # standard-user owner has to go. This is the step that closes the hole.
    $acl.SetOwner($sidAdmins)
    Set-Acl -LiteralPath $DataDir -AclObject $acl

    $nameSystem = $sidSystem.Translate([System.Security.Principal.NTAccount]).Value
    $nameAdmins = $sidAdmins.Translate([System.Security.Principal.NTAccount]).Value
    $nameUsers  = $sidUsers.Translate([System.Security.Principal.NTAccount]).Value
    Write-Output ('secured ' + $DataDir + ' - inheritance off, owner ' + $nameAdmins +
        ', full control ' + $nameSystem + ' + ' + $nameAdmins + ', read-only ' + $nameUsers)
}
catch {
    Write-Output ('FATAL could not secure ' + $DataDir + ' - ' + $_.Exception.Message)
    exit 4
}

# Copy-Item -Force overwrites an existing file in place, which keeps that file's
# owner (and the WRITE_DAC that comes with ownership). Delete first so both
# SYSTEM-executed scripts are fresh objects under the DACL set above.
foreach ($dest in @($WatcherDest, $F1Dest)) {
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
}

Copy-Item -LiteralPath $WatcherSrc -Destination $WatcherDest -Force
Copy-Item -LiteralPath $F1Src -Destination $F1Dest -Force
Write-Output ('installed watcher script to ' + $WatcherDest)
Write-Output ('installed F1 script to ' + $F1Dest)

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
