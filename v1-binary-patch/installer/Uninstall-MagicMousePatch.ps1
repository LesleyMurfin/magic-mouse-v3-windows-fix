#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls the Magic Mouse scroll fix (Apple driver install).

.DESCRIPTION
Reverts Install-MagicMousePatch.ps1 for any supported Magic Mouse - v1 (030D),
v2 (0269 / 0310) or v3 (0323) - restoring the system to its pre-installation
state.

Workflow:
  1. Confirmation prompt
  2. Stop the applewirelessmouse service
  3. Find the paired Magic Mouse (report every match) and disable the selected
     one, so the loaded driver is not holding its files open
  4. Remove 'applewirelessmouse' from LowerFilters (REG_MULTI_SZ) on EVERY
     supported Magic Mouse device-instance key under
     HKLM\SYSTEM\CurrentControlSet\Enum\ - the service is machine-global, so
     more than one instance can be bound to it
  5. Restore the backup from C:\ProgramData\MagicMousePatch\backup\, or delete
     the installed driver when there is no backup to restore
  6. Delete the service key (HKLM\SYSTEM\CurrentControlSet\Services\
     applewirelessmouse)
  7. Remove the MagicMouseFix certificate from LocalMachine\TrustedPublisher
     by thumbprint - a no-op on an Apple-signed install, which imports none
  8. Re-enable the device, but only when step 3 actually disabled it
  9. Remove C:\ProgramData\MagicMousePatch\
 10. Reboot instruction

Exits 0 when every step it attempted succeeded, 1 when any step failed; the
remaining steps still run either way, because a half-installed state has to be
cleaned up as far as it can be.

.PARAMETER TargetPid
Restrict the disable / re-enable step (3 and 8) to the mouse with this Bluetooth
PID. Use it when several Magic Mice are paired and only one of them was patched.
The LowerFilters cleanup in step 4 is always exhaustive: 'applewirelessmouse' is
this project's own service name, so removing it from any Magic Mouse instance is
correct regardless of -TargetPid, and every other filter in those values is
preserved.

.EXAMPLE
.\Uninstall-MagicMousePatch.ps1

.EXAMPLE
.\Uninstall-MagicMousePatch.ps1 -TargetPid 030D

.NOTES
Author:  Revive Business Solutions
License: MIT
Contact: riley@revivebusiness.ca
#>

param(
    # Restrict the disable / re-enable step to one model, e.g. -TargetPid 030D. Mirrors
    # the installer. It does not scope the LowerFilters cleanup, which is exhaustive.
    [ValidateSet('030D','0310','0269','0323')]
    [string]$TargetPid
)

# ============================================================================
# Configuration
# ============================================================================

# Continue, not Stop: an uninstaller has to push through partial state. Every
# step below is individually guarded and verifies its own result, so a failure
# is reported rather than assumed away.
$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$TargetDriver   = "C:\Windows\System32\drivers\applewirelessmouse.sys"
$BackupDir      = "C:\ProgramData\MagicMousePatch\backup"
$DataDir        = "C:\ProgramData\MagicMousePatch"
$ServiceName    = "applewirelessmouse"

# CN=MagicMouseFix - only ever imported by the legacy patched-and-resigned
# route. The Apple-signed route imports no certificate at all.
$CertThumbprint = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"

# Models the installer can bind, keyed by the Bluetooth PID in the InstanceId.
$MagicMouseModels = @(
    [pscustomobject]@{ Pid = '0323'; Name = 'Magic Mouse v3 (2024, USB-C)' }
    [pscustomobject]@{ Pid = '0269'; Name = 'Magic Mouse v2'              }
    [pscustomobject]@{ Pid = '0310'; Name = 'Magic Mouse v2 (alt PID)'    }
    [pscustomobject]@{ Pid = '030D'; Name = 'Magic Mouse v1'              }
)

# Matches any supported model on the Bluetooth HID (00001124) profile, and the same
# narrowed to the one model asked for with -TargetPid.
$MagicMouseAnyRe    = 'BTHENUM.*00001124.*PID&(0323|0269|0310|030D)'
$MagicMouseDeviceRe = if ($TargetPid) { 'BTHENUM.*00001124.*PID&' + $TargetPid } else { $MagicMouseAnyRe }

# Set by any step that could not complete; decides the exit code.
$script:Failed = $false

# Whether step 3 actually took the device down. Only then is there anything to
# re-enable at the end, and only then is a failed re-enable a real problem.
$script:DeviceDisabled = $false

# ============================================================================
# Helpers
# ============================================================================

function Write-Status {
    param([string]$Message, [string]$Status = "OK")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Gray" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $color
}

function Write-Failure {
    param([string]$Message)
    $script:Failed = $true
    Write-Status $Message "ERROR"
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
}

