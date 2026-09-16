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
  3. Find the paired Magic Mouse (report every match, act on the selected one)
     and pnputil /disable-device it
  4. Restore the backup from C:\ProgramData\MagicMousePatch\backup\, or delete
     the installed driver when there is no backup to restore
  5. Remove 'applewirelessmouse' from LowerFilters (REG_MULTI_SZ) on that
     device-instance key under HKLM\SYSTEM\CurrentControlSet\Enum\
  6. Delete the service key (HKLM\SYSTEM\CurrentControlSet\Services\
     applewirelessmouse)
  7. Remove the MagicMouseFix certificate from LocalMachine\TrustedPublisher
     by thumbprint - a no-op on an Apple-signed install, which imports none
  8. pnputil /enable-device
  9. Remove C:\ProgramData\MagicMousePatch\
 10. Reboot instruction

Exits 0 when every step it attempted succeeded, 1 when any step failed; the
remaining steps still run either way, because a half-installed state has to be
cleaned up as far as it can be.

.PARAMETER TargetPid
Revert only the mouse with this Bluetooth PID. Use it when several Magic Mice
are paired and only one of them was patched.

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
    # Restrict to one model, e.g. -TargetPid 030D. Mirrors the installer.
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

# Matches any supported model on the Bluetooth HID (00001124) profile, or just
# the one asked for with -TargetPid.
$MagicMouseDeviceRe = if ($TargetPid) {
    'BTHENUM.*00001124.*PID&' + $TargetPid
} else {
    'BTHENUM.*00001124.*PID&(0323|0269|0310|030D)'
}

# Set by any step that could not complete; decides the exit code.
$script:Failed = $false

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

function Get-MagicMouseDevice {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match $MagicMouseDeviceRe }
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

# Returns the InstanceId that was disabled, so the same device is re-enabled at
# the end, or $null when no supported mouse is paired.
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
        Write-Status "$($found.Count) Magic Mice paired; reverting only the first listed" "WARN"
        Write-Host "  Re-run with -TargetPid <030D|0310|0269|0323> to pick another." -ForegroundColor Yellow
    }

    Write-Section "Disabling the device..."
    & pnputil /disable-device "$($mouse.InstanceId)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Carry on: the registry revert below does not need the device down, it
        # just takes effect on reboot rather than immediately.
        Write-Status "pnputil /disable-device returned $LASTEXITCODE; continuing" "WARN"
    } else {
        Start-Sleep -Seconds 5
        Write-Status "Disabled $($mouse.InstanceId)" "OK"
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

function Remove-LowerFiltersEntry {
    param([string]$InstanceId)
    Write-Section "Removing 'applewirelessmouse' from LowerFilters..."
    if (-not $InstanceId) {
        Write-Status "No device selected -- no LowerFilters to remove" "OK"
        return
    }
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

    # Preserve every other filter that was there.
    $kept = @($entries | Where-Object { $_ -and ($_ -ne $ServiceName) })
    Remove-ItemProperty -Path $instancePath -Name 'LowerFilters' -Force -ErrorAction SilentlyContinue
    if ($kept.Count -gt 0) {
        New-ItemProperty -Path $instancePath -Name 'LowerFilters' -Value $kept -PropertyType MultiString -Force -ErrorAction SilentlyContinue | Out-Null
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
    & pnputil /enable-device "$InstanceId" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Failure "pnputil /enable-device returned $LASTEXITCODE for $InstanceId"
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
    Restore-DriverBackup
    Remove-LowerFiltersEntry -InstanceId $iid
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
