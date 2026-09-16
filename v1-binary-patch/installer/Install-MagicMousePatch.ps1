#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the Apple multi-touch filter driver (applewirelessmouse.sys) so scroll works
on an Apple Magic Mouse paired over Bluetooth.

.DESCRIPTION
Windows ships no multi-touch filter for the Magic Mouse, so the touch surface produces
no scroll. Apple's own Boot Camp driver does that translation, but Apple's INF has no
entry for the Bluetooth PID this mouse reports (0x0323), so the driver is registered
manually as a LowerFilter on the device instead.

Two binary variants are supported and auto-detected by Authenticode signer:

  AppleSigned      Apple's driver, UNMODIFIED. Apple-signed and Microsoft
                   WHQL-countersigned, so the signature is intact.
                   -> No Test Mode. Secure Boot and memory integrity may stay ON.
                   This is the recommended variant.

  PatchedResigned  Legacy: a byte-patched copy re-signed with this project's own
                   certificate (CN=MagicMouseFix). Patching breaks Apple's
                   countersignature, and a self-signed cert outside Root cannot
                   satisfy kernel code integrity.
                   -> REQUIRES test signing, Secure Boot off, memory integrity off.

Workflow:
  1. Elevation + Windows build (>= 14393) check
  2. HiberbootEnabled (Fast Startup) must be 0
  3. Locate the driver: -DriverPath, then beside this script, then the local DriverStore
  4. Identify the variant from its signature, and verify it
  5. Code-integrity gates applied ONLY for PatchedResigned (test signing, HVCI)
  6. Import MagicMouseFix.cer to LocalMachine\TrustedPublisher (PatchedResigned only,
     and NOT to Root)
  7. Backup existing driver to C:\ProgramData\MagicMousePatch\backup\
  8. Detect the mouse via BTHENUM PID&0323
  9. Clear BTHPORT cache (CachedServices, DynamicCachedServices) for the MAC
 10. Stop service -> disable device -> copy -> register service -> write
     LowerFilters at the device-instance level (REG_MULTI_SZ) -> enable device
 11. Post-install verify: hash matches source, size, Authenticode, expected signer
 12. Reboot instruction

.PARAMETER DriverPath
Explicit path to applewirelessmouse.sys. Use this to install Apple's unmodified driver
from wherever you extracted it.

.PARAMETER FromDriverStore
Search %SystemRoot%\System32\DriverStore\FileRepository for Apple's driver (present if
Apple Software Update / Boot Camp support software was ever installed) and use that.

.EXAMPLE
.\Install-MagicMousePatch.ps1

.EXAMPLE
.\Install-MagicMousePatch.ps1 -FromDriverStore

.EXAMPLE
.\Install-MagicMousePatch.ps1 -DriverPath D:\bootcamp\applewirelessmouse.sys

.NOTES
Author:  Revive Business Solutions
License: MIT
Contact: riley@revivebusiness.ca

applewirelessmouse.sys is Apple's proprietary driver and is subject to Apple's software
licence terms. See DMCA-NOTICE.md.
#>

[CmdletBinding()]
param(
    [string]$DriverPath,
    [switch]$FromDriverStore
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 or later is required." -ForegroundColor Red
    exit 1
}

$ScriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CertPath     = Join-Path $ScriptRoot "MagicMouseFix.cer"
$BackupDir    = "C:\ProgramData\MagicMousePatch\backup"
$TargetDriver = "C:\Windows\System32\drivers\applewirelessmouse.sys"
$ServiceName  = "applewirelessmouse"

# Legacy patched+re-signed variant: exact artifact this installer shipped as v1.0.0.
$PatchedSha256  = "370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03"
$PatchedSize    = 66288
$CertThumbprint = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"

