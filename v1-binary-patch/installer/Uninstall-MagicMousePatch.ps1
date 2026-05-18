#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls the Magic Mouse v3 scroll fix (PATH-A binary patch).

.DESCRIPTION
Mirrors Install-MagicMousePatch.ps1 in reverse, restoring the system to its
pre-installation state.

Workflow:
  1. Elevation check
  2. Stop applewirelessmouse service
  3. pnputil /disable-device on the v3 device (if paired)
  4. Restore backup from C:\ProgramData\MagicMousePatch\backup\ via Copy-Item
  5. Remove 'applewirelessmouse' from LowerFilters (REG_MULTI_SZ) at the
     device-instance level under HKLM\...\Enum\BTHENUM
  6. Delete service registry key (HKLM\...\Services\applewirelessmouse)
  7. Remove MagicMouseFix cert from TrustedPublisher (by thumbprint)
  8. pnputil /enable-device
  9. Remove C:\ProgramData\MagicMousePatch\
 10. Reboot prompt

.EXAMPLE
.\Uninstall-MagicMousePatch.ps1

.NOTES
Author:  Revive Business Solutions
License: MIT
Contact: riley@revivebusiness.ca
#>

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$TargetDriver       = "C:\Windows\System32\drivers\applewirelessmouse.sys"
$BackupDir          = "C:\ProgramData\MagicMousePatch\backup"
$DataDir            = "C:\ProgramData\MagicMousePatch"
$ServiceName        = "applewirelessmouse"
$CertThumbprint     = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"
$MagicMouseDeviceRe = 'BTHENUM.*00001124.*PID&0323'

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

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
}

function Get-MagicMouseV3 {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match $MagicMouseDeviceRe } |
        Select-Object -First 1
}

function Get-MagicMouseInstanceRegPath {
    $enumRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"
    if (-not (Test-Path $enumRoot)) { return $null }
    foreach ($lvl1 in Get-ChildItem $enumRoot -ErrorAction SilentlyContinue) {
        if ($lvl1.PSChildName -notmatch '00001124') { continue }
        foreach ($lvl2 in Get-ChildItem $lvl1.PSPath -ErrorAction SilentlyContinue) {
            if ($lvl1.PSChildName -match 'PID&0323' -or $lvl2.PSChildName -match 'PID&0323') {
                return $lvl2.PSPath
            }
        }
    }
    return $null
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
    if ($svc.Status -eq 'Running') {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Status "Service stopped" "OK"
    } else {
        Write-Status "Service not running" "OK"
    }
}

function Disable-MagicMouseDevice {
    Write-Section "Disabling Magic Mouse v3 device (if paired)..."
    $v3 = Get-MagicMouseV3
    if (-not $v3) {
        Write-Status "v3 device not paired -- skipping disable" "OK"
        return $null
    }
    & pnputil /disable-device "$($v3.InstanceId)" 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    Write-Status "Disabled $($v3.InstanceId)" "OK"
    return $v3.InstanceId
}

function Restore-DriverBackup {
    Write-Section "Restoring driver from backup..."
    if (-not (Test-Path $BackupDir)) {
        Write-Status "No backup directory; removing patched driver instead" "WARN"
        if (Test-Path $TargetDriver) {
            Remove-Item -Path $TargetDriver -Force -ErrorAction SilentlyContinue
            Write-Status "Removed $TargetDriver" "OK"
        }
        return
    }
    $backups = Get-ChildItem -Path $BackupDir -Filter "applewirelessmouse_*.sys" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending
    if (-not $backups) {
        Write-Status "No backup files found; removing patched driver instead" "WARN"
        if (Test-Path $TargetDriver) {
            Remove-Item -Path $TargetDriver -Force -ErrorAction SilentlyContinue
            Write-Status "Removed $TargetDriver" "OK"
        }
        return
    }
    $latest = $backups[0].FullName
    Write-Host "  Restoring: $latest" -ForegroundColor Gray
    Copy-Item -Path $latest -Destination $TargetDriver -Force
    Write-Status "Restored driver from $($backups[0].Name)" "OK"
}

function Remove-LowerFiltersEntry {
    Write-Section "Removing 'applewirelessmouse' from LowerFilters..."
    $instancePath = Get-MagicMouseInstanceRegPath
    if (-not $instancePath) {
        Write-Status "BTHENUM instance key not found -- nothing to remove" "OK"
        return
    }
    $cur = (Get-ItemProperty -Path $instancePath -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters
    if (-not $cur) {
        Write-Status "No LowerFilters value present at $instancePath" "OK"
        return
    }
    if ($cur -is [array]) {
        $entries = @($cur)
    } else {
        $entries = @([string]$cur)
    }
    $kept = @($entries | Where-Object { $_ -and ($_ -ne $ServiceName) })
    Remove-ItemProperty -Path $instancePath -Name 'LowerFilters' -Force -ErrorAction SilentlyContinue
    if ($kept.Count -gt 0) {
        New-ItemProperty -Path $instancePath -Name 'LowerFilters' -Value $kept -PropertyType MultiString -Force | Out-Null
        Write-Status "Re-wrote LowerFilters without applewirelessmouse: [$([string]::Join(', ', $kept))]" "OK"
    } else {
        Write-Status "Removed LowerFilters entirely (no remaining entries)" "OK"
    }
}

function Remove-MagicMouseService {
    Write-Section "Removing applewirelessmouse service registry key..."
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (Test-Path $regPath) {
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status "Removed $regPath" "OK"
    } else {
        Write-Status "Service registry key not present" "OK"
    }
}

function Remove-MagicMouseCert {
    Write-Section "Removing MagicMouseFix cert from TrustedPublisher..."
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $matches = @($store.Certificates | Where-Object { $_.Thumbprint -eq $CertThumbprint })
        foreach ($c in $matches) {
            $store.Remove($c)
            Write-Status "Removed cert $($c.Thumbprint)" "OK"
        }
        $store.Close()
        if ($matches.Count -eq 0) {
            Write-Status "No matching cert in TrustedPublisher" "OK"
        }
    } catch {
        Write-Status "Cert removal error: $_" "WARN"
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
    Start-Sleep -Seconds 8
    Write-Status "Enabled $InstanceId" "OK"
}

function Remove-DataDirectory {
    Write-Section "Cleaning up C:\ProgramData\MagicMousePatch\..."
    if (Test-Path $DataDir) {
        Remove-Item -Path $DataDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status "Removed $DataDir" "OK"
    } else {
        Write-Status "$DataDir not present" "OK"
    }
}

# ============================================================================
# Main
# ============================================================================

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Magic Mouse v3 Scroll Fix Uninstaller"   -ForegroundColor Cyan
    Write-Host " v1.0.0 - PATH-A Binary Patch"            -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This will remove the patch and restore your system." -ForegroundColor Yellow
    $confirm = Read-Host "Continue with uninstallation? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Uninstallation cancelled." -ForegroundColor Yellow
        exit 0
    }

    Stop-MagicMouseService
    $iid = Disable-MagicMouseDevice
    Restore-DriverBackup
    Remove-LowerFiltersEntry
    Remove-MagicMouseService
    Remove-MagicMouseCert
    Enable-MagicMouseDevice -InstanceId $iid
    Remove-DataDirectory

    Write-Host ""
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
    Write-Host "If you no longer need Test Signing mode, disable it (Admin):" -ForegroundColor Cyan
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
