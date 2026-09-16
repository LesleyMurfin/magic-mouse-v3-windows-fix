# Setup-Community.ps1
# $0 path: make a local code-signing cert, enable testsigning, sign the unique
# package, pnputil /add-driver, then F1 so MT reports return.
#
# Not WHQL. Requires testsigning ON, Secure Boot off, Memory integrity off.
# Never Copy-Item onto System32 or DriverStore. Never delete oem16.
# Never PATH-A. Never live-named MagicMouseDriver.sys.
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SkipPnputil
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'scripts\Kmdf-Common.ps1')

$script:KmdfCommunitySubject = 'CN=MagicMouseDriver Community'
$script:KmdfRebootRequired   = $false

function Fail([string]$m) {
    Write-KmdfLog -Message $m -Level 'ERROR'
    Write-KmdfResult -Status 'FAIL' -Detail $m
    exit 1
}

function Get-KmdfCommunityCert {
    $have = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $script:KmdfCommunitySubject -and $_.HasPrivateKey } |
        Select-Object -First 1
    if ($have) { return $have }
    Write-KmdfLog -Message "Creating local CodeSigning cert ($script:KmdfCommunitySubject). Private key stays on this PC." -Level 'HEAD'
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $script:KmdfCommunitySubject `
        -HashAlgorithm SHA256 `
        -KeyLength 2048 `
        -KeyExportPolicy NonExportable `
        -CertStoreLocation Cert:\LocalMachine\My `
        -NotAfter (Get-Date).AddYears(10)
    $tmp = Join-Path $env:TEMP 'mm-community.cer'
    Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
    Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-KmdfLog -Message ("Community cert thumb=" + $cert.Thumbprint) -Level 'OK'
    return $cert
}

function Test-KmdfTestSigningOn {
    $out = & bcdedit.exe /enum '{current}' 2>$null | Out-String
    return ($out -match '(?i)testsigning\s+Yes')
}

function Enable-KmdfTestSigning {
    if (Test-KmdfTestSigningOn) {
        Write-KmdfLog -Message 'testsigning already Yes' -Level 'OK'
        return $false
    }
    Write-KmdfLog -Message 'Enabling bcdedit /set testsigning on (required for a free self-signed kernel driver). Reboot required.' -Level 'WARN'
    & bcdedit.exe /set testsigning on
    if ($LASTEXITCODE -ne 0) {
        Fail 'bcdedit testsigning failed. Turn off Secure Boot in firmware, then re-run.'
    }
    return $true
}

function Test-KmdfSecureBootOn {
    try { return [bool](Confirm-SecureBootUEFI) } catch { return $false }
}

function Add-KmdfCommunitySignature {
    param($Cert)
    $inf = Join-Path $Here $script:KmdfUniqueInf
    $sys = Join-Path $Here $script:KmdfUniqueSys
    $cat = Join-Path $Here $script:KmdfUniqueCat
    if (-not (Test-Path -LiteralPath $inf)) { Fail "Missing $inf" }
    if (-not (Test-Path -LiteralPath $sys)) { Fail "Missing $sys - need the unique WDK .sys, not MagicMouseDriver.sys" }
    if (Test-Path -LiteralPath (Join-Path $Here $script:KmdfLiveSysName)) {
        Fail "Package folder has MagicMouseDriver.sys - remove it. That name is Apr 30 restore."
    }
    if (Test-KmdfForbiddenSysFile -Path $sys) { Fail 'Refusing banned .sys' }

    $infText = Get-Content -LiteralPath $inf -Raw
    if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') {
        Fail 'INF AddService must be MagicMouseDriver204Scroll'
    }
    if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') {
        Fail 'INF AddService hijacks live MagicMouseDriver'
    }

    Write-KmdfLog -Message "Signing $sys with community cert $($Cert.Thumbprint)" -Level 'HEAD'
    $sig = Set-AuthenticodeSignature -FilePath $sys -Certificate $Cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com' -ErrorAction SilentlyContinue
    if ($null -eq $sig -or $null -eq $sig.SignerCertificate) {
        $sig = Set-AuthenticodeSignature -FilePath $sys -Certificate $Cert -HashAlgorithm SHA256
    }
    if ($null -eq $sig.SignerCertificate) { Fail "Set-AuthenticodeSignature failed on $sys" }

    # New-FileCatalog is NOT a substitute: it emits a generic file-hash catalog
    # that pnputil /add-driver rejects, so the fallback shipped a package that
    # could not install. Inf2Cat (WDK) is required.
    $inf2cat = Get-Command Inf2Cat.exe -ErrorAction SilentlyContinue
    if (-not $inf2cat) {
        Fail ('Inf2Cat.exe not found. A driver catalog pnputil accepts can only be built by Inf2Cat, ' +
              'which ships with the Windows Driver Kit. Install the WDK from ' +
              'https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk and re-run from ' +
              'a Developer Command Prompt, or add C:\Program Files (x86)\Windows Kits\10\bin\x86 to PATH.')
    }
    Write-KmdfLog -Message 'Inf2Cat present - building driver catalog' -Level 'INFO'
    & Inf2Cat.exe /driver:$Here /os:10_X64
    if ($LASTEXITCODE -ne 0) { Fail "Inf2Cat exited $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $cat)) { Fail "Missing $cat after catalog step" }
    $csig = Set-AuthenticodeSignature -FilePath $cat -Certificate $Cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com' -ErrorAction SilentlyContinue
    if ($null -eq $csig -or $null -eq $csig.SignerCertificate) {
        $csig = Set-AuthenticodeSignature -FilePath $cat -Certificate $Cert -HashAlgorithm SHA256
    }
    if ($null -eq $csig.SignerCertificate) { Fail "Set-AuthenticodeSignature failed on $cat" }
    Write-KmdfLog -Message "Signed sys+cat thumb=$($Cert.Thumbprint)" -Level 'OK'
}

function Install-KmdfCommunityPackage {
    $inf = Join-Path $Here $script:KmdfUniqueInf
    # Integrity gate, deliberately BEFORE /add-driver: a missing F1 helper means this
    # package was extracted incompletely, and failing here fails while nothing is
    # installed yet, instead of inverting an already-successful install below.
    $f1 = Join-Path $Here 'scripts\mm-f1-once.ps1'
    if (-not (Test-Path -LiteralPath $f1)) {
        Fail "Missing $f1 - incomplete package. Re-extract the release, then re-run."
    }
    $pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
    $blocks = $pnpRaw -split '(?=Published Name:)'
    foreach ($block in $blocks) {
        if ($block -notmatch 'MagicMouseDriver-kmdf-204-scroll\.inf') { continue }
        if ($block -match 'Original Name:\s+MagicMouseDriver\.inf') { continue }
        if ($block -match 'Published Name:\s+oem16\.inf') { continue }
        if ($block -match 'Published Name:\s+(oem\d+\.inf)') {
            $oem = $Matches[1]
            if ($oem -eq 'oem16.inf') { Fail 'REFUSE delete oem16' }
            Write-KmdfLog -Message "Removing unique $oem only" -Level 'INFO'
            & pnputil.exe /delete-driver $oem /uninstall /force
        }
    }
    Write-KmdfLog -Message "pnputil /add-driver $inf /install" -Level 'HEAD'
    & pnputil.exe /add-driver $inf /install
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 3010) { Fail "pnputil /add-driver exited $rc" }
    # 3010 is success-with-reboot-required, not failure. Carry it to the exit code.
    if ($rc -eq 3010) { $script:KmdfRebootRequired = $true }

    # Everything below is BEST-EFFORT recovery, not installation: /add-driver has already
    # published the package. MmAutoF1Watcher re-sends F1 on every PID_0323 arrival and at
    # startup, so a failure here means "multitouch may need a nudge", never "install
    # failed" - and it must never discard a banked 3010.
    #
    # $inst is a hardware ID, not a device instance ID (a real one carries a third
    # component, e.g. ...PID&0323\7&1a2b3c4d&0&<BDADDR>_C00000000), and no recorded run
    # has ever shown this call returning 0, so a non-zero code here is the norm.
    $inst = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'
    & pnputil.exe /restart-device $inst 2>$null
    $rrc = $LASTEXITCODE
    if ($rrc -eq 3010) {
        $script:KmdfRebootRequired = $true
    }
    elseif ($rrc -ne 0) {
        Write-KmdfLog -Message "pnputil /restart-device exited $rrc - the package is installed, this step is best-effort. If two-finger scroll is dead: make sure the Magic Mouse (PID 0323) is paired and connected, then run scripts\mm-f1-once.ps1 as admin, or let the MmAutoF1Watcher task re-send F1 on the next connect or at startup." -Level 'WARN'
    }
    Start-Sleep -Seconds 3

    Write-KmdfLog -Message 'HidD_SetFeature F1 (MT enable; 121/-EIO is expected)' -Level 'INFO'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f1
    $frc = $LASTEXITCODE
    if ($frc -ne 0) {
        Write-KmdfLog -Message "mm-f1-once.ps1 exited $frc - the package is installed, but multitouch may still be in compact 9-byte mode, so two-finger scroll can need a nudge. exit 2 means the COL01 HID child had not been re-created yet (that script enumerates once, it does not retry enumeration). Make sure the Magic Mouse (PID 0323) is paired and connected, then run scripts\mm-f1-once.ps1 as admin, or let the MmAutoF1Watcher task re-send F1 on the next connect or at startup." -Level 'WARN'
    }
    $oem16 = 'C:\Windows\System32\drivers\MagicMouseDriver.sys'
    if (Test-Path -LiteralPath $oem16) {
        $h = Get-KmdfFileSha256 -Path $oem16
        Write-KmdfLog -Message "oem16 still $h" -Level 'INFO'
        if (-not $h.StartsWith('AD5D244B')) {
            Write-KmdfLog -Message 'WARNING: oem16 hash is not AD5D244B (this PC may not be the Apr 30 restore box)' -Level 'WARN'
        }
    }
}

if (-not (Test-KmdfIsAdmin) -and -not $NoElevate) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate')
    if ($SkipPnputil) { $relaunch += '-SkipPnputil' }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}
if (-not (Test-KmdfIsAdmin)) {
    # Not Fail: Write-KmdfLog/Write-KmdfResult call Initialize-KmdfDataDir themselves,
    # which would create C:\ProgramData\MagicMouseDriver as this unprivileged user - the
    # last pre-elevation creator. Neither install.log nor RESULT.txt is writable there
    # without admin anyway. Exit 1 matches Fail.
    Write-Host 'Administrator required.' -ForegroundColor Red
    exit 1
}

# Keep this AFTER the admin gate so the elevated run is the directory's creator:
# C:\ProgramData hands out CREATOR OWNER Full Control by inheritance, so a standard-user
# creator would keep write access to the scripts the watcher installer registers to run
# as SYSTEM. The ordering only removes the common path, it is not a guarantee:
# Write-KmdfLog and Write-KmdfResult in scripts\Kmdf-Common.ps1 each call
# Initialize-KmdfDataDir themselves, so any unprivileged entry point that logs before
# elevating can still create the directory first. The actual guarantee is
# scripts\mm-auto-f1-watcher-install.ps1, which takes ownership and writes a protected
# DACL on this directory before it stages either SYSTEM-executed script. Do not drop
# that hardening on the strength of this ordering.
Initialize-KmdfDataDir

Write-Host ''
Write-Host 'This installs a SELF-SIGNED kernel driver. Windows will not load it unless:' -ForegroundColor Yellow
Write-Host '  - testsigning is ON (this script can set that; reboot once)' -ForegroundColor Yellow
Write-Host '  - Secure Boot is OFF' -ForegroundColor Yellow
Write-Host '  - Settings > Privacy & security > Windows Security > Device security > Memory integrity OFF' -ForegroundColor Yellow
Write-Host 'No money, no WHQL. Private key never leaves this PC. No PFX in git.' -ForegroundColor Yellow
Write-Host ''

if (Test-KmdfSecureBootOn) {
    Fail 'Secure Boot is ON. Turn it off in firmware, then re-run. Self-signed kernel drivers will not load.'
}

$needReboot = Enable-KmdfTestSigning
$cert = Get-KmdfCommunityCert
Add-KmdfCommunitySignature -Cert $cert

if ($needReboot) {
    Write-KmdfResult -Status 'PENDING' -Detail 'testsigning enabled. Reboot, then run Setup-Community.cmd again to pnputil.'
    Write-Host 'Reboot now, then run Setup-Community.cmd again.' -ForegroundColor Yellow
    exit 3010
}

if ($SkipPnputil) {
    Write-KmdfResult -Status 'PASS' -Detail 'Signed with community cert. pnputil skipped.'
    exit 0
}

Install-KmdfCommunityPackage
if ($script:KmdfRebootRequired) {
    Write-KmdfResult -Status 'PASS' -Detail 'Community self-sign + unique pnputil + F1. Reboot required to finish (3010).'
    Write-Host 'Install succeeded. Reboot to finish.' -ForegroundColor Yellow
    exit 3010
}
Write-KmdfResult -Status 'PASS' -Detail 'Community self-sign + unique pnputil + F1. Two-finger scroll. oem16 not deleted.'
exit 0