# Apple's unmodified driver is identified by its countersigning chain, not by hash:
# Apple has shipped more than one Boot Camp build, and pinning a hash here would
# reject a legitimately signed newer copy.
$AppleSignerPattern = 'Microsoft Windows Hardware Compatibility Publisher|Apple Inc'

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
    Write-Status "Test Signing is OFF - a self-signed kernel driver will not load" "ERROR"
    Write-Host ""
    Write-Host "  This is only required for the legacy patched+re-signed driver." -ForegroundColor Yellow
    Write-Host "  Apple's UNMODIFIED driver needs none of this - it is Microsoft-" -ForegroundColor Yellow
    Write-Host "  countersigned. Re-run with -FromDriverStore or -DriverPath <path>" -ForegroundColor Yellow
    Write-Host "  pointing at Apple's own applewirelessmouse.sys." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Otherwise, to use the patched variant:" -ForegroundColor Yellow
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
# Driver discovery + variant identification
# ============================================================================

# Apple's driver is present in the DriverStore on any machine where Apple
# Software Update or Boot Camp support software was installed.
function Find-DriverStoreCopy {
    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (-not (Test-Path $repo)) { return $null }
    Get-ChildItem -Path $repo -Filter 'applewirelessmouse.inf_*' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -Path $_.FullName -Filter 'applewirelessmouse.sys' -File -ErrorAction SilentlyContinue
        } |
        Sort-Object -Property Length -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Resolve-DriverSource {
    Write-Section "Locating driver binary..."

    if ($DriverPath) {
        if (-not (Test-Path -LiteralPath $DriverPath)) {
            Write-Status "-DriverPath not found: $DriverPath" "ERROR"
            return $null
        }
        Write-Status "Using -DriverPath: $DriverPath" "OK"
        return (Resolve-Path -LiteralPath $DriverPath).Path
    }

    if ($FromDriverStore) {
        $ds = Find-DriverStoreCopy
        if (-not $ds) {
            Write-Status "No applewirelessmouse.sys in the local DriverStore" "ERROR"
            Write-Host "  Install Apple Software Update for Windows, or extract the driver from" -ForegroundColor Yellow
            Write-Host "  Boot Camp Support Software, then use -DriverPath." -ForegroundColor Yellow
            return $null
        }
        Write-Status "Found in DriverStore: $ds" "OK"
        return $ds
    }

    $local = Join-Path $ScriptRoot 'applewirelessmouse.sys'
    if (Test-Path -LiteralPath $local) {
        Write-Status "Using driver beside this script: $local" "OK"
        return $local
    }

    $ds = Find-DriverStoreCopy
    if ($ds) {
        Write-Status "No local copy; using DriverStore: $ds" "OK"
        return $ds
    }

    Write-Status "applewirelessmouse.sys not found" "ERROR"
    Write-Host "  Options:" -ForegroundColor Yellow
    Write-Host "    - place applewirelessmouse.sys beside this script" -ForegroundColor Gray
    Write-Host "    - or pass -DriverPath <path>" -ForegroundColor Gray
    Write-Host "    - or install Apple Software Update and pass -FromDriverStore" -ForegroundColor Gray
    return $null
}

# Identify which binary we were handed, from its signature. Hash pinning is used
# only for the legacy patched artifact; Apple has shipped multiple Boot Camp
# builds, so a hash pin would reject a legitimately signed newer copy.
function Get-DriverVariant {
    param([string]$Path)

    $sig   = Get-AuthenticodeSignature -LiteralPath $Path
    $thumb = ''
    $subj  = ''
    if ($sig.SignerCertificate) {
        $thumb = $sig.SignerCertificate.Thumbprint.ToUpper()
        $subj  = $sig.SignerCertificate.Subject
    }

    $info = [ordered]@{
        Path      = $Path
        Size      = (Get-Item -LiteralPath $Path).Length
        Sha256    = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpper()
        SigStatus = $sig.Status
        Signer    = $subj
        Thumb     = $thumb
        Variant   = 'Unknown'
    }

    if ($thumb -eq $CertThumbprint) {
        $info.Variant = 'PatchedResigned'
    } elseif ($sig.Status -eq 'Valid' -and $subj -match $AppleSignerPattern) {
        $info.Variant = 'AppleSigned'
    }

    return [pscustomobject]$info
}

# ============================================================================
# Binary + cert verify
# ============================================================================

