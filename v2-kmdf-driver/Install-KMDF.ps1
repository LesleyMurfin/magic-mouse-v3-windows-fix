<#
.SYNOPSIS
Add the unique signed 2.0.4 scroll package with pnputil /add-driver only.

.DESCRIPTION
Requires an already-signed unique package in this folder:

  MagicMouseDriver-kmdf-204-scroll.inf
  MagicMouseDriver-kmdf-204-scroll.sys
  MagicMouseDriver-kmdf-204-scroll.cat

Nothing in the download is pre-signed. Setup-Community.cmd creates a signing
certificate on YOUR PC, signs the .sys/.cat with it and records its thumbprint
in C:\ProgramData\MagicMouseDriver\community-setup-state.json. This script then
accepts that certificate. Resolution order for the expected signer is
MM_KMDF_SIGN_THUMB, then the state file, then the historical maintainer cert
(see Get-KmdfExpectedThumb in scripts\Kmdf-Common.ps1).

Most users should run Setup-Community.cmd instead of this script - it does the
certificate, test signing, signing, install, multitouch enable and verify steps
in order. This script is the install step on its own.

Does not Copy-Item onto System32\drivers or DriverStore.
Does not delete Apr 30 oem16 / MagicMouseDriver.inf.
Does not create certificates. Does not run unsigned activate.
PATH-A is refused.

.PARAMETER Uninstall
Remove only this unique package (match MagicMouseDriver-kmdf-204-scroll.inf).
Never /delete-driver the Apr 30 package.

.PARAMETER NoElevate
Internal. Set when relaunched via UAC so we do not loop.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'scripts\Kmdf-Common.ps1')

function Uninstall-KmdfUniquePackage {
    Write-KmdfLog -Message "Removing unique 2.0.4 scroll package only. The Apr 30 oem16 package is left alone." -Level 'HEAD'
    $oems = @(Get-KmdfPublishedOemNames)
    if ($oems.Count -eq 0) {
        Write-KmdfLog -Message "No published MagicMouseDriver-kmdf-204-scroll.inf package found." -Level 'WARN'
        return
    }
    foreach ($oem in $oems) {
        if ($oem -match '^oem16\.inf$') {
            throw "Refusing /delete-driver oem16 (Apr 30 restore)."
        }
        Write-KmdfLog -Message "pnputil /delete-driver $oem (204-scroll unique package only)" -Level 'INFO'
        & pnputil.exe /delete-driver $oem /uninstall 2>&1 | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
    }
}

function Install-KmdfUniquePackage {
    $inf = Join-Path $Here $script:KmdfUniqueInf
    $sys = Join-Path $Here $script:KmdfUniqueSys

    # Every identity / banned-artifact / signature gate, shared with the wizard.
    $problems = @(Get-KmdfPackageProblem -Directory $Here -RequireSignature)
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-KmdfLog -Message $p -Level 'ERROR' }
        throw ($problems[0])
    }

    # Freeze-hash gate. The shipped .sys is frozen UNSIGNED; signing it locally
    # changes its hash by design, so a signed file is accepted only when this
    # PC recorded the frozen unsigned hash before signing it (state file) and
    # the signature above matched the expected certificate.
    $sha = Get-KmdfFileSha256 -Path $sys
    $sums = Join-Path $Here 'SHA256SUMS.txt'
    $known = $false
    if ($sha -eq $script:KmdfUnsignedSysSha) { $known = $true }
    if (-not $known -and (Test-Path -LiteralPath $sums)) {
        $sumText = Get-Content -LiteralPath $sums -Raw
        if ($sumText -match [regex]::Escape($sha)) { $known = $true }
    }
    if ($known) {
        Write-KmdfLog -Message "Freeze-hash gate matched $sha" -Level 'OK'
    }
    else {
        $st = Read-KmdfState
        if ($null -ne $st -and $st['driverSha256'] -eq $script:KmdfUnsignedSysSha) {
            Write-KmdfLog -Message "Freeze-hash gate: $sha is the locally signed copy of frozen $($script:KmdfUnsignedSysSha) (signature already verified)." -Level 'OK'
        }
        else {
            throw "Freeze-hash gate: $sys SHA256 $sha is not the frozen $($script:KmdfDriverVersion) binary ($($script:KmdfUnsignedSysSha)) and is not listed in SHA256SUMS.txt. Re-download the release ZIP, then run Setup-Community.cmd."
        }
    }

    Write-KmdfLog -Message "pnputil.exe /add-driver $inf /install (no System32 copy-over, no oem16 delete)" -Level 'HEAD'
    & pnputil.exe /add-driver $inf /install 2>&1 | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        Write-KmdfResult -Status 'PASS' -Detail "pnputil added unique package. SHA256=$sha dest=$($script:KmdfUniqueSys). Apr 30 MagicMouseDriver.sys / oem16 left in place."
        return
    }
    if ($rc -eq 3010) {
        Write-KmdfResult -Status 'PENDING' -Detail "pnputil 3010 reboot required. Unique package staged. Apr 30 oem16 not deleted."
        return
    }
    throw "pnputil /add-driver exited $rc"
}

if (-not (Test-KmdfIsAdmin) -and -not $NoElevate) {
    Write-Host "Administrator is required for pnputil /add-driver." -ForegroundColor Yellow
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate')
    if ($Uninstall) { $relaunch += '-Uninstall' }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}

if (-not (Test-KmdfIsAdmin)) {
    Write-Host "Administrator approval was cancelled. Nothing was installed." -ForegroundColor Red
    exit 2
}

try {
    if ($Uninstall) {
        Uninstall-KmdfUniquePackage
        Write-KmdfResult -Status 'FAIL' -Detail 'Unique 2.0.4 scroll package removed. Apr 30 oem16 / MagicMouseDriver.sys was not deleted.'
        exit 0
    }
    Install-KmdfUniquePackage
    exit 0
} catch {
    Write-KmdfLog -Message "$_" -Level 'ERROR'
    Write-KmdfResult -Status 'FAIL' -Detail "$_"
    exit 1
}
