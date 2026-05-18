#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls the Magic Mouse v3 scroll fix patch.

.DESCRIPTION
Removes the PATH-A binary patch and restores the system to its pre-installation state.
This script:
- Stops the applewirelessmouse service
- Removes the service and registry entries
- Restores the original driver from backup
- Removes the MagicMouseFix certificate
- Cleans up C:\ProgramData\MagicMousePatch\
- Prompts for reboot

.EXAMPLE
.\Uninstall-MagicMousePatch.ps1

.NOTES
Author: Revive Business Solutions
License: MIT
Contact: riley@revivebusiness.ca
#>

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = "Continue"  # Don't fail completely on non-critical errors
$ProgressPreference = "SilentlyContinue"

$TargetDriver = "C:\Windows\System32\drivers\applewirelessmouse.sys"
$BackupDir = "C:\ProgramData\MagicMousePatch\backup"
$CertThumbprint = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"
$MagicMouseVID = "0001004C"
$MagicMousePID = "0323"

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Status {
    param([string]$Message, [string]$Status = "OK")
    $StatusColor = switch ($Status) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        default { "Gray" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $StatusColor
}

function Stop-MagicMouseService {
    Write-Host ""
    Write-Host "Stopping applewirelessmouse service..." -ForegroundColor Cyan

    try {
        $service = Get-Service -Name "applewirelessmouse" -ErrorAction SilentlyContinue

        if ($service) {
            if ($service.Status -eq "Running") {
                Stop-Service -Name "applewirelessmouse" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                Write-Status "Service stopped" "OK"
            } else {
                Write-Status "Service not running" "OK"
            }
            return $true
        } else {
            Write-Status "Service not found (may already be uninstalled)" "OK"
            return $true
        }
    } catch {
        Write-Status "Error stopping service: $_" "WARN"
        return $true  # Continue anyway
    }
}

function Remove-LowerFilters {
    Write-Host ""
    Write-Host "Removing LowerFilters registry entries..." -ForegroundColor Cyan

    try {
        $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"

        if (Test-Path $regBase) {
            $found = $false
            Get-ChildItem $regBase | ForEach-Object {
                if ($_.Name -match "VID&$MagicMouseVID" -and $_.Name -match "PID&$MagicMousePID") {
                    $paramsPath = Join-Path $_.PSPath "Device Parameters"

                    if (Test-Path $paramsPath) {
                        $prop = Get-ItemProperty -Path $paramsPath -Name "LowerFilters" -ErrorAction SilentlyContinue
                        if ($prop) {
                            Remove-ItemProperty -Path $paramsPath -Name "LowerFilters" -Force -ErrorAction SilentlyContinue
                            Write-Status "Removed LowerFilters from $($_.PSChildName)" "OK"
                            $found = $true
                        }
                    }
                }
            }

            if (-not $found) {
                Write-Status "No LowerFilters entries found" "OK"
            }
        } else {
            Write-Status "BTHENUM registry not found" "OK"
        }

        return $true
    } catch {
        Write-Status "Error removing LowerFilters: $_" "WARN"
        return $true  # Non-fatal
    }
}

function Restore-OriginalDriver {
    Write-Host ""
    Write-Host "Restoring original driver..." -ForegroundColor Cyan

    try {
        # If no backup exists, just remove the patched driver
        if (-not (Test-Path $BackupDir)) {
            Write-Status "No backup directory found" "OK"

            if (Test-Path $TargetDriver) {
                Remove-Item $TargetDriver -Force -ErrorAction SilentlyContinue
                Write-Status "Removed patched driver" "OK"
            }

            return $true
        }

        # Find most recent backup
        $backups = Get-ChildItem $BackupDir -Filter "applewirelessmouse_*.sys" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

        if ($backups) {
            $latestBackup = $backups[0].FullName
            Write-Host "  Found backup: $($backups[0].Name)" -ForegroundColor Gray

            # Restore backup
            Copy-Item $latestBackup $TargetDriver -Force
            Write-Status "Restored driver from backup" "OK"
            return $true
        } else {
            Write-Status "No backup files found, removing patched driver" "WARN"

            if (Test-Path $TargetDriver) {
                Remove-Item $TargetDriver -Force -ErrorAction SilentlyContinue
                Write-Status "Removed patched driver" "OK"
            }

            return $true
        }
    } catch {
        Write-Status "Error restoring driver: $_" "WARN"
        return $true  # Non-fatal
    }
}

function Remove-Service {
    Write-Host ""
    Write-Host "Removing applewirelessmouse service..." -ForegroundColor Cyan

    try {
        # Remove via registry (more reliable)
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\applewirelessmouse"

        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Service registry removed" "OK"
        } else {
            Write-Status "Service registry not found" "OK"
        }

        # Also try sc.exe removal
        sc.exe delete applewirelessmouse 2>$null
        Start-Sleep -Milliseconds 500

        # Verify
        $service = Get-Service -Name "applewirelessmouse" -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Status "Service verified as removed" "OK"
        }

        return $true
    } catch {
        Write-Status "Error removing service: $_" "WARN"
        return $true  # Non-fatal
    }
}

