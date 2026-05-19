#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the Magic Mouse v3 scroll fix (PATH-A binary patch) on Windows.

.DESCRIPTION
Installs a lower-filter kernel driver (applewirelessmouse.sys) that restores scroll
functionality on Apple Magic Mouse v3 (PID 0x0323) when paired over Bluetooth.

Logic is extracted from the production-tested install route
(PATHA-V5-DIRECTCOPY-INSTALL) and adapted for a pre-signed public binary.

Workflow:
  1. Elevation + Windows build (>= 14393) check
  2. HiberbootEnabled (Fast Startup) must be 0
  3. Test Signing mode must be ON (self-signed kernel driver)
  4. HVCI / Memory Integrity warning (Win11 22H2+ blocks self-signed drivers)
  5. SHA256 + size verify of shipped applewirelessmouse.sys
  6. Import MagicMouseFix.cer to LocalMachine\TrustedPublisher (NOT Root)
  7. Backup existing driver to C:\ProgramData\MagicMousePatch\backup\
  8. Detect v3 device via BTHENUM PID&0323
  9. Clear BTHPORT cache (CachedServices, DynamicCachedServices) for the MAC
 10. Stop service -> disable device -> copy -> register service -> write
     LowerFilters at the device-instance level (REG_MULTI_SZ) -> enable device
 11. Post-install verify: SHA256 + size + Authenticode + signer thumbprint
 12. Reboot instruction

.EXAMPLE
.\Install-MagicMousePatch.ps1

.NOTES
Author:  Revive Business Solutions
License: MIT
Contact: riley@revivebusiness.ca
#>

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.0 or later required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 1
}

$ScriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DriverSrc    = Join-Path $ScriptRoot "applewirelessmouse.sys"
$CertPath     = Join-Path $ScriptRoot "MagicMouseFix.cer"
$BackupDir    = "C:\ProgramData\MagicMousePatch\backup"
$TargetDriver = "C:\Windows\System32\drivers\applewirelessmouse.sys"
$ServiceName  = "applewirelessmouse"

# Expected facts (empirically established)
$ExpectedSha256       = "370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03"
$ExpectedSize         = 66288
$CertThumbprint       = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"
$MagicMouseDeviceRe   = 'BTHENUM.*00001124.*PID&0323'

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

# ============================================================================
# Pre-flight checks
# ============================================================================

function Test-WindowsVersion {
    Write-Section "Checking Windows version..."
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    Write-Host "  Build: $build ($($os.Caption))" -ForegroundColor Gray
    if ($build -lt 14393) {
        Write-Status "Windows build 14393 (1607) or later required. Current: $build" "ERROR"
        return $false
    }
    Write-Status "Windows version OK" "OK"
    return $true
}