function Test-DriverBinary {
    param([pscustomobject]$Info)

    Write-Section "Verifying driver binary..."
    Write-Host ("  Path    : {0}" -f $Info.Path)      -ForegroundColor Gray
    Write-Host ("  Size    : {0} bytes" -f $Info.Size) -ForegroundColor Gray
    Write-Host ("  SHA256  : {0}" -f $Info.Sha256)     -ForegroundColor Gray
    Write-Host ("  Auth    : {0}" -f $Info.SigStatus)  -ForegroundColor Gray
    Write-Host ("  Signer  : {0}" -f $Info.Signer)     -ForegroundColor Gray

    switch ($Info.Variant) {
        'AppleSigned' {
            Write-Status "Apple's UNMODIFIED driver - Microsoft-countersigned" "OK"
            Write-Host "  No Test Mode needed. Secure Boot and Memory Integrity may stay ON." -ForegroundColor Green
            return $true
        }
        'PatchedResigned' {
            Write-Status "Legacy patched driver, re-signed as MagicMouseFix" "WARN"
            if ($Info.Size -ne $PatchedSize) {
                Write-Status "Size mismatch. Expected $PatchedSize, got $($Info.Size)" "ERROR"
                return $false
            }
            if ($Info.Sha256 -ne $PatchedSha256.ToUpper()) {
                Write-Status "SHA256 mismatch. Expected $PatchedSha256" "ERROR"
                return $false
            }
            if ($Info.SigStatus -ne 'Valid') {
                Write-Status "Authenticode status is $($Info.SigStatus), expected Valid" "ERROR"
                return $false
            }
            Write-Status "Patched driver verified against pinned hash" "OK"
            Write-Host "  This variant REQUIRES Test Mode. Apple's unmodified driver does not -" -ForegroundColor Yellow
            Write-Host "  see -FromDriverStore / -DriverPath." -ForegroundColor Yellow
            return $true
        }
        default {
            Write-Status "Unrecognised driver binary - refusing to install" "ERROR"
            Write-Host "  Expected either:" -ForegroundColor Yellow
            Write-Host "    - Apple's unmodified driver (Authenticode Valid, Microsoft/Apple signer)" -ForegroundColor Gray
            Write-Host "    - the legacy patched driver signed by MagicMouseFix ($CertThumbprint)" -ForegroundColor Gray
            Write-Host "  A driver whose signature does not verify has been modified or corrupted." -ForegroundColor Yellow
            return $false
        }
    }
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
    param(
        [string]$InstanceId,
        [pscustomobject]$Info
    )

    Write-Section "Installing driver (disable -> copy -> enable)..."

    & pnputil /disable-device "$InstanceId" 2>&1 | Out-Null
    Start-Sleep -Seconds 5

    Copy-Item -LiteralPath $Info.Path -Destination $TargetDriver -Force -ErrorAction Stop
    Write-Status "Copied driver to $TargetDriver" "OK"

    & pnputil /enable-device "$InstanceId" 2>&1 | Out-Null
    Start-Sleep -Seconds 8
    Write-Status "Device re-enabled" "OK"
}

