<#
.SYNOPSIS
Freeze-hash gate for the 2.0.4 scroll KMDF artifact.

.DESCRIPTION
After a Windows WDK build, hash the .sys and publish:

  MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys   canonical artifact
  MagicMouseDriver-kmdf-204-scroll.sys            INF SourceDisksFiles / dest

Never writes MagicMouseDriver.sys (Apr 30 restore name).
Never Copy-Item onto System32\drivers or DriverStore.
Never ships PATH-A. Refuses Apr 30 / May 20 / failed oem26 hashes.

Does not sign. Human signs with cert thumb 16940C0F on the PC (see SIGN-AND-INSTALL.md).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SysPath,

    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'Kmdf-Common.ps1')

if (-not $OutDir) {
    $OutDir = Split-Path -Parent $Here
}

if (-not (Test-Path -LiteralPath $SysPath)) {
    throw "WDK output not found: $SysPath"
}

$full = (Resolve-Path -LiteralPath $SysPath).Path
$outFull = (Resolve-Path -LiteralPath $OutDir).Path

$sysRoot = Join-Path $env:SystemRoot 'System32\drivers'
$driverStore = Join-Path $env:SystemRoot 'System32\DriverStore'
if ($outFull.StartsWith($sysRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $outFull.StartsWith($driverStore, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Freeze output must not be System32\drivers or DriverStore."
}

if (Test-KmdfForbiddenSys -Path $full) {
    throw "Refusing to freeze a banned .sys (PATH-A / May 20 / failed 2.0.4 / Apr 30 / live name)."
}

$sha = Get-KmdfFileSha256 -Path $full
$sha8 = $sha.Substring(0, 8)
$canonical = Join-Path $outFull "MagicMouseDriver-kmdf-2.0.4-scroll-$sha8.sys"
$infPayload = Join-Path $outFull $script:KmdfUniqueSys
$sums = Join-Path $outFull 'SHA256SUMS.txt'

# Never emit the live restore filename anywhere in the package folder.
$liveCollision = Join-Path $outFull $script:KmdfLiveSysName
if (Test-Path -LiteralPath $liveCollision) {
    throw "Package folder already has $($script:KmdfLiveSysName). Remove it. That name is the Apr 30 restore file."
}

Copy-Item -LiteralPath $full -Destination $canonical -Force
if ($full -ne $infPayload) {
    Copy-Item -LiteralPath $full -Destination $infPayload -Force
}

$canonicalHash = Get-KmdfFileSha256 -Path $canonical
$payloadHash = Get-KmdfFileSha256 -Path $infPayload
if ($canonicalHash -ne $sha -or $payloadHash -ne $sha) {
    throw "Freeze copy hash mismatch."
}

$nl = [Environment]::NewLine
$sumBody = "# Freeze-hash gate for KMDF 2.0.4 scroll$nl" +
    "# Canonical: MagicMouseDriver-kmdf-2.0.4-scroll-$sha8.sys$nl" +
    "# INF dest : $($script:KmdfUniqueSys)$nl" +
    "# Do not install if SHA256 is not this value.$nl" +
    "# Banned: Apr 30 AD5D244B… / May 20 559B136A… / failed 2.0.4 845435CE…$nl" +
    "$sha  MagicMouseDriver-kmdf-2.0.4-scroll-$sha8.sys$nl" +
    "$sha  $($script:KmdfUniqueSys)$nl"
Set-Content -LiteralPath $sums -Value $sumBody -Encoding ASCII

Write-Host "Frozen SHA256=$sha" -ForegroundColor Green
Write-Host "  $canonical" -ForegroundColor Gray
Write-Host "  $infPayload" -ForegroundColor Gray
Write-Host "  $sums" -ForegroundColor Gray
Write-Host "Next: sign with cert thumb 16940C0F, inf2cat $($script:KmdfUniqueCat), pnputil /add-driver $($script:KmdfUniqueInf)" -ForegroundColor Yellow
Write-Host "Do NOT Copy-Item onto System32\drivers\$($script:KmdfLiveSysName) or DriverStore." -ForegroundColor Yellow