# -AllModels ignores -TargetPid: the LowerFilters cleanup has to see every patched
# instance, not just the one being disabled.
function Get-MagicMouseDevice {
    param([switch]$AllModels)
    $re = if ($AllModels) { $MagicMouseAnyRe } else { $MagicMouseDeviceRe }
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match $re }
}

function Get-MagicMouseModel {
    param([string]$InstanceId)
    foreach ($m in $MagicMouseModels) {
        if ($InstanceId -match ('PID&' + $m.Pid)) { return $m }
    }
    return $null
}

# LowerFilters lives on the device-instance key itself, exactly where the
# installer wrote it - not in a Device Parameters subkey.
function Get-MagicMouseInstanceRegPath {
    param([string]$InstanceId)
    return "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
}

# ============================================================================
# Steps
# ============================================================================

function Stop-MagicMouseService {
    Write-Section "Stopping applewirelessmouse service..."
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Status "Service not present (already removed?)" "OK"
        return
    }
    if ($svc.Status -ne 'Running') {
        Write-Status "Service not running" "OK"
        return
    }
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        # Not fatal: the service key is deleted later and the driver unloads on
        # reboot anyway.
        Write-Status "Service still running; it will unload on reboot" "WARN"
    } else {
        Write-Status "Service stopped" "OK"
    }
}

# Returns the InstanceId that was selected - whether or not the disable worked - or $null
# when no supported mouse is paired, so the re-enable at the end knows what to bring back.
# $script:DeviceDisabled records whether it was really disabled. The LowerFilters cleanup
# does not use this id: it visits every supported instance.
function Disable-MagicMouseDevice {
    Write-Section "Finding the Magic Mouse..."
    $found = @(Get-MagicMouseDevice)
    if ($found.Count -eq 0) {
        $scope = if ($TargetPid) { "PID $TargetPid" } else { "PID 0323 / 0269 / 0310 / 030D" }
        Write-Status "No Magic Mouse paired ($scope) -- skipping device steps" "OK"
        return $null
    }

    foreach ($d in $found) {
        $model = Get-MagicMouseModel -InstanceId $d.InstanceId
        $name  = if ($model) { $model.Name } else { 'unrecognised PID' }
        Write-Host "  $name  -  $($d.FriendlyName)" -ForegroundColor Gray
        Write-Host "    $($d.InstanceId)" -ForegroundColor Gray
    }

    $mouse = $found[0]
    if ($found.Count -gt 1) {
        Write-Status "$($found.Count) Magic Mice paired; disabling only the first listed (LowerFilters is cleaned on all of them)" "WARN"
        Write-Host "  Re-run with -TargetPid <030D|0310|0269|0323> to pick another." -ForegroundColor Yellow
    }

    Write-Section "Disabling the device..."
    # An optimisation only: the registry revert does not need the device down, it just
    # takes effect on reboot rather than immediately. A failure here is therefore a
    # WARN, and the device is not re-enabled later, because it was never disabled.
    try {
        Disable-PnpDevice -InstanceId $mouse.InstanceId -Confirm:$false -ErrorAction Stop
        $script:DeviceDisabled = $true
        Start-Sleep -Seconds 5
        Write-Status "Disabled $($mouse.InstanceId)" "OK"
    } catch {
        Write-Status "Could not disable the device: $($_.Exception.Message); continuing" "WARN"
    }
    return $mouse.InstanceId
}

function Remove-InstalledDriver {
    if (-not (Test-Path $TargetDriver)) {
        Write-Status "$TargetDriver already absent" "OK"
        return
    }
    Remove-Item -Path $TargetDriver -Force -ErrorAction SilentlyContinue
    if (Test-Path $TargetDriver) {
        Write-Failure "Could not remove $TargetDriver (in use? reboot and re-run)"
    } else {
        Write-Status "Removed $TargetDriver" "OK"
    }
}

