#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the Apple multi-touch filter driver (applewirelessmouse.sys) so scroll works
on an Apple Magic Mouse paired over Bluetooth.

.DESCRIPTION
Windows ships no multi-touch filter for the Magic Mouse, so the touch surface produces
no scroll. Apple's own Boot Camp driver does that translation, but its INF does not
create a Bluetooth binding for the 2024 mouse, so the driver is registered manually as
a LowerFilter on the device instance instead.

There is exactly ONE install route: copy the .sys into C:\Windows\System32\drivers\,
register the kernel service, and prepend 'applewirelessmouse' to the LowerFilters value
on the selected device instance. No driver package is added to the DriverStore, so
nothing outside that one device instance changes, and Uninstall-MagicMousePatch.ps1
reverses every step.

Two binary variants are supported and auto-detected:

  AppleSigned      Apple's driver, UNMODIFIED: Authenticode Valid, signer subject
                   starting CN=Microsoft Windows Hardware Compatibility Publisher
                   (or CN=Apple Inc), PE OriginalFilename AppleWirelessMouse.sys.
                   Microsoft-countersigned, so Test Mode is EXPECTED not to be
                   required - an expectation NOT yet verified on a machine with
                   testsigning off, because this project's development PC runs with
                   test signing ON. Confirm after rebooting with
                   'sc query applewirelessmouse'. This is the recommended variant.

  PatchedResigned  Legacy: a byte-patched copy re-signed as CN=MagicMouseFix, pinned
                   by SHA256 and by size. Patching breaks Apple's countersignature,
                   so it REQUIRES test signing on and memory integrity off.
                   MagicMouseFix.cer is NOT shipped in this repository; place it
                   beside this script to use this path.

Anything else is refused.

Workflow:
  1. Elevation, Windows build >= 14393, HiberbootEnabled (Fast Startup) = 0
  2. Locate the driver: -DriverPath, -FromDriverStore, beside this script, the
     bundled ..\apple-driver\applewirelessmouse.sys, then the local DriverStore
  3. Identify the variant from its signature and PE version resource, and verify it
  4. PatchedResigned only: test signing + HVCI checks, and import MagicMouseFix.cer
     to LocalMachine\TrustedPublisher (never to Root)
  5. Detect the mouse (BTHENUM HID profile 00001124, PID 030D / 0310 / 0269 / 0323),
     then back up any existing driver to C:\ProgramData\MagicMousePatch\backup\
  6. Clear BTHPORT cache, stop service, disable device, copy, register service, write
     LowerFilters (REG_MULTI_SZ) on the device-instance key, re-enable device
  7. Verify hash, size, Authenticode status and signer against the source actually
     used, plus LowerFilters and the service key when the mouse was bound, then
     instruct a reboot

Exit codes: 0 = success, or the partial state where the driver file and service are
installed but no mouse is paired yet; 1 = any failure, verification included.

.PARAMETER DriverPath
Explicit path to applewirelessmouse.sys. Use this to install Apple's unmodified driver
from wherever you extracted it.

.PARAMETER FromDriverStore
Search %SystemRoot%\System32\DriverStore\FileRepository for Apple's driver (present if
Apple Software Update / Boot Camp support software was ever installed) and use that.

.PARAMETER DryRun
Report what would happen and change nothing: no file copies, no registry writes, no
device disable/enable.

.PARAMETER TargetPid
Restrict to one model, e.g. -TargetPid 030D. Use this when several Magic Mice are
paired and only one should be modified.

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
    [switch]$FromDriverStore,
    [switch]$DryRun,
    [ValidateSet('030D','0310','0269','0323')]
    [string]$TargetPid
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

$ScriptRoot       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CertPath         = Join-Path $ScriptRoot "MagicMouseFix.cer"
$BackupDir        = "C:\ProgramData\MagicMousePatch\backup"
$TargetDriver     = "C:\Windows\System32\drivers\applewirelessmouse.sys"
$ServiceName      = "applewirelessmouse"
$ServiceImagePath = "\SystemRoot\System32\drivers\applewirelessmouse.sys"

