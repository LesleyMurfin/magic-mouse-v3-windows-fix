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
    $out = & bcdedit.exe /enum '{current}' 2>&1 | Out-String
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

function Sign-KmdfCommunityPackage {
    param($Cert)
    $inf = Join-Path $Here $script:KmdfUniqueInf
    $sys = Join-Path $Here $script:KmdfUniqueSys
    $cat = Join-Path $Here $script:KmdfUniqueCat
    if (-not (Test-Path -LiteralPath $inf)) { Fail "Missing $inf" }
    if (-not (Test-Path -LiteralPath $sys)) { Fail "Missing $sys - need the unique WDK .sys, not MagicMouseDriver.sys" }
    if (Test-Path -LiteralPath (Join-Path $Here $script:KmdfLiveSysName)) {
        Fail "Package folder has MagicMouseDriver.sys - remove it. That name is Apr 30 restore."
    }
    if (Test-KmdfForbiddenSys -Path $sys) { Fail 'Refusing banned .sys' }

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

    $inf2cat = Get-Command Inf2Cat.exe -ErrorAction SilentlyContinue
    if ($inf2cat) {
        Write-KmdfLog -Message 'Inf2Cat present - building driver catalog' -Level 'INFO'
        & Inf2Cat.exe /driver:$Here /os:10_X64
        if ($LASTEXITCODE -ne 0) { Fail "Inf2Cat exited $LASTEXITCODE" }
    }
    else {
        Write-KmdfLog -Message 'Inf2Cat not found - New-FileCatalog (testsigning-only)' -Level 'WARN'
        $files = @(
            (Get-Item -LiteralPath $inf),
            (Get-Item -LiteralPath $sys)
        )
        New-FileCatalog -Path $files.FullName -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
    }
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
    $inst = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'
    & pnputil.exe /restart-device $inst 2>$null
    Start-Sleep -Seconds 3
    $f1 = Join-Path $Here 'scripts\mm-f1-once.ps1'
    if (Test-Path -LiteralPath $f1) {
        Write-KmdfLog -Message 'HidD_SetFeature F1 (MT enable; 121/-EIO is expected)' -Level 'INFO'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f1
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

Initialize-KmdfDataDir

if (-not (Test-KmdfIsAdmin) -and -not $NoElevate) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate')
    if ($SkipPnputil) { $relaunch += '-SkipPnputil' }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}
if (-not (Test-KmdfIsAdmin)) { Fail 'Administrator required.' }

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
Sign-KmdfCommunityPackage -Cert $cert

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
Write-KmdfResult -Status 'PASS' -Detail 'Community self-sign + unique pnputil + F1. Two-finger scroll. oem16 not deleted.'
exit 0