function Remove-Certificates {
    Write-Host ""
    Write-Host "Removing MagicMouseFix certificates..." -ForegroundColor Cyan

    try {
        $removed = $false

        # Remove from TrustedPublisher
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

        $certs = $store.Certificates | Where-Object { $_.Thumbprint -eq $CertThumbprint }
        foreach ($cert in $certs) {
            $store.Remove($cert)
            Write-Status "Removed from TrustedPublisher" "OK"
            $removed = $true
        }

        $store.Close()

        # Remove from Root
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

        $certs = $store.Certificates | Where-Object { $_.Thumbprint -eq $CertThumbprint }
        foreach ($cert in $certs) {
            $store.Remove($cert)
            Write-Status "Removed from Root" "OK"
            $removed = $true
        }

        $store.Close()

        if (-not $removed) {
            Write-Status "No certificates found (may already be removed)" "OK"
        }

        return $true
    } catch {
        Write-Status "Error removing certificates: $_" "WARN"
        return $true  # Non-fatal
    }
}

function Remove-BackupDirectory {
    Write-Host ""
    Write-Host "Cleaning up backup directory..." -ForegroundColor Cyan

    try {
        if (Test-Path $BackupDir) {
            Remove-Item $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Removed $BackupDir" "OK"
        } else {
            Write-Status "Backup directory not found" "OK"
        }

        # Also remove parent dir if empty
        $parentDir = "C:\ProgramData\MagicMousePatch"
        if (Test-Path $parentDir) {
            $items = Get-ChildItem $parentDir -ErrorAction SilentlyContinue
            if (-not $items) {
                Remove-Item $parentDir -Force -ErrorAction SilentlyContinue
                Write-Status "Removed empty parent directory" "OK"
            }
        }

        return $true
    } catch {
        Write-Status "Error cleaning up backup: $_" "WARN"
        return $true  # Non-fatal
    }
}

# ============================================================================
# Main Uninstall Flow
# ============================================================================

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Magic Mouse v3 Scroll Fix Uninstaller" -ForegroundColor Cyan
    Write-Host "v1.0.0 - PATH-A Binary Patch" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Confirm before proceeding
    Write-Host "This will remove the Magic Mouse patch and restore your system." -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "Continue with uninstallation? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Uninstallation cancelled." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""

    # Step 1: Stop service
    Stop-MagicMouseService

    # Step 2: Remove LowerFilters
    Remove-LowerFilters

    # Step 3: Restore original driver
    Restore-OriginalDriver

    # Step 4: Remove service
    Remove-Service

    # Step 5: Remove certificates
    Remove-Certificates

    # Step 6: Clean up backup
    Remove-BackupDirectory

    # Uninstallation complete
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Uninstallation Complete" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEP: Reboot your computer" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Command:" -ForegroundColor Cyan
    Write-Host "    shutdown /r /t 60 /c 'Magic Mouse Patch uninstalled - rebooting in 60 sec'"
    Write-Host ""
    Write-Host "  Or manually: Settings > System > Power > Restart" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "After reboot, your system will be restored to its pre-patch state." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Support: riley@revivebusiness.ca" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================================
# Execute
# ============================================================================

try {
    Main
} catch {
    Write-Host ""
    Write-Status "Uninstallation error: $_" "ERROR"
    Write-Host "Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
    Write-Host ""
    Write-Host "For support, contact: riley@revivebusiness.ca" -ForegroundColor Yellow
    exit 1
}