# Legacy patched+re-signed variant: exact artifact this installer shipped as v1.0.0.
$PatchedSha256  = "370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03"
$PatchedSize    = 66288
$CertThumbprint = "16940C0F937D569363560D5FEC5CD8FA6D6D9BCE"

# Apple's unmodified driver is NOT hash-pinned: Apple has shipped more than one Boot
# Camp build, and a hash pin here would reject a legitimately signed newer copy. It is
# identified instead by three properties a modified binary cannot all keep: an
# Authenticode status of Valid, a signer subject starting with one of the two publishers
# Apple's driver has carried, and the PE version resource Apple stamped into it.
$AppleSignerPattern    = '^CN=(Microsoft Windows Hardware Compatibility Publisher|Apple Inc)'
$AppleOriginalFilename = 'AppleWirelessMouse.sys'

# Bluetooth PIDs of the Magic Mouse models this filter serves. The PID is the one the
# mouse reports in its BTHENUM InstanceId; -TargetPid selects a single model.
$MagicMouseModels = @(
    [pscustomobject]@{ Pid = '0323'; Name = 'Magic Mouse v3 (2024, USB-C)' }
    [pscustomobject]@{ Pid = '0269'; Name = 'Magic Mouse v2'              }
    [pscustomobject]@{ Pid = '0310'; Name = 'Magic Mouse v2 (alt PID)'    }
    [pscustomobject]@{ Pid = '030D'; Name = 'Magic Mouse v1'              }
)

# Matches any of the above on the Bluetooth HID (00001124) profile.
$MagicMouseDeviceRe = 'BTHENUM.*00001124.*PID&(0323|0269|0310|030D)'

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
    $shown = if ($null -eq $hib) { 'not set' } else { $hib }
    Write-Status "Fast Startup is ON (HiberbootEnabled=$shown) - install will silently fail" "ERROR"
    Write-Host "  REMEDIATE: run 'powercfg /h off' as Administrator, reboot, then re-run" -ForegroundColor Yellow
    Write-Host "  this installer." -ForegroundColor Yellow
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
    Write-Host "  Only the legacy patched driver needs this; Apple's UNMODIFIED driver is" -ForegroundColor Yellow
    Write-Host "  Microsoft-countersigned - re-run with -FromDriverStore or -DriverPath. To use" -ForegroundColor Yellow
    Write-Host "  the patched variant: 'bcdedit /set testsigning on', reboot, re-run (a 'Test" -ForegroundColor Yellow
    Write-Host "  Mode' desktop watermark is expected)." -ForegroundColor Yellow
    return $false
}

