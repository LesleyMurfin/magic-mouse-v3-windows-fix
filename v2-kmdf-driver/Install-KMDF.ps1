<#
.SYNOPSIS
Add the unique signed 2.0.4 scroll package with pnputil /add-driver only.

.DESCRIPTION
Requires a already-signed unique package in this folder:

  MagicMouseDriver-kmdf-204-scroll.inf
  MagicMouseDriver-kmdf-204-scroll.sys   (byte-identical to the sha8 artifact)
  MagicMouseDriver-kmdf-204-scroll.cat   (signed with thumb 16940C0F)

Does not Copy-Item onto System32\drivers or DriverStore.
Does not delete Apr 30 oem16 / MagicMouseDriver.inf.
Does not create certificates. Does not run unsigned activate.
PATH-A is refused.

.PARAMETER Uninstall
Remove only this unique package (match MagicMouseDriver-kmdf-204-scroll.inf).
Never /delete-driver the Apr 30 MagicMouseDriver.inf package.

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

# 3010 = success-with-reboot-required. Banked here and carried to the process exit code
# at the bottom so Install-KMDF.cmd and automation can tell "staged, needs a reboot"
# from plain success. Same idiom as Setup-Community.ps1.
$script:KmdfRebootRequired = $false

function Get-KmdfUniqueOemName {
    $pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
    $blocks = $pnpRaw -split '(?=Published Name:)'
    $found = @()
    foreach ($block in $blocks) {
        if ($block -notmatch 'MagicMouseDriver-kmdf-204-scroll\.inf') { continue }
        if ($block -match 'Original Name:\s+MagicMouseDriver\.inf') { continue }
        if ($block -match 'Published Name:\s+oem16\.inf') { continue }
        if ($block -match 'Published Name:\s+(oem\d+\.inf)') {
            $found += $Matches[1]
        }
    }
    return $found
}

function Uninstall-KmdfUniquePackage {
    Write-KmdfLog -Message "Removing unique 2.0.4 scroll package only. Apr 30 oem16 / MagicMouseDriver.inf is left alone." -Level 'HEAD'
    $oems = @(Get-KmdfUniqueOemName)
    if ($oems.Count -eq 0) {
        Write-KmdfLog -Message "No published MagicMouseDriver-kmdf-204-scroll.inf package found." -Level 'WARN'
        return
    }
    foreach ($oem in $oems) {
        if ($oem -match '^oem16\.inf$') {
            throw "Refusing /delete-driver oem16 (Apr 30 restore)."
        }
        Write-KmdfLog -Message "pnputil /delete-driver $oem (unique package only)" -Level 'INFO'
        # 2>$null, not 2>&1: merging a native command's stderr into the pipeline while
        # $ErrorActionPreference is 'Stop' raises a terminating NativeCommandError in
        # Windows PowerShell 5.1, which would abort this loop and report FAIL for a
        # removal that actually worked.
        & pnputil.exe /delete-driver $oem /uninstall 2>$null | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
        $rc = $LASTEXITCODE
        if ($rc -eq 3010) {
            $script:KmdfRebootRequired = $true
        }
        elseif ($rc -ne 0) {
            throw "pnputil /delete-driver $oem exited $rc"
        }
    }
}