function Test-FastStartup {
    Write-Section "Checking Fast Startup (HiberbootEnabled)..."
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $hib = (Get-ItemProperty -Path $key -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($null -ne $hib -and $hib -eq 0) {
        Write-Status "Fast Startup is OFF (HiberbootEnabled=0)" "OK"
        return $true
    }
    Write-Status "Fast Startup is ON (HiberbootEnabled=$hib) - install will silently fail" "ERROR"
    Write-Host ""
    Write-Host "  REMEDIATE:" -ForegroundColor Yellow
    Write-Host "    1. Run (Admin):  powercfg /h off" -ForegroundColor Gray
    Write-Host "    2. Reboot" -ForegroundColor Gray
    Write-Host "    3. Re-run this installer" -ForegroundColor Gray
    return $false
}

function Test-TestSigning {
    Write-Section "Checking Test Signing mode..."
    $out = & bcdedit /enum '{current}' 2>&1 | Out-String
    if ($out -match '(?im)^\s*testsigning\s+Yes\s*$') {
        Write-Status "Test Signing is ON" "OK"
        return $true
    }
    Write-Status "Test Signing is OFF - self-signed kernel driver will not load" "ERROR"
    Write-Host ""
    Write-Host "  REMEDIATE:" -ForegroundColor Yellow
    Write-Host "    1. Run (Admin):  bcdedit /set testsigning on" -ForegroundColor Gray
    Write-Host "    2. Reboot" -ForegroundColor Gray
    Write-Host "    3. Re-run this installer" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Note: A 'Test Mode' watermark will appear on the desktop. This is expected." -ForegroundColor Gray
    return $false
}

function Test-HvciState {
    Write-Section "Checking HVCI / Memory Integrity..."
    $hvciKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $enabled = $null
    if (Test-Path $hvciKey) {
        $enabled = (Get-ItemProperty -Path $hvciKey -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
    }
    if ($enabled -eq 1) {
        Write-Status "HVCI / Memory Integrity is ENABLED" "WARN"
        Write-Host ""
        Write-Host "  Windows 11 22H2+ blocks self-signed kernel drivers when HVCI is on." -ForegroundColor Yellow
        Write-Host "  If the driver fails to load after reboot, disable Memory Integrity:" -ForegroundColor Yellow
        Write-Host "    Settings -> Privacy & Security -> Windows Security ->" -ForegroundColor Gray
        Write-Host "    Device Security -> Core isolation -> Memory Integrity: OFF" -ForegroundColor Gray
        Write-Host "    Then reboot." -ForegroundColor Gray
        return $true # warn-only, not fatal
    }
    Write-Status "HVCI / Memory Integrity not enabled" "OK"
    return $true
}

# ============================================================================
# Binary + cert verify
# ============================================================================

function Test-DriverBinary {
    Write-Section "Verifying shipped driver binary..."
    if (-not (Test-Path $DriverSrc)) {
        Write-Status "Driver binary not found: $DriverSrc" "ERROR"
        return $false
    }
    $size = (Get-Item $DriverSrc).Length
    Write-Host "  Path:  $DriverSrc" -ForegroundColor Gray
    Write-Host "  Size:  $size bytes" -ForegroundColor Gray
    if ($size -ne $ExpectedSize) {
        Write-Status "Size mismatch. Expected $ExpectedSize, got $size" "ERROR"
        return $false
    }
    $sha = (Get-FileHash $DriverSrc -Algorithm SHA256).Hash.ToUpper()
    Write-Host "  SHA256: $sha" -ForegroundColor Gray
    if ($sha -ne $ExpectedSha256.ToUpper()) {
        Write-Status "SHA256 mismatch. Expected $ExpectedSha256" "ERROR"
        return $false
    }
    $sig = Get-AuthenticodeSignature $DriverSrc
    if ($sig.SignerCertificate -and ($sig.SignerCertificate.Thumbprint -eq $CertThumbprint)) {
        Write-Status "Driver pre-signed by MagicMouseFix (thumbprint OK)" "OK"
    } else {
        Write-Status "Driver is not signed by expected cert" "ERROR"
        return $false
    }
    Write-Status "Driver binary verified" "OK"
    return $true
}

function Import-MagicMouseCert {
    Write-Section "Importing code-signing certificate..."
    if (-not (Test-Path $CertPath)) {
        Write-Status "Certificate file not found: $CertPath" "ERROR"
        return $false
    }
    try {
        $cert  = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
        if ($cert.Thumbprint -ne $CertThumbprint) {
            Write-Status "Cert thumbprint mismatch. Got $($cert.Thumbprint), expected $CertThumbprint" "ERROR"
            return $false
        }
        # TrustedPublisher ONLY -- Root import is a security hole (would let any cert
        # signed by MagicMouseFix bypass user-mode trust prompts system-wide).
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($cert)
        $store.Close()
        Write-Status "Imported to LocalMachine\TrustedPublisher" "OK"

        $found = Get-ChildItem "Cert:\LocalMachine\TrustedPublisher" |
                 Where-Object { $_.Thumbprint -eq $CertThumbprint }
        if (-not $found) {
            Write-Status "Post-import verification failed (thumbprint not present)" "ERROR"
            return $false
        }
        Write-Status "Cert verified in TrustedPublisher ($CertThumbprint)" "OK"
        return $true
    } catch {
        Write-Status "Cert import failed: $_" "ERROR"
        return $false
    }
}

# ============================================================================
# Device + driver install
# ============================================================================

function Backup-ExistingDriver {
    Write-Section "Backing up existing driver (if any)..."
    if (-not (Test-Path $TargetDriver)) {
        Write-Status "No existing driver at $TargetDriver (fresh install)" "OK"
        return $true
    }
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $dst   = Join-Path $BackupDir "applewirelessmouse_$stamp.sys"
    Copy-Item -Path $TargetDriver -Destination $dst -Force
    Write-Status "Backed up to $dst" "OK"
    return $true
}

function Get-MagicMouseV3 {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match $MagicMouseDeviceRe } |
        Select-Object -First 1
}

function Clear-BthportCache {
    param([string]$InstanceId)
    Write-Section "Clearing BTHPORT cache..."
    $mac = ''
    if ($InstanceId -match '&0&([0-9A-Fa-f]{12})_C\d+$') {
        $mac = $Matches[1].ToUpper()
    } elseif ($InstanceId -match '([0-9A-Fa-f]{12})_C\d+$') {
        $mac = $Matches[1].ToUpper()
    }
    if (-not $mac) {
        Write-Status "Could not extract MAC from InstanceId; skipping cache clear" "WARN"
        return
    }
    Write-Host "  MAC: $mac" -ForegroundColor Gray
    $base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
    foreach ($sub in 'CachedServices','DynamicCachedServices','Cache') {
        $p = "$base\$sub"
        if (Test-Path $p) {
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Cleared $sub" "OK"
        }
    }
}

function Register-MagicMouseService {
    Write-Section "Registering applewirelessmouse service..."
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    # Type=1   SERVICE_KERNEL_DRIVER
    # Start=1  SERVICE_SYSTEM_START  (required for lower-filter drivers)
    # ErrorControl=1  SERVICE_ERROR_NORMAL
    Set-ItemProperty -Path $regPath -Name "Type"         -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "Start"        -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "ErrorControl" -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "ImagePath"    -Value "\SystemRoot\System32\drivers\applewirelessmouse.sys" -Type ExpandString
    Set-ItemProperty -Path $regPath -Name "DisplayName"  -Value "Apple Magic Mouse v3 Scroll Fix" -Type String
    Set-ItemProperty -Path $regPath -Name "Description"  -Value "Lower-filter driver for Apple Magic Mouse v3 scroll fix (PID 0x0323)" -Type String
    Write-Status "Service registered (Type=1 kernel, Start=1 SYSTEM_START)" "OK"
}

# Find the device-instance level key (level 2 under HKLM\...\Enum\BTHENUM):
#   BTHENUM\<GUID_container>\<MAC_instance>
# LowerFilters lives on the level-2 (MAC instance) key itself, NOT inside
# the Device Parameters subkey.
function Get-MagicMouseInstanceRegPath {
    $enumRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM"
    if (-not (Test-Path $enumRoot)) { return $null }
    foreach ($lvl1 in Get-ChildItem $enumRoot -ErrorAction SilentlyContinue) {
        # GUID container must include the HID service GUID 00001124
        if ($lvl1.PSChildName -notmatch '00001124') { continue }
        # PID&0323 is what marks the v3 device
        $hasPid = $lvl1.PSChildName -match 'PID&0323'
        foreach ($lvl2 in Get-ChildItem $lvl1.PSPath -ErrorAction SilentlyContinue) {
            $candidate = $lvl2.PSChildName
            if ($hasPid -or $lvl1.Name -match 'PID&0323' -or $candidate -match 'PID&0323') {
                return $lvl2.PSPath
            }
        }
    }
    return $null
}

function Set-LowerFiltersMultiSz {
    Write-Section "Writing LowerFilters (REG_MULTI_SZ) at device-instance level..."
    $instancePath = Get-MagicMouseInstanceRegPath
    if (-not $instancePath) {
        Write-Status "Magic Mouse v3 instance key not found under BTHENUM (device may not be paired yet)" "WARN"
        Write-Host "  Pair the mouse, then re-run the installer to write LowerFilters." -ForegroundColor Yellow
        return $true # non-fatal; service is registered for later activation
    }
    Write-Host "  Instance key: $instancePath" -ForegroundColor Gray

    $existing = @()
    $cur = (Get-ItemProperty -Path $instancePath -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters
    if ($cur) {
        if ($cur -is [array]) { $existing = @($cur) } else { $existing = @([string]$cur) }
    }
    if ($existing -notcontains $ServiceName) {
        $existing = @($ServiceName) + $existing
    }
    # REG_MULTI_SZ -- use New-ItemProperty so PropertyType is honored even if value missing
    if (Get-ItemProperty -Path $instancePath -Name 'LowerFilters' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $instancePath -Name 'LowerFilters' -Force -ErrorAction SilentlyContinue
    }
    New-ItemProperty -Path $instancePath -Name 'LowerFilters' -Value $existing -PropertyType MultiString -Force | Out-Null
    Write-Status "LowerFilters = [$([string]::Join(', ', $existing))]" "OK"
    return $true
}

function Stop-MagicMouseService {
    Write-Section "Stopping applewirelessmouse service (if running)..."
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Status "Service stopped" "OK"
    } else {
        Write-Status "Service not running" "OK"
    }
}

function Invoke-DirectCopyInstall {
    param([string]$InstanceId)

    Write-Section "Installing driver (disable -> copy -> enable)..."

    & pnputil /disable-device "$InstanceId" 2>&1 | Out-Null
    Start-Sleep -Seconds 5

    Copy-Item -Path $DriverSrc -Destination $TargetDriver -Force -ErrorAction Stop
    Write-Status "Copied driver to $TargetDriver" "OK"

    & pnputil /enable-device "$InstanceId" 2>&1 | Out-Null
    Start-Sleep -Seconds 8
    Write-Status "Device re-enabled" "OK"
}

function Test-PostInstall {
    Write-Section "Verifying post-install state..."

    $postHash = (Get-FileHash $TargetDriver -Algorithm SHA256).Hash.ToLower()
    $srcHash  = (Get-FileHash $DriverSrc    -Algorithm SHA256).Hash.ToLower()
    $postSize = (Get-Item $TargetDriver).Length
    $sig      = Get-AuthenticodeSignature $TargetDriver

    $hashOk   = ($postHash -eq $srcHash)
    $sizeOk   = ($postSize -eq $ExpectedSize)
    $sigOk    = ($sig.Status -eq 'Valid')
    $signerOk = ($sig.SignerCertificate -and $sig.SignerCertificate.Thumbprint -eq $CertThumbprint)

    Write-Host ("  SHA256   : {0} ({1})" -f $postHash, (@{$true='OK';$false='FAIL'}[$hashOk]))   -ForegroundColor Gray
    Write-Host ("  Size     : {0} ({1})" -f $postSize, (@{$true='OK';$false='FAIL'}[$sizeOk]))   -ForegroundColor Gray
    Write-Host ("  Auth Sig : {0} ({1})" -f $sig.Status, (@{$true='OK';$false='FAIL'}[$sigOk]))  -ForegroundColor Gray
    Write-Host ("  Signer   : {0}" -f ($sig.SignerCertificate.Thumbprint))                       -ForegroundColor Gray

    if ($hashOk -and $sizeOk -and $sigOk -and $signerOk) {
        Write-Status "Post-install verification PASSED" "OK"
        return $true
    }
    Write-Status "Post-install verification FAILED" "ERROR"
    return $false
}

# ============================================================================
# Main
# ============================================================================

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Magic Mouse v3 Scroll Fix Installer"    -ForegroundColor Cyan
    Write-Host " v1.0.0 - PATH-A Binary Patch"           -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Test-WindowsVersion))  { exit 1 }
    if (-not (Test-FastStartup))     { exit 1 }
    if (-not (Test-TestSigning))     { exit 1 }
    Test-HvciState | Out-Null

    if (-not (Test-DriverBinary))    { exit 1 }
    if (-not (Import-MagicMouseCert)){ exit 1 }
    if (-not (Backup-ExistingDriver)){ exit 1 }

    Write-Section "Detecting Magic Mouse v3..."
    $v3 = Get-MagicMouseV3
    if (-not $v3) {
        Write-Status "Magic Mouse v3 (PID&0323) not currently paired" "WARN"
        Write-Host "  Pair the mouse over Bluetooth, then re-run this installer to" -ForegroundColor Yellow
        Write-Host "  complete LowerFilters binding. Driver file + service will still" -ForegroundColor Yellow
        Write-Host "  be installed now." -ForegroundColor Yellow
        # Still copy + register so a later pair just works once LowerFilters is written
        Copy-Item -Path $DriverSrc -Destination $TargetDriver -Force -ErrorAction Stop
        Register-MagicMouseService
        Test-PostInstall | Out-Null
        Write-Host ""
        Write-Host "Partial install complete. Re-run after pairing the mouse." -ForegroundColor Yellow
        exit 0
    }
    Write-Status "Found: $($v3.FriendlyName) [$($v3.InstanceId)]" "OK"

    Clear-BthportCache -InstanceId $v3.InstanceId
    Stop-MagicMouseService
    Invoke-DirectCopyInstall -InstanceId $v3.InstanceId
    Register-MagicMouseService
    Set-LowerFiltersMultiSz | Out-Null

    if (-not (Test-PostInstall)) {
        Write-Host ""
        Write-Status "Installation completed with verification errors" "ERROR"
        Write-Host "  Run Uninstall-MagicMousePatch.ps1 to revert." -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Installation Complete"                   -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEP: Reboot your computer." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  shutdown /r /t 60 /c 'Magic Mouse Patch - rebooting'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "After reboot, verify with:" -ForegroundColor Cyan
    Write-Host "  sc query applewirelessmouse" -ForegroundColor Gray
    Write-Host "  Get-AuthenticodeSignature $TargetDriver" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Support: riley@revivebusiness.ca" -ForegroundColor Gray
    Write-Host ""
}

try {
    Main
} catch {
    Write-Host ""
    Write-Status "Installation failed: $_" "ERROR"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