# Advisory only: HVCI blocks the patched variant, never Apple's signed one.
function Test-HvciState {
    Write-Section "Checking HVCI / Memory Integrity..."
    $hvciKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $enabled = $null
    if (Test-Path $hvciKey) {
        $enabled = (Get-ItemProperty -Path $hvciKey -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
    }
    if ($enabled -eq 1) {
        Write-Status "HVCI / Memory Integrity is ENABLED" "WARN"
        Write-Host "  Windows 11 22H2+ blocks self-signed kernel drivers when HVCI is on. If the" -ForegroundColor Yellow
        Write-Host "  driver fails to load after reboot, turn Memory Integrity off (Settings ->" -ForegroundColor Yellow
        Write-Host "  Privacy & Security -> Windows Security -> Device Security -> Core" -ForegroundColor Yellow
        Write-Host "  isolation) and reboot." -ForegroundColor Yellow
        return
    }
    Write-Status "HVCI / Memory Integrity not enabled" "OK"
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
    param([string]$DriverPath, [switch]$FromDriverStore)

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

    # The copy that ships in this download: v1-binary-patch\apple-driver\.
    $bundled = Join-Path (Split-Path -Parent $ScriptRoot) 'apple-driver\applewirelessmouse.sys'
    if (Test-Path -LiteralPath $bundled) {
        Write-Status "Using the bundled driver: $bundled" "OK"
        return (Resolve-Path -LiteralPath $bundled).Path
    }

    $ds = Find-DriverStoreCopy
    if ($ds) {
        Write-Status "No local copy; using DriverStore: $ds" "OK"
        return $ds
    }

    Write-Status "applewirelessmouse.sys not found" "ERROR"
    Write-Host "  Provide it by extracting the whole download (apple-driver\ must sit one" -ForegroundColor Yellow
    Write-Host "  folder above this installer), by placing it beside this script, by passing" -ForegroundColor Yellow
    Write-Host "  -DriverPath <path>, or by installing Apple Software Update and passing" -ForegroundColor Yellow
    Write-Host "  -FromDriverStore." -ForegroundColor Yellow
    return $null
}

# Identify which binary we were handed. Hash pinning is used only for the legacy patched
# artifact; see $AppleSignerPattern above for why Apple's is identified by signature
# status, signer and PE version resource instead.
function Get-DriverVariant {
    param([string]$Path)

    $sig   = Get-AuthenticodeSignature -LiteralPath $Path
    $thumb = ''
    $subj  = ''
    if ($sig.SignerCertificate) {
        $thumb = $sig.SignerCertificate.Thumbprint.ToUpper()
        $subj  = $sig.SignerCertificate.Subject
    }

    $item = Get-Item -LiteralPath $Path
    # Some PE version resources pad the string; compare on the trimmed value.
    $origName = ([string]$item.VersionInfo.OriginalFilename).Trim()

    $info = [ordered]@{
        Path      = $Path
        Size      = $item.Length
        Sha256    = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpper()
        SigStatus = $sig.Status
        Signer    = $subj
        Thumb     = $thumb
        OrigName  = $origName
        FileVer   = [string]$item.VersionInfo.FileVersion
        Variant   = 'Unknown'
    }

    if ($thumb -eq $CertThumbprint) {
        $info.Variant = 'PatchedResigned'
    } elseif ($sig.Status -eq 'Valid' -and $subj -match $AppleSignerPattern -and $origName -eq $AppleOriginalFilename) {
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
    Write-Host ("  Path     : {0}" -f $Info.Path)       -ForegroundColor Gray
    Write-Host ("  Size     : {0} bytes" -f $Info.Size) -ForegroundColor Gray
    Write-Host ("  SHA256   : {0}" -f $Info.Sha256)     -ForegroundColor Gray
    Write-Host ("  Auth     : {0}" -f $Info.SigStatus)  -ForegroundColor Gray
    Write-Host ("  Signer   : {0}" -f $Info.Signer)     -ForegroundColor Gray
    Write-Host ("  PE name  : {0}" -f $Info.OrigName)   -ForegroundColor Gray
    Write-Host ("  PE ver   : {0}" -f $Info.FileVer)    -ForegroundColor Gray

    switch ($Info.Variant) {
        'AppleSigned' {
            Write-Status "Apple's UNMODIFIED driver - Microsoft-countersigned" "OK"
            Write-Host "  Signature valid, signer and PE OriginalFilename both as Apple ships them," -ForegroundColor Green
            Write-Host "  so Windows is EXPECTED to load it without Test Mode." -ForegroundColor Green
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
            Write-Status "Patched driver verified against pinned hash and size" "OK"
            Write-Host "  This variant REQUIRES Test Mode. Apple's unmodified driver does not -" -ForegroundColor Yellow
            Write-Host "  see -FromDriverStore / -DriverPath." -ForegroundColor Yellow
            return $true
        }
        default {
            Write-Status "Unrecognised driver binary - refusing to install" "ERROR"
            Write-Host "  Accepted only if ALL of these hold (actual values above):" -ForegroundColor Yellow
            Write-Host "    Apple   : Auth=Valid, signer matching $AppleSignerPattern," -ForegroundColor Gray
            Write-Host "              PE OriginalFilename '$AppleOriginalFilename'" -ForegroundColor Gray
            Write-Host "    Patched : signed by MagicMouseFix $CertThumbprint" -ForegroundColor Gray
            Write-Host "  A binary matching neither has been modified, is corrupted, or is not" -ForegroundColor Yellow
            Write-Host "  this driver at all." -ForegroundColor Yellow
            return $false
        }
    }
}

function Import-MagicMouseCert {
    Write-Section "Importing code-signing certificate..."
    if (-not (Test-Path $CertPath)) {
        Write-Status "Certificate file not found: $CertPath" "ERROR"
        Write-Host "  MagicMouseFix.cer is not shipped in this repository; the legacy patched" -ForegroundColor Yellow
        Write-Host "  driver only installs if you supply it here. Prefer Apple's unmodified" -ForegroundColor Yellow
        Write-Host "  driver: -FromDriverStore or -DriverPath." -ForegroundColor Yellow
        return $false
    }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
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

        $found = Get-ChildItem "Cert:\LocalMachine\TrustedPublisher" |
                 Where-Object { $_.Thumbprint -eq $CertThumbprint }
        if (-not $found) {
            Write-Status "Post-import verification failed (thumbprint not present)" "ERROR"
            return $false
        }
        Write-Status "Cert verified in LocalMachine\TrustedPublisher ($CertThumbprint)" "OK"
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
        return
    }
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $dst = Join-Path $BackupDir ("applewirelessmouse_{0}.sys" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    Copy-Item -Path $TargetDriver -Destination $dst -Force
    Write-Status "Backed up to $dst" "OK"
}

# Every paired Magic Mouse that matches, in enumeration order. The caller installs on
# the first and reports the rest, so a user with several mice can see which one changed.
function Get-MagicMouseDevice {
    param([string]$TargetPid)
    $re = if ($TargetPid) { 'BTHENUM.*00001124.*PID&' + $TargetPid } else { $MagicMouseDeviceRe }
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match $re }
}

# Which model an instance is, so the install can name it.
function Get-MagicMouseModel {
    param([string]$InstanceId)
    foreach ($m in $MagicMouseModels) {
        if ($InstanceId -match ('PID&' + $m.Pid)) { return $m }
    }
    return $null
}

function Clear-BthportCache {
    param([string]$InstanceId)
    Write-Section "Clearing BTHPORT cache..."
    $mac = ''
    if ($InstanceId -match '([0-9A-Fa-f]{12})_C\d+$') {
        $mac = $Matches[1].ToUpper()
    }
    if (-not $mac) {
        Write-Status "Could not extract MAC from InstanceId; skipping cache clear" "WARN"
        return
    }
    Write-Host "  MAC: $mac" -ForegroundColor Gray
    $base = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$mac"
    foreach ($sub in 'CachedServices','DynamicCachedServices') {
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
    # Type=1 SERVICE_KERNEL_DRIVER, Start=1 SERVICE_SYSTEM_START (required for lower
    # filters), ErrorControl=1 SERVICE_ERROR_NORMAL.
    Set-ItemProperty -Path $regPath -Name "Type"         -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "Start"        -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "ErrorControl" -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "ImagePath"    -Value $ServiceImagePath -Type ExpandString
    Set-ItemProperty -Path $regPath -Name "DisplayName"  -Value "Apple Magic Mouse Scroll Fix" -Type String
    Set-ItemProperty -Path $regPath -Name "Description"  -Value "Lower-filter driver for the Apple Magic Mouse scroll fix" -Type String
    Write-Status "Service registered (Type=1 kernel, Start=1 SYSTEM_START)" "OK"
}

# LowerFilters lives on the PnP device-instance key itself:
#   HKLM\SYSTEM\CurrentControlSet\Enum\<InstanceId>
# NOT inside its 'Device Parameters' subkey.
function Set-LowerFiltersMultiSz {
    param([string]$InstanceId)

    Write-Section "Writing LowerFilters (REG_MULTI_SZ) at device-instance level..."
    $instancePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    if (-not (Test-Path -LiteralPath $instancePath)) {
        Write-Status "Device instance key not found: $instancePath" "ERROR"
        Write-Host "  The mouse was enumerated but its registry key is missing, so the filter" -ForegroundColor Yellow
        Write-Host "  cannot be bound. Re-pair the mouse and run this installer again." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  Instance key: $instancePath" -ForegroundColor Gray

    $existing = @()
    $cur = (Get-ItemProperty -LiteralPath $instancePath -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters
    if ($cur) {
        if ($cur -is [array]) { $existing = @($cur) } else { $existing = @([string]$cur) }
    }
    if ($existing -notcontains $ServiceName) {
        $existing = @($ServiceName) + $existing
    }
    # New-ItemProperty -Force overwrites an existing value in place and honours
    # -PropertyType, so the value is never removed first: a write that is then refused
    # must not be able to destroy filters belonging to other software.
    #
    # The Enum tree belongs to the PnP manager, and its default ACL gives SYSTEM Full
    # Control and Administrators read-only. This project's own hardware testing shows the
    # write going through under elevation, but on a machine that keeps the stock ACL it is
    # refused - as UnauthorizedAccessException or SecurityException. Diagnose it here
    # instead of letting a stack trace land on the user.
    try {
        New-ItemProperty -LiteralPath $instancePath -Name 'LowerFilters' -Value $existing -PropertyType MultiString -Force | Out-Null
    } catch [System.UnauthorizedAccessException], [System.Security.SecurityException] {
        Write-Status "Access denied writing LowerFilters: $($_.Exception.Message)" "ERROR"
        Write-Host "  That key is owned by SYSTEM on this machine, so Administrator rights are not" -ForegroundColor Yellow
        Write-Host "  enough to write it. Two ways forward:" -ForegroundColor Yellow
        Write-Host "    1. Re-run this installer in a SYSTEM context, e.g." -ForegroundColor Yellow
        Write-Host "       psexec -s -i powershell.exe -File .\Install-MagicMousePatch.ps1" -ForegroundColor Yellow
        Write-Host "    2. Grant your account write access to that one device-instance key:" -ForegroundColor Yellow
        Write-Host "       HKLM\SYSTEM\CurrentControlSet\Enum\$InstanceId" -ForegroundColor Yellow
        return $false
    }
    Write-Status "LowerFilters = [$([string]::Join(', ', $existing))]" "OK"
    return $true
}

function Invoke-DirectCopyInstall {
    param([pscustomobject]$Info, [string]$InstanceId)

    if (-not $InstanceId) {
        Write-Section "Installing driver file..."
        Copy-Item -LiteralPath $Info.Path -Destination $TargetDriver -Force
        Write-Status "Copied driver to $TargetDriver" "OK"
        return
    }

    Write-Section "Installing driver (disable -> copy -> enable)..."
    # Disabling is an optimisation, not a requirement: it unloads the driver so the copy
    # is not blocked by the running one holding System32\drivers\applewirelessmouse.sys
    # open. When the disable cannot be done the copy is still attempted, and nothing is
    # re-enabled afterwards, because nothing was disabled.
    $disabled = $false
    try {
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        $disabled = $true
        Start-Sleep -Seconds 5
    } catch {
        Write-Status "Could not disable the device: $($_.Exception.Message)" "WARN"
        Write-Host "  The device was NOT disabled, so it will not be re-enabled either." -ForegroundColor Yellow
        Write-Host "  Attempting the copy anyway." -ForegroundColor Yellow
    }

    # A device that WAS disabled has to be re-enabled even when the copy throws: this
    # mouse may be the only pointing device on the machine.
    $copyFailed   = $false
    $enableFailed = $false
    try {
        Copy-Item -LiteralPath $Info.Path -Destination $TargetDriver -Force
        Write-Status "Copied driver to $TargetDriver" "OK"
    } catch {
        Write-Status "Could not copy the driver to $TargetDriver" "ERROR"
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  The loaded driver holds that file open, which is exactly what the disable" -ForegroundColor Yellow
        Write-Host "  step above is for. Reboot and re-run this installer." -ForegroundColor Yellow
        $copyFailed = $true
    } finally {
        if ($disabled) {
            try {
                Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 8
                Write-Status "Device re-enabled" "OK"
            } catch {
                Write-Status "Could not re-enable the device: $($_.Exception.Message)" "ERROR"
                Write-Host "  Re-enable the device in Device Manager before re-running." -ForegroundColor Yellow
                $enableFailed = $true
            }
        }
    }
    # A device left administratively disabled is a failed install even if the copy
    # worked, and it is the more urgent of the two problems.
    if ($enableFailed) { throw "The device was disabled but could not be re-enabled: $InstanceId" }
    if ($copyFailed)   { throw "Could not copy the driver to ${TargetDriver}: reboot and re-run" }
}

function Test-PostInstall {
    param([pscustomobject]$Info, [string]$InstanceId)

    Write-Section "Verifying post-install state..."

    $postHash  = (Get-FileHash -LiteralPath $TargetDriver -Algorithm SHA256).Hash.ToUpper()
    $postSize  = (Get-Item -LiteralPath $TargetDriver).Length
    $sig       = Get-AuthenticodeSignature -LiteralPath $TargetDriver
    $postThumb = ''
    if ($sig.SignerCertificate) { $postThumb = $sig.SignerCertificate.Thumbprint.ToUpper() }

    # Compare against what we installed, not against a baked-in constant: the source may
    # legitimately be Apple's driver of any Boot Camp vintage.
    $hashOk = ($postHash -eq $Info.Sha256)
    $sizeOk = ($postSize -eq $Info.Size)
    $sigOk  = ($sig.Status -eq 'Valid')

    $signerOk = switch ($Info.Variant) {
        'PatchedResigned' { $postThumb -eq $CertThumbprint }
        'AppleSigned'     { [bool]($sig.SignerCertificate -and $sig.SignerCertificate.Subject -match $AppleSignerPattern) }
        default           { $false }
    }

    $fmt = @{$true='OK';$false='FAIL'}
    Write-Host ("  Variant  : {0}" -f $Info.Variant)                     -ForegroundColor Gray
    Write-Host ("  SHA256   : {0} ({1})" -f $postHash, $fmt[$hashOk])    -ForegroundColor Gray
    Write-Host ("  Size     : {0} ({1})" -f $postSize, $fmt[$sizeOk])    -ForegroundColor Gray
    Write-Host ("  Auth Sig : {0} ({1})" -f $sig.Status, $fmt[$sigOk])   -ForegroundColor Gray
    Write-Host ("  Signer   : {0} ({1})" -f $postThumb, $fmt[$signerOk]) -ForegroundColor Gray

    $regOk = $true
    if ($InstanceId) {
        $filters   = @((Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId" -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters)
        $filtersOk = ($filters -contains $ServiceName)
        $svc       = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue
        $svcOk     = [bool]($null -ne $svc -and $svc.Type -eq 1 -and $svc.Start -eq 1 -and $svc.ImagePath -eq $ServiceImagePath)
        Write-Host ("  Filters  : [{0}] ({1})" -f ([string]::Join(', ', $filters)), $fmt[$filtersOk]) -ForegroundColor Gray
        Write-Host ("  Service  : Type={0} Start={1} ({2})" -f $svc.Type, $svc.Start, $fmt[$svcOk])   -ForegroundColor Gray
        $regOk = ($filtersOk -and $svcOk)
    }

    if ($hashOk -and $sizeOk -and $sigOk -and $signerOk -and $regOk) {
        Write-Status "Post-install verification PASSED" "OK"
        return $true
    }
    Write-Status "Post-install verification FAILED" "ERROR"
    return $false
}

# ============================================================================
# Summary
# ============================================================================

function Show-Summary {
    param(
        [pscustomobject]$Info,
        [pscustomobject]$Model,
        [string]$InstanceId,
        [ValidateSet('Complete','Partial','DryRun')]
        [string]$Mode
    )

    $title = switch ($Mode) {
        'Complete' { " Installation Complete" }
        'Partial'  { " Partial install - mouse NOT bound yet" }
        'DryRun'   { " DRY RUN - nothing was changed" }
    }
    $color = if ($Mode -eq 'Complete') { "Green" } else { "Yellow" }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor $color
    Write-Host $title                                     -ForegroundColor $color
    Write-Host "========================================" -ForegroundColor $color
    Write-Host ""
    Write-Host ("Driver  : {0}" -f $Info.Variant) -ForegroundColor Cyan
    if ($Model) { Write-Host ("Mouse   : {0}" -f $Model.Name) -ForegroundColor Cyan }
    if ($Info.Variant -eq 'AppleSigned') {
        Write-Host "Signing : Microsoft-countersigned, so Test Mode is EXPECTED not to be" -ForegroundColor Green
        Write-Host "          required. Not yet verified with testsigning off - this project's" -ForegroundColor Green
        Write-Host "          development PC runs with test signing ON - so after rebooting," -ForegroundColor Green
        Write-Host "          confirm with: sc query applewirelessmouse" -ForegroundColor Green
    } else {
        Write-Host "Signing : self-signed - Test Mode must stay ON" -ForegroundColor Yellow
    }
    Write-Host ""

    if ($Mode -eq 'DryRun') {
        Write-Host "Would do:" -ForegroundColor Cyan
        Write-Host ("  1. Back up {0} (if present) to {1}" -f $TargetDriver, $BackupDir) -ForegroundColor Gray
        Write-Host ("  2. Copy {0} -> {1}" -f $Info.Path, $TargetDriver) -ForegroundColor Gray
        Write-Host ("  3. Register kernel service '{0}' (Type=1, Start=1)" -f $ServiceName) -ForegroundColor Gray
        if ($InstanceId) {
            Write-Host ("  4. Prepend '{0}' to LowerFilters at HKLM\SYSTEM\CurrentControlSet\Enum\{1}" -f $ServiceName, $InstanceId) -ForegroundColor Gray
        } else {
            Write-Host "  4. SKIP LowerFilters - no Magic Mouse is paired" -ForegroundColor Yellow
        }
        Write-Host "  5. Verify the installed file against the source, and read the registry back" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Re-run without -DryRun to apply." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    if ($Mode -eq 'Partial') {
        Write-Host "The driver file and the kernel service are installed, but no Magic Mouse is" -ForegroundColor Yellow
        Write-Host "paired, so LowerFilters was not written and scroll will NOT work yet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "NEXT STEP: pair the mouse over Bluetooth, then run this installer again." -ForegroundColor Yellow
    } else {
        Write-Host "What you get:" -ForegroundColor Cyan
        Write-Host "  Pointer : works" -ForegroundColor Gray
        Write-Host "  Scroll  : two-finger scroll via Apple's multi-touch filter" -ForegroundColor Gray
        Write-Host "  Battery : install Magic Tray (https://magictray.app/) - it detects this" -ForegroundColor Gray
        Write-Host "            driver and briefly flips Mode A/B to read the level" -ForegroundColor Gray
        Write-Host ""
        Write-Host "NEXT STEP: reboot, e.g.  shutdown /r /t 60 /c 'Magic Mouse driver'" -ForegroundColor Yellow
        Write-Host "Then verify with:  sc query applewirelessmouse" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Support: riley@revivebusiness.ca" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================================
# Main
# ============================================================================

function Main {
    param(
        [string]$DriverPath,
        [switch]$FromDriverStore,
        [switch]$DryRun,
        [string]$TargetPid
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Magic Mouse Scroll Fix Installer"       -ForegroundColor Cyan
    Write-Host " Apple applewirelessmouse.sys filter"    -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    if ($DryRun) { Write-Host " DRY RUN - nothing will be changed" -ForegroundColor Yellow }

    if (-not (Test-WindowsVersion)) { exit 1 }
    if (-not $DryRun -and -not (Test-FastStartup)) { exit 1 }

    $src = Resolve-DriverSource -DriverPath $DriverPath -FromDriverStore:$FromDriverStore
    if (-not $src) { exit 1 }

    $info = Get-DriverVariant -Path $src
    if (-not (Test-DriverBinary -Info $info)) { exit 1 }

    # Code-integrity gates apply ONLY to the self-signed, patched variant. Apple's
    # unmodified driver is Microsoft-countersigned: forcing Test Mode or demanding
    # Memory Integrity be off would push users into weakening their machine for nothing.
    if ($info.Variant -eq 'PatchedResigned') {
        if (-not $DryRun) {
            if (-not (Test-TestSigning)) { exit 1 }
            Test-HvciState
            if (-not (Import-MagicMouseCert)) { exit 1 }
        }
    } else {
        Write-Section "Code-integrity requirements..."
        Write-Status "Apple-signed driver: no certificate import needed" "OK"
        Write-Host "  The .sys carries Apple's signature and Microsoft's countersignature, and no" -ForegroundColor Green
        Write-Host "  catalog is installed, so kernel code integrity is EXPECTED to be satisfied" -ForegroundColor Green
        Write-Host "  without Test Mode. Not yet verified with testsigning off; after rebooting," -ForegroundColor Green
        Write-Host "  confirm the driver loaded with 'sc query applewirelessmouse'." -ForegroundColor Green
    }

    Write-Section "Detecting Magic Mouse..."
    $mice       = @(Get-MagicMouseDevice -TargetPid $TargetPid)
    $mouse      = $mice | Select-Object -First 1
    $model      = $null
    $label      = 'unrecognised PID'
    $instanceId = ''
    if ($mouse) {
        $instanceId = $mouse.InstanceId
        $model      = Get-MagicMouseModel -InstanceId $instanceId
        if ($model) { $label = $model.Name }
        Write-Status "Found: $label - $($mouse.FriendlyName)" "OK"
        Write-Host "  $instanceId" -ForegroundColor Gray
    } else {
        Write-Status "No Magic Mouse paired (looked for PID 0323 / 0269 / 0310 / 030D)" "WARN"
    }

    # Only ONE device instance is ever modified, and it is simply the first one Windows
    # enumerated. Name it, so a user with several Magic Mice can see whether it is the
    # one they meant.
    if ($mice.Count -gt 1) {
        Write-Status "$($mice.Count) Magic Mouse devices are paired - only one will be changed" "WARN"
        Write-Host "  Chosen : $label - $($mouse.FriendlyName)" -ForegroundColor Yellow
        foreach ($o in ($mice | Select-Object -Skip 1)) {
            $om = Get-MagicMouseModel -InstanceId $o.InstanceId
            $on = if ($om) { $om.Name } else { 'unknown model' }
            Write-Host "  Skipped: $on - $($o.FriendlyName)" -ForegroundColor Yellow
        }
        Write-Host "  Re-run with -TargetPid <030D|0310|0269|0323> to pick a specific model." -ForegroundColor Yellow
    }

    if ($DryRun) {
        Show-Summary -Info $info -Model $model -InstanceId $instanceId -Mode 'DryRun'
        exit 0
    }

    Backup-ExistingDriver
    if ($instanceId) { Clear-BthportCache -InstanceId $instanceId }

    Write-Section "Stopping applewirelessmouse service (if running)..."
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Status "Service stopped" "OK"
    } else {
        Write-Status "Service not running" "OK"
    }

    Invoke-DirectCopyInstall -Info $info -InstanceId $instanceId
    Register-MagicMouseService

    if ($instanceId -and -not (Set-LowerFiltersMultiSz -InstanceId $instanceId)) {
        Write-Host ""
        Write-Status "Installation failed: LowerFilters could not be written" "ERROR"
        Write-Host "  Run Uninstall-MagicMousePatch.ps1 to revert." -ForegroundColor Yellow
        exit 1
    }

    if (-not (Test-PostInstall -Info $info -InstanceId $instanceId)) {
        Write-Host ""
        Write-Status "Installation completed with verification errors" "ERROR"
        Write-Host "  Run Uninstall-MagicMousePatch.ps1 to revert." -ForegroundColor Yellow
        exit 1
    }

    if ($instanceId) {
        Show-Summary -Info $info -Model $model -InstanceId $instanceId -Mode 'Complete'
    } else {
        Show-Summary -Info $info -Model $model -Mode 'Partial'
    }
}

try {
    Main -DriverPath $DriverPath -FromDriverStore:$FromDriverStore -DryRun:$DryRun -TargetPid $TargetPid
} catch {
    Write-Host ""
    Write-Status "Installation failed: $_" "ERROR"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