function Restore-DriverBackup {
    Write-Section "Restoring driver from backup..."
    $backups = @()
    if (Test-Path $BackupDir) {
        $backups = @(Get-ChildItem -Path $BackupDir -Filter "applewirelessmouse_*.sys" -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending)
    }
    if ($backups.Count -eq 0) {
        # Nothing to put back: before the install there was no Apple driver in
        # System32\drivers at all, so deleting it IS the correct revert.
        Write-Status "No backup to restore; removing the installed driver instead" "WARN"
        Remove-InstalledDriver
        return
    }

    $latest = $backups[0]
    Write-Host "  Restoring: $($latest.FullName)" -ForegroundColor Gray
    Copy-Item -LiteralPath $latest.FullName -Destination $TargetDriver -Force -ErrorAction SilentlyContinue
    if (Test-Path $TargetDriver) {
        $restored = (Get-FileHash -LiteralPath $TargetDriver -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        $expected = (Get-FileHash -LiteralPath $latest.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($restored -and $expected -and $restored -ne $expected) {
            Write-Failure "Copied file does not match the backup (driver may be locked; reboot and re-run)"
            return
        }
        Write-Status "Restored driver from $($latest.Name)" "OK"
    } else {
        Write-Failure "Could not restore $TargetDriver from $($latest.Name)"
    }
}

# -TargetPid selects the single device that gets disabled and re-enabled; it deliberately
# does NOT scope this cleanup. The applewirelessmouse service is machine-global, so an
# install run twice with different -TargetPid values leaves its name in the LowerFilters
# of two device instances, and every one of them has to lose it before the service key
# and the driver file go away - otherwise Windows keeps resolving a filter that is gone.
function Remove-MagicMouseFilterBinding {
    Write-Section "Removing 'applewirelessmouse' from LowerFilters..."
    $found = @(Get-MagicMouseDevice -AllModels)
    if ($found.Count -eq 0) {
        Write-Status "No Magic Mouse paired -- no LowerFilters to clean" "OK"
        return
    }
    foreach ($d in $found) {
        $model = Get-MagicMouseModel -InstanceId $d.InstanceId
        $name  = if ($model) { $model.Name } else { 'unrecognised PID' }
        Write-Host "  $name" -ForegroundColor Gray
        Remove-LowerFiltersEntry -InstanceId $d.InstanceId
    }
}

# One device instance. An instance that never listed our filter is reported and left
# alone, which is a normal outcome and not a failure.
function Remove-LowerFiltersEntry {
    param([string]$InstanceId)
    $instancePath = Get-MagicMouseInstanceRegPath -InstanceId $InstanceId
    if (-not (Test-Path $instancePath)) {
        Write-Status "Instance key not found: $instancePath" "OK"
        return
    }
    Write-Host "  Instance key: $instancePath" -ForegroundColor Gray

    $cur = (Get-ItemProperty -Path $instancePath -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters
    if (-not $cur) {
        Write-Status "No LowerFilters value present" "OK"
        return
    }
    # Piping through Where-Object normalises REG_MULTI_SZ (string[]), a single
    # string and a $null into a real array, so .Count is always meaningful.
    $entries = @($cur | Where-Object { $_ })
    if ($entries -notcontains $ServiceName) {
        Write-Status "LowerFilters does not list $ServiceName; left untouched" "OK"
        return
    }

    # Preserve every other filter that was there. New-ItemProperty -Force overwrites the
    # value in place and honours -PropertyType, so nothing is removed first: a write that
    # is then refused must not be able to destroy another vendor's filters. With nothing
    # left to keep, Remove-ItemProperty is the right call instead - an empty
    # REG_MULTI_SZ is not what was there before the install.
    $kept = @($entries | Where-Object { $_ -and ($_ -ne $ServiceName) })
    # The Enum tree is the PnP manager's and can be SYSTEM-owned, in which case even an
    # elevated write is refused. -ErrorAction Stop so that condition is named here rather
    # than silently leaving the filter in place.
    try {
        if ($kept.Count -gt 0) {
            New-ItemProperty -Path $instancePath -Name 'LowerFilters' -Value $kept -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
        } else {
            Remove-ItemProperty -Path $instancePath -Name 'LowerFilters' -Force -ErrorAction Stop
        }
    } catch [System.UnauthorizedAccessException], [System.Security.SecurityException] {
        Write-Failure "Access denied re-writing LowerFilters: $($_.Exception.Message)"
        Write-Host "  That key is owned by SYSTEM on this machine, so Administrator rights are not" -ForegroundColor Yellow
        Write-Host "  enough to write it. Two ways forward:" -ForegroundColor Yellow
        Write-Host "    1. Re-run this uninstaller in a SYSTEM context, e.g." -ForegroundColor Yellow
        Write-Host "       psexec -s -i powershell.exe -File .\Uninstall-MagicMousePatch.ps1" -ForegroundColor Yellow
        Write-Host "    2. Grant your account write access to that one device-instance key:" -ForegroundColor Yellow
        Write-Host "       HKLM\SYSTEM\CurrentControlSet\Enum\$InstanceId" -ForegroundColor Yellow
        return
    } catch {
        Write-Failure "Could not re-write LowerFilters at ${instancePath}: $($_.Exception.Message)"
        return
    }

    $after = (Get-ItemProperty -Path $instancePath -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters
    $afterList = @($after | Where-Object { $_ })
    if ($afterList -contains $ServiceName) {
        Write-Failure "LowerFilters still lists $ServiceName at $instancePath"
    } elseif ($kept.Count -ne $afterList.Count) {
        Write-Failure "LowerFilters re-write lost entries; expected [$([string]::Join(', ', $kept))], found [$([string]::Join(', ', $afterList))]"
    } elseif ($afterList.Count -gt 0) {
        Write-Status "Re-wrote LowerFilters without ${ServiceName}: [$([string]::Join(', ', $afterList))]" "OK"
    } else {
        Write-Status "Removed LowerFilters entirely (no remaining entries)" "OK"
    }
}

function Remove-MagicMouseService {
    Write-Section "Removing applewirelessmouse service registry key..."
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path $regPath)) {
        Write-Status "Service registry key not present" "OK"
        return
    }
    Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $regPath) {
        Write-Failure "Could not remove $regPath"
    } else {
        Write-Status "Removed $regPath" "OK"
    }
}

function Remove-MagicMouseCert {
    Write-Section "Removing MagicMouseFix cert from TrustedPublisher..."
    $store = $null
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $certMatches = @($store.Certificates | Where-Object { $_.Thumbprint -eq $CertThumbprint })
        if ($certMatches.Count -eq 0) {
            # Expected on an Apple-signed install: that route imports no
            # certificate, so there is nothing here to undo.
            Write-Status "No MagicMouseFix cert imported -- nothing to remove" "OK"
            return
        }
        foreach ($c in $certMatches) {
            $store.Remove($c)
            Write-Status "Removed cert $($c.Thumbprint)" "OK"
        }
    } catch {
        Write-Failure "Cert removal failed: $_"
    } finally {
        if ($store) { $store.Close() }
    }
}