function Install-KmdfUniquePackage {
    $inf = Join-Path $Here $script:KmdfUniqueInf
    $sys = Join-Path $Here $script:KmdfUniqueSys
    $cat = Join-Path $Here $script:KmdfUniqueCat
    $retired = Join-Path $Here $script:KmdfRetiredInf
    $liveNamed = Join-Path $Here $script:KmdfLiveSysName

    if (Test-Path -LiteralPath $retired) {
        throw "Retired $($script:KmdfRetiredInf) is in the package folder. That identity created oem26 and hardlinked over Apr 30. Use $($script:KmdfUniqueInf) only."
    }
    if (Test-Path -LiteralPath $liveNamed) {
        throw "Package folder has $($script:KmdfLiveSysName). Remove it. That name collides with Apr 30 restore."
    }
    if (-not (Test-Path -LiteralPath $inf)) { throw "Missing $inf" }
    if (-not (Test-Path -LiteralPath $sys)) { throw "Missing $sys - WDK build, then Freeze-KmdfArtifact.ps1." }
    if (-not (Test-Path -LiteralPath $cat)) { throw "Missing $cat - human must inf2cat + sign with thumb 16940C0F. No unsigned activate." }

    $infText = Get-Content -LiteralPath $inf -Raw
    if ($infText -notmatch 'CatalogFile\s*=\s*MagicMouseDriver-kmdf-204-scroll\.cat') {
        throw "INF CatalogFile is not $($script:KmdfUniqueCat)."
    }
    if ($infText -match '08/30/2026,2\.0\.4\.0' -or $infText -match '08/31/2026,2\.0\.4\.0') {
        throw "INF DriverVer collides with the failed 2.0.4 oem26 / PR #3 identity."
    }
    if ($infText -notmatch '09/17/2026,2\.0\.4\.5') {
        throw "INF DriverVer must be 09/17/2026,2.0.4.5 (unique vs oem26; newer than the installed 09/16/2026,2.0.4.4)."
    }
    if ($infText -match 'ServiceBinary\s*=\s*%12%\\MagicMouseDriver\.sys') {
        throw "INF ServiceBinary must not be MagicMouseDriver.sys (Apr 30 restore file)."
    }
    if ($infText -match '(?m)^MagicMouseDriver\.sys') {
        throw "INF CopyFiles must not be MagicMouseDriver.sys (Apr 30 restore file)."
    }
    if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') {
        throw "INF AddService must not be MagicMouseDriver (live oem16 SCM name)."
    }
    if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') {
        throw "INF AddService must be MagicMouseDriver204Scroll."
    }
    if ($infText -notmatch 'LowerFilters.*,0x00010000,"MagicMouseDriver204Scroll"') {
        throw "INF LowerFilters must be MagicMouseDriver204Scroll."
    }
    if ($infText -match 'LowerFilters.*,0x00010000,"MagicMouseDriver"(?!204Scroll)') {
        throw "INF LowerFilters must not be MagicMouseDriver (live oem16 filter)."
    }

    if (Test-KmdfForbiddenSysFile -Path $sys) {
        throw "Refusing banned .sys."
    }

    $sha = Get-KmdfFileSha256 -Path $sys
    $sums = Join-Path $Here 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sums)) {
        throw "Integrity failure: missing $sums."
    }
    $sumText = Get-Content -LiteralPath $sums -Raw
    if ($sumText -notmatch [regex]::Escape($sha)) {
        throw "Freeze-hash gate: $sys SHA256 $sha is not in SHA256SUMS.txt."
    }
    Write-KmdfLog -Message "Freeze-hash gate matched $sha" -Level 'OK'

    if (-not (Test-KmdfSignedByThumb -Path $sys -Thumb $script:KmdfSignThumb)) {
        throw "Unsigned or wrong-thumb .sys. Sign with 16940C0F. Do not run pr3-activate / copy-over."
    }
    if (-not (Test-KmdfSignedByThumb -Path $cat -Thumb $script:KmdfSignThumb)) {
        throw "Unsigned or wrong-thumb .cat. Sign with 16940C0F."
    }

    Write-KmdfLog -Message "pnputil /add-driver $inf /install (no System32 copy-over, no oem16 delete)" -Level 'HEAD'
    # 2>$null, not 2>&1: see Uninstall-KmdfUniquePackage. Under 'Stop', a merged stderr
    # line becomes a terminating NativeCommandError, so a successful 0/3010 install could
    # be reported FAIL by the outer catch without $rc ever being read.
    & pnputil.exe /add-driver $inf /install 2>$null | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        Write-KmdfResult -Status 'PASS' -Detail "pnputil added unique package. SHA256=$sha dest=$($script:KmdfUniqueSys). Apr 30 MagicMouseDriver.sys / oem16 left in place."
        return
    }
    if ($rc -eq 3010) {
        $script:KmdfRebootRequired = $true
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
        if ($script:KmdfRebootRequired) {
            Write-KmdfResult -Status 'PENDING' -Detail 'Unique 2.0.4 scroll package removed. Reboot required to finish (3010). Apr 30 oem16 / MagicMouseDriver.sys was not deleted.'
            Write-Host 'Unique package removed. Reboot to finish (3010).' -ForegroundColor Yellow
            exit 3010
        }
        Write-KmdfResult -Status 'PASS' -Detail 'Unique 2.0.4 scroll package removed. Apr 30 oem16 / MagicMouseDriver.sys was not deleted.'
        exit 0
    }
    Install-KmdfUniquePackage
    if ($script:KmdfRebootRequired) {
        Write-Host 'Unique package staged. Reboot to finish (3010).' -ForegroundColor Yellow
        exit 3010
    }
    exit 0
} catch {
    Write-KmdfLog -Message "$_" -Level 'ERROR'
    Write-KmdfResult -Status 'FAIL' -Detail "$_"
    exit 1
}
