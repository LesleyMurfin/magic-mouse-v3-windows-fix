#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the Magic Mouse v3 scroll fix patch on Windows.

.DESCRIPTION
Installs the PATH-A binary patch to restore scroll functionality on Apple Magic Mouse v3 (PID 0x0323).
This script:
- Verifies Windows version (build 14393+)
- Detects Magic Mouse hardware
- Validates driver binary via SHA256
- Imports code-signing certificate
- Backs up existing driver
- Registers service and registry entries
- Prompts for reboot

.PARAMETER SkipMouse
If $true, skip the Magic Mouse detection check (for testing).

.EXAMPLE
.\Install-MagicMousePatch.ps1

.EXAMPLE
.\Install-MagicMousePatch.ps1 -SkipMouse

.NOTES
Author: Revive Business Solutions
License: MIT
Contact: riley@revivebusiness.ca
#>

param(
    [switch]$SkipMouse
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$PSVersion = $PSVersionTable.PSVersion.Major
if ($PSVersion -lt 5) {
    Write-Host "PowerShell 5.0 or later required. Current version: $PSVersion" -ForegroundColor Red
    exit 1
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DriverPath = Join-Path $ScriptRoot "applewirelessmouse.sys"
$CertPath = Join-Path $ScriptRoot "..\MagicMouseFix.cer"
$BackupDir = "C:\ProgramData\MagicMousePatch\backup"
$TargetDriver = "C:\Windows\System32\drivers\applewirelessmouse.sys"

# Expected hash of the patched driver
$ExpectedHash = "370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03"
$CertThumbprint = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"
$MagicMouseVID = "0001004C"  # Apple vendor ID
$MagicMousePID = "0323"       # Magic Mouse v3 product ID

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

function Get-WindowsBuild {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    return $os.BuildNumber
}

function Test-WindowsVersion {
    $build = Get-WindowsBuild
    Write-Host "Windows Build: $build" -ForegroundColor Cyan

    if ($build -lt 14393) {
        Write-Status "Windows build 14393 or later required. Current: $build" "ERROR"
        return $false
    }

    Write-Status "Windows version compatible (build $build >= 14393)" "OK"
    return $true
}

function Find-MagicMouse {
    Write-Host ""
    Write-Host "Searching for Magic Mouse v3 (PID&0323)..." -ForegroundColor Cyan

    try {
        # Query all HID devices and look for Magic Mouse v3
        $devices = Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -match "VID&$MagicMouseVID" -and $_.InstanceId -match "PID&$MagicMousePID"
        }

        if ($devices) {
            foreach ($device in $devices) {
                Write-Status "Found: $($device.Name) [$($device.InstanceId)]" "OK"
            }
            return $true
        } else {
            Write-Status "Magic Mouse v3 (PID&0323) not detected" "WARN"
            Write-Host "  This may be OK if the device hasn't been paired yet."
            Write-Host "  The driver will work when the device is connected." -ForegroundColor Yellow
            return $true  # Not a fatal error
        }
    } catch {
        Write-Status "Error searching for Magic Mouse: $_" "WARN"
        return $true  # Continue anyway
    }
}

function Test-FileHash {
    param([string]$FilePath, [string]$Expected)

    Write-Host ""
    Write-Host "Verifying driver binary..." -ForegroundColor Cyan

    if (-not (Test-Path $FilePath)) {
        Write-Status "Driver binary not found: $FilePath" "ERROR"
        return $false
    }

    $hash = (Get-FileHash $FilePath -Algorithm SHA256).Hash
    Write-Host "  SHA256: $hash"

    if ($hash -eq $Expected) {
        Write-Status "Hash verification PASSED" "OK"
        return $true
    } else {
        Write-Status "Hash verification FAILED" "ERROR"
        Write-Host "  Expected: $Expected"
        Write-Host "  Got:      $hash"
        return $false
    }
}

function Import-MagicMouseCert {
    Write-Host ""
    Write-Host "Importing code-signing certificate..." -ForegroundColor Cyan

    if (-not (Test-Path $CertPath)) {
        Write-Status "Certificate file not found: $CertPath" "ERROR"
        return $false
    }

    try {
        # Import to TrustedPublisher store
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($cert)
        $store.Close()

        Write-Status "Imported to LocalMachine\TrustedPublisher" "OK"

        # Also import to Root store for full trust
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($cert)
        $store.Close()

        Write-Status "Imported to LocalMachine\Root" "OK"

        # Verify
        $cert = Get-ChildItem "Cert:\LocalMachine\TrustedPublisher" | Where-Object { $_.Thumbprint -eq $CertThumbprint }
        if ($cert) {
            Write-Status "Certificate verified (thumbprint: $($cert.Thumbprint))" "OK"
            return $true
        } else {
            Write-Status "Certificate import verification failed" "ERROR"
            return $false
        }
    } catch {
        Write-Status "Certificate import failed: $_" "ERROR"
        return $false
    }
}

function Backup-ExistingDriver {
    Write-Host ""
    Write-Host "Backing up existing driver..." -ForegroundColor Cyan

    if (-not (Test-Path $TargetDriver)) {
        Write-Status "No existing driver found (OK for fresh install)" "OK"
        return $true
    }

    try {
        if (-not (Test-Path $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
            Write-Status "Created backup directory: $BackupDir" "OK"
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPath = Join-Path $BackupDir "applewirelessmouse_$timestamp.sys"
        Copy-Item $TargetDriver $backupPath -Force

        Write-Status "Backed up to: $backupPath" "OK"
        return $true
    } catch {
        Write-Status "Backup failed: $_" "ERROR"
        return $false
    }
}

function Install-Driver {
    Write-Host ""
    Write-Host "Installing driver to System32\drivers..." -ForegroundColor Cyan

    try {
        # Copy driver file
        Copy-Item $DriverPath $TargetDriver -Force
        Write-Status "Copied driver to $TargetDriver" "OK"

        # If copy fails due to file lock, use PendingFileRenameOperations
        if (-not (Test-Path $TargetDriver)) {
            Write-Host "Driver in use, scheduling replacement..." -ForegroundColor Yellow

            # Create temp path
            $tempPath = Join-Path "C:\Windows\System32\drivers" "applewirelessmouse_temp.sys"
            Copy-Item $DriverPath $tempPath -Force

            # Add to pending operations
            $reg = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("System\CurrentControlSet\Control\Session Manager", $true)
            $value = $reg.GetValue("PendingFileRenameOperations", @())

            if ($value -is [string]) {
                $value = @($value)
            }

            $value += "\SystemRoot\System32\drivers\applewirelessmouse_temp.sys"
            $value += "\SystemRoot\System32\drivers\applewirelessmouse.sys"

            $reg.SetValue("PendingFileRenameOperations", $value, [Microsoft.Win32.RegistryValueKind]::MultiString)
            $reg.Close()

            Write-Status "Scheduled replacement for next boot" "OK"
        }

        return $true
    } catch {
        Write-Status "Driver installation failed: $_" "ERROR"
        return $false
    }
}

function Register-Service {
    Write-Host ""
    Write-Host "Registering applewirelessmouse service..." -ForegroundColor Cyan

    try {
        # Check if service already exists
        $service = Get-Service -Name "applewirelessmouse" -ErrorAction SilentlyContinue

        if ($service) {
            Write-Status "Service already exists, updating..." "WARN"
            Stop-Service -Name "applewirelessmouse" -Force -ErrorAction SilentlyContinue
            sc.exe delete applewirelessmouse | Out-Null
            Start-Sleep -Milliseconds 500
        }

        # Create service via registry (more reliable than sc.exe)
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\applewirelessmouse"

        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }

        # Set service properties
        Set-ItemProperty -Path $regPath -Name "Type" -Value 1 -Type DWord  # KERNEL_DRIVER
        Set-ItemProperty -Path $regPath -Name "Start" -Value 3 -Type DWord  # SERVICE_DEMAND_START
        Set-ItemProperty -Path $regPath -Name "ImagePath" -Value "\SystemRoot\System32\drivers\applewirelessmouse.sys" -Type String
        Set-ItemProperty -Path $regPath -Name "DisplayName" -Value "Apple Magic Mouse Fix" -Type String
        Set-ItemProperty -Path $regPath -Name "Description" -Value "Lower filter driver for Apple Magic Mouse v3 scroll fix" -Type String

        Write-Status "Service registered" "OK"

        # Verify
        $service = Get-Service -Name "applewirelessmouse" -ErrorAction SilentlyContinue
        if ($service) {
            Write-Status "Service verified: $($service.Name)" "OK"
            return $true
        } else {
            Write-Status "Service verification failed" "WARN"
            return $true  # Continue anyway
        }
    } catch {
        Write-Status "Service registration failed: $_" "ERROR"
        return $false
    }
}

function Set-LowerFilters {
    Write-Host ""
    Write-Host "Setting LowerFilters registry entry..." -ForegroundColor Cyan

    try {
        # Find BTHENUM device instance for Magic Mouse
        $regBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"

        # Search for Magic Mouse v3 device
        if (Test-Path $regBase) {
            $found = $false
            Get-ChildItem $regBase | ForEach-Object {
                if ($_.Name -match "VID&$MagicMouseVID" -and $_.Name -match "PID&$MagicMousePID") {
                    $devicePath = $_.PSPath

                    # Find Device Parameters subkey
                    $paramsPath = Join-Path $devicePath "Device Parameters"
                    if (-not (Test-Path $paramsPath)) {
                        New-Item -Path $paramsPath -Force | Out-Null
                    }

                    # Set LowerFilters
                    Set-ItemProperty -Path $paramsPath -Name "LowerFilters" -Value "applewirelessmouse" -Type String
                    Write-Status "Set LowerFilters in $($_.PSChildName)" "OK"
                    $found = $true
                }
            }

            if (-not $found) {
                Write-Status "Magic Mouse device instance not found in registry (OK if device not yet paired)" "WARN"
                return $true
            }
        } else {
            Write-Status "BTHENUM registry key not found (device not paired yet - OK)" "WARN"
            return $true
        }

        return $true
    } catch {
        Write-Status "LowerFilters registry entry failed: $_" "WARN"
        return $true  # Not fatal
    }
}

function Invoke-PnpRestart {
    Write-Host ""
    Write-Host "Restarting PnP device stack..." -ForegroundColor Cyan

    try {
        # Find Magic Mouse device and restart it
        $devices = Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -match "VID&$MagicMouseVID" -and $_.InstanceId -match "PID&$MagicMousePID"
        }

        if ($devices) {
            foreach ($device in $devices) {
                Write-Host "  Restarting: $($device.Name)" -ForegroundColor Cyan
                $device | Restart-PnpDevice -Confirm:$false -WarningAction SilentlyContinue
                Start-Sleep -Seconds 2
                Write-Status "Restarted $($device.InstanceId)" "OK"
            }
        } else {
            Write-Status "Device not currently connected (will be initialized on next connection)" "OK"
        }

        return $true
    } catch {
        Write-Status "PnP restart error: $_" "WARN"
        return $true  # Not fatal
    }
}

# ============================================================================
# Main Installation Flow
# ============================================================================

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Magic Mouse v3 Scroll Fix Installer" -ForegroundColor Cyan
    Write-Host "v1.0.0 - PATH-A Binary Patch" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Verify Windows version
    if (-not (Test-WindowsVersion)) {
        Write-Host ""
        Write-Status "Installation aborted: Windows version too old" "ERROR"
        exit 1
    }

    # Step 2: Detect Magic Mouse (optional)
    if (-not $SkipMouse) {
        Find-MagicMouse | Out-Null
    }

    # Step 3: Verify driver binary
    if (-not (Test-FileHash $DriverPath $ExpectedHash)) {
        Write-Host ""
        Write-Status "Installation aborted: driver verification failed" "ERROR"
        exit 1
    }

    # Step 4: Import certificate
    if (-not (Import-MagicMouseCert)) {
        Write-Host ""
        Write-Status "Installation aborted: certificate import failed" "ERROR"
        exit 1
    }

    # Step 5: Backup existing driver
    if (-not (Backup-ExistingDriver)) {
        Write-Host ""
        Write-Status "Installation aborted: backup failed" "ERROR"
        exit 1
    }

    # Step 6: Install driver
    if (-not (Install-Driver)) {
        Write-Host ""
        Write-Status "Installation aborted: driver installation failed" "ERROR"
        exit 1
    }

    # Step 7: Register service
    if (-not (Register-Service)) {
        Write-Host ""
        Write-Status "Installation aborted: service registration failed" "ERROR"
        exit 1
    }

    # Step 8: Set registry entries
    if (-not (Set-LowerFilters)) {
        Write-Status "Registry entry warning (non-fatal)" "WARN"
    }

    # Step 9: Restart device (if connected)
    Invoke-PnpRestart

    # Installation complete
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Installation Complete" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEP: Reboot your computer" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Command:" -ForegroundColor Cyan
    Write-Host "    shutdown /r /t 60 /c 'Magic Mouse Patch installing - rebooting in 60 sec'"
    Write-Host ""
    Write-Host "  Or manually: Settings > System > Power > Restart" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "After reboot, verify installation with:" -ForegroundColor Cyan
    Write-Host "  sc query applewirelessmouse" -ForegroundColor Gray
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
    Write-Status "Installation failed: $_" "ERROR"
    Write-Host "Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