function Test-PostInstall {
    param([pscustomobject]$Info)

    Write-Section "Verifying post-install state..."

    $postHash = (Get-FileHash $TargetDriver -Algorithm SHA256).Hash.ToUpper()
    $postSize = (Get-Item $TargetDriver).Length
    $sig      = Get-AuthenticodeSignature $TargetDriver
    $postThumb = ''
    if ($sig.SignerCertificate) { $postThumb = $sig.SignerCertificate.Thumbprint.ToUpper() }

    # Compare against what we installed, not against a baked-in constant: the
    # source may legitimately be Apple's driver of any Boot Camp vintage.
    $hashOk = ($postHash -eq $Info.Sha256)
    $sizeOk = ($postSize -eq $Info.Size)
    $sigOk  = ($sig.Status -eq 'Valid')

    $signerOk = switch ($Info.Variant) {
        'PatchedResigned' { $postThumb -eq $CertThumbprint }
        'AppleSigned'     { $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match $AppleSignerPattern }
        default           { $false }
    }

    $fmt = @{$true='OK';$false='FAIL'}
    Write-Host ("  Variant  : {0}" -f $Info.Variant)                                     -ForegroundColor Gray
    Write-Host ("  SHA256   : {0} ({1})" -f $postHash, $fmt[$hashOk])                    -ForegroundColor Gray
    Write-Host ("  Size     : {0} ({1})" -f $postSize, $fmt[$sizeOk])                    -ForegroundColor Gray
    Write-Host ("  Auth Sig : {0} ({1})" -f $sig.Status, $fmt[$sigOk])                   -ForegroundColor Gray
    Write-Host ("  Signer   : {0} ({1})" -f $postThumb, $fmt[[bool]$signerOk])           -ForegroundColor Gray

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
    Write-Host " Magic Mouse Scroll Fix Installer"       -ForegroundColor Cyan
    Write-Host " Apple applewirelessmouse.sys filter"    -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Test-WindowsVersion)) { exit 1 }
    if (-not (Test-FastStartup))    { exit 1 }

    $src = Resolve-DriverSource
    if (-not $src) { exit 1 }

    $info = Get-DriverVariant -Path $src
    if (-not (Test-DriverBinary -Info $info)) { exit 1 }

    # Code-integrity gates apply ONLY to the self-signed, patched variant.
    # Apple's unmodified driver is Microsoft-countersigned: forcing Test Mode or
    # demanding Memory Integrity be off would be wrong, and would push users into
    # weakening their machine for no reason.
    if ($info.Variant -eq 'PatchedResigned') {
        if (-not (Test-TestSigning)) { exit 1 }
        Test-HvciState | Out-Null
        if (-not (Import-MagicMouseCert)) { exit 1 }
    } else {
        Write-Section "Code-integrity requirements..."
        Write-Status "Apple-signed driver: no Test Mode, no certificate import needed" "OK"
        Write-Host "  Secure Boot and Memory Integrity can remain enabled." -ForegroundColor Green
    }

    if (-not (Backup-ExistingDriver)) { exit 1 }

    Write-Section "Detecting Magic Mouse (PID&0323)..."
    $v3 = Get-MagicMouseV3
    if (-not $v3) {
        Write-Status "Magic Mouse (PID&0323) not currently paired" "WARN"
        Write-Host "  Pair the mouse over Bluetooth, then re-run this installer to" -ForegroundColor Yellow
        Write-Host "  complete LowerFilters binding. Driver file + service will still" -ForegroundColor Yellow
        Write-Host "  be installed now." -ForegroundColor Yellow
        Copy-Item -LiteralPath $info.Path -Destination $TargetDriver -Force -ErrorAction Stop
        Register-MagicMouseService
        Test-PostInstall -Info $info | Out-Null
        Write-Host ""
        Write-Host "Partial install complete. Re-run after pairing the mouse." -ForegroundColor Yellow
        exit 0
    }
    Write-Status "Found: $($v3.FriendlyName) [$($v3.InstanceId)]" "OK"

    Clear-BthportCache -InstanceId $v3.InstanceId
    Stop-MagicMouseService
    Invoke-DirectCopyInstall -InstanceId $v3.InstanceId -Info $info
    Register-MagicMouseService
    Set-LowerFiltersMultiSz | Out-Null

    if (-not (Test-PostInstall -Info $info)) {
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
    Write-Host ("Installed variant: {0}" -f $info.Variant) -ForegroundColor Cyan
    if ($info.Variant -eq 'AppleSigned') {
        Write-Host "  Microsoft-countersigned - Test Mode is NOT required." -ForegroundColor Green
    } else {
        Write-Host "  Self-signed - Test Mode must stay ON for this driver to load." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "What you get with this driver:" -ForegroundColor Cyan
    Write-Host "  Pointer  : works" -ForegroundColor Gray
    Write-Host "  Scroll   : two-finger scroll via Apple's multi-touch filter" -ForegroundColor Gray
    Write-Host "  Battery  : use Magic Tray (https://magictray.app/) - it detects this" -ForegroundColor Gray
    Write-Host "             driver and flips Mode A/B briefly to read the level" -ForegroundColor Gray
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