function Enable-MagicMouseDevice {
    param([string]$InstanceId)
    Write-Section "Re-enabling device..."
    if (-not $InstanceId) {
        Write-Status "No instance to re-enable" "OK"
        return
    }
    if (-not $script:DeviceDisabled) {
        Write-Status "Device was never disabled -- nothing to re-enable" "OK"
        return
    }
    try {
        Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Failure "Could not re-enable ${InstanceId}: $($_.Exception.Message)"
        Write-Host "  Re-enable it in Device Manager, or unpair and re-pair the mouse." -ForegroundColor Yellow
        return
    }
    Start-Sleep -Seconds 8
    Write-Status "Enabled $InstanceId" "OK"
}

function Remove-DataDirectory {
    Write-Section "Cleaning up C:\ProgramData\MagicMousePatch\..."
    if (-not (Test-Path $DataDir)) {
        Write-Status "$DataDir not present" "OK"
        return
    }
    Remove-Item -Path $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $DataDir) {
        Write-Failure "Could not remove $DataDir"
    } else {
        Write-Status "Removed $DataDir" "OK"
    }
}

# ============================================================================
# Main
# ============================================================================

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Magic Mouse Scroll Fix Uninstaller"      -ForegroundColor Cyan
    Write-Host " Apple driver route"                     -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This will remove the scroll fix and restore your system." -ForegroundColor Yellow
    $confirm = Read-Host "Continue with uninstallation? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Uninstallation cancelled." -ForegroundColor Yellow
        exit 0
    }

    Stop-MagicMouseService
    $iid = Disable-MagicMouseDevice
    # Unbind the filter from every patched instance first: after this point the service
    # key and the driver file go away, and a LowerFilters entry naming either of them
    # would be left for Windows to resolve at every boot.
    Remove-MagicMouseFilterBinding
    Restore-DriverBackup
    Remove-MagicMouseService
    Remove-MagicMouseCert
    Enable-MagicMouseDevice -InstanceId $iid
    Remove-DataDirectory

    Write-Host ""
    if ($script:Failed) {
        Write-Host "========================================" -ForegroundColor Red
        Write-Host " Uninstallation Incomplete"              -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Read the [ERROR] lines above, reboot, then run this script again." -ForegroundColor Yellow
        Write-Host "Support: riley@revivebusiness.ca" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }

    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Uninstallation Complete"                 -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEP: Reboot your computer." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  shutdown /r /t 60 /c 'Magic Mouse Patch removed - rebooting'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "After reboot, your system will be restored to its pre-patch state." -ForegroundColor Gray
    Write-Host ""
    Write-Host "The Apple driver route never needed Test Signing. If you turned it" -ForegroundColor Cyan
    Write-Host "on for the older patched-and-resigned driver, turn it off (Admin):" -ForegroundColor Cyan
    Write-Host "  bcdedit /set testsigning off" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Support: riley@revivebusiness.ca" -ForegroundColor Gray
    Write-Host ""
}

try {
    Main
} catch {
    Write-Host ""
    Write-Status "Uninstallation error: $_" "ERROR"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ""
    Write-Host "Support: riley@revivebusiness.ca" -ForegroundColor Yellow
    exit 1
}
