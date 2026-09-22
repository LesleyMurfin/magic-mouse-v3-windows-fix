<#
.SYNOPSIS
Packages the Magic Mouse v3 installer kit as a release asset.

.DESCRIPTION
Stages the installer scripts, checksums and legal/security documents into a
temporary directory, generates an in-archive SHA256SUMS manifest, then writes
dist/magic-mouse-v3-fix-<Tag>-installer.zip plus a .sha256 sidecar.

Two applewirelessmouse.sys binaries are known and each has its own rules:

  apple   Apple's unmodified driver, tracked at v1-binary-patch/apple-driver/.
          Microsoft-countersigned, so it installs with no certificate at all
          and ships on its own.
  legacy  The byte-patched copy re-signed as CN=MagicMouseFix, not tracked in
          git (see DMCA-NOTICE.md). It and MagicMouseFix.cer are one payload,
          never two options: Install-MagicMousePatch.ps1 imports the .cer into
          LocalMachine\TrustedPublisher before it copies the .sys and refuses
          to run without either, so staging exactly one of them is a hard
          failure -- a kit that carries half the payload looks complete and
          cannot install.

The kit ships exactly one driver, so staging both is refused rather than
resolved by search order, and a staged driver must hash to the triple its
location promises: apple-driver/ to the Apple constants pinned below, the
installer directory or the patch root to the $PatchedSha256 / $PatchedSize
constants in Install-MagicMousePatch.ps1. Shipping a binary that contradicts
our own documentation is a hard failure.

When no driver is staged this produces a scripts-only kit and reports
binary_included=false so the release notes can say so explicitly.

.PARAMETER Tag
Release tag, e.g. v1.0.0. Becomes part of the asset filename.

.PARAMETER RepoRoot
Repository root. Defaults to the parent of the scripts directory.

.PARAMETER OutDir
Output directory for the ZIP and sidecar. Relative paths resolve against
RepoRoot. Defaults to 'dist'.

.EXAMPLE
pwsh -File scripts/package-release.ps1 -Tag v1.0.0

.NOTES
License: MIT
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Tag,

    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================================
# Helpers
# ============================================================================

function Write-Failure {
    param([string]$Message)

    Write-Host "::error::$Message"
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# The shipped Apple driver. Install-MagicMousePatch.ps1 identifies it by Authenticode
# signer rather than by hash, so the constants of the copy this repository ships are
# pinned here; Test-ReleaseProvenance.ps1 fails if this pin drifts from the tree.
$AppleSha256 = '08f33d7e3ece2c73950a9706f1c4c9057894eaeaf1c4fb355f261f3c2333378f'
$AppleSize   = [int64]78424

function Get-InstallerFact {
    param([string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $sha  = [regex]::Match($text, '\$PatchedSha256\s*=\s*"([0-9A-Fa-f]{64})"')
    $size = [regex]::Match($text, '\$PatchedSize\s*=\s*([0-9]+)')
    if (-not $sha.Success -or -not $size.Success) {
        throw "Unable to read PatchedSha256/PatchedSize from $Path"
    }
    return [pscustomobject]@{
        Sha256 = $sha.Groups[1].Value.ToLowerInvariant()
        Size   = [int64]$size.Groups[1].Value
    }
}

function Get-Sha256Hex {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-StepOutput {
    param([string]$Name, [string]$Value)

    if (-not [string]::IsNullOrEmpty($env:GITHUB_OUTPUT)) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

# ============================================================================
# Resolve layout
# ============================================================================

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$patchDir     = Join-Path $RepoRoot 'v1-binary-patch'
$installerDir = Join-Path $patchDir 'installer'
$installerPs1 = Join-Path $installerDir 'Install-MagicMousePatch.ps1'

if (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = Join-Path $RepoRoot $OutDir
}

$zipName = "magic-mouse-v3-fix-$Tag-installer.zip"

Write-Host ""
Write-Host "Packaging $zipName" -ForegroundColor Cyan
Write-Host "  RepoRoot: $RepoRoot" -ForegroundColor Gray
Write-Host "  OutDir:   $OutDir" -ForegroundColor Gray

# name inside the archive <- source on disk
$plan = @(
    [pscustomobject]@{ Name = 'Install-MagicMousePatch.ps1'   ; Source = $installerPs1 }
    [pscustomobject]@{ Name = 'Uninstall-MagicMousePatch.ps1' ; Source = (Join-Path $installerDir 'Uninstall-MagicMousePatch.ps1') }
    [pscustomobject]@{ Name = 'SHA256SUMS.txt'                ; Source = (Join-Path $installerDir 'SHA256SUMS.txt') }
    [pscustomobject]@{ Name = 'LICENSE'                       ; Source = (Join-Path $RepoRoot 'LICENSE') }
    [pscustomobject]@{ Name = 'SECURITY.md'                   ; Source = (Join-Path $RepoRoot 'SECURITY.md') }
    [pscustomobject]@{ Name = 'DMCA-NOTICE.md'                ; Source = (Join-Path $RepoRoot 'DMCA-NOTICE.md') }
    [pscustomobject]@{ Name = 'README.txt'                    ; Source = (Join-Path $patchDir 'README.md') }
)

$missing = @($plan | Where-Object { -not (Test-Path -LiteralPath $_.Source -PathType Leaf) })
if ($missing.Count -gt 0) {
    foreach ($item in $missing) {
        Write-Failure "Required payload file not found: $($item.Source)"
    }
    exit 1
}

$facts = Get-InstallerFact -Path $installerPs1

# Where each driver may live and what it must hash to. Exactly one of these may be
# staged: the kit ships a single applewirelessmouse.sys, so a tree holding two of them
# is ambiguous and is refused rather than silently resolved by search order.
$driverSources = @(
    [pscustomobject]@{ Driver = 'apple'  ; Path = (Join-Path (Join-Path $patchDir 'apple-driver') 'applewirelessmouse.sys'); Sha256 = $AppleSha256    ; Size = $AppleSize    ; NeedsCert = $false }
    [pscustomobject]@{ Driver = 'legacy' ; Path = (Join-Path $installerDir 'applewirelessmouse.sys')                       ; Sha256 = $facts.Sha256 ; Size = $facts.Size ; NeedsCert = $true }
    [pscustomobject]@{ Driver = 'legacy' ; Path = (Join-Path $patchDir 'applewirelessmouse.sys')                           ; Sha256 = $facts.Sha256 ; Size = $facts.Size ; NeedsCert = $true }
)

Write-Host "  apple driver  SHA256 $AppleSha256 / $AppleSize bytes" -ForegroundColor Gray
Write-Host "  legacy driver SHA256 $($facts.Sha256) / $($facts.Size) bytes" -ForegroundColor Gray

# ============================================================================
# Optional payload: the driver, plus the certificate the legacy driver needs
# ============================================================================

$staged = @($driverSources | Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf })
if ($staged.Count -gt 1) {
    Write-Failure ("More than one applewirelessmouse.sys is staged: " + (($staged | ForEach-Object { "$($_.Path) ($($_.Driver))" }) -join ', ') + ". The kit ships exactly one driver; remove the copies it must not publish.")
    exit 1
}

$driver     = $staged | Select-Object -First 1
$certSource = $null
foreach ($dir in @($installerDir, $patchDir)) {
    $candidate = Join-Path $dir 'MagicMouseFix.cer'
    if ($null -eq $certSource -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $certSource = $candidate }
}

$needsCert = ($null -ne $driver) -and $driver.NeedsCert
$hasCert   = $null -ne $certSource

if ($needsCert -and -not $hasCert) {
    Write-Failure "MagicMouseFix.cer not found in $installerDir or $patchDir, but the legacy patched driver is staged at $($driver.Path). That driver and its certificate are one payload - Install-MagicMousePatch.ps1 imports the certificate before it copies the driver. Stage the certificate or remove the driver; refusing to publish half a kit."
    exit 1
}
if ($hasCert -and -not $needsCert) {
    Write-Failure "MagicMouseFix.cer is staged at $certSource, but no legacy patched driver is. That certificate exists only to trust the re-signed legacy binary - Apple's driver is Microsoft-countersigned and needs no certificate at all. Stage the legacy driver or remove the certificate; refusing to publish a file the kit cannot use."
    exit 1
}

$binaryIncluded = $null -ne $driver
if ($binaryIncluded) {
    $actualHash = Get-Sha256Hex -Path $driver.Path
    $actualSize = (Get-Item -LiteralPath $driver.Path).Length

    if ($actualHash -ne $driver.Sha256) {
        Write-Failure "SHA256 mismatch for $($driver.Path) - this location must hold the $($driver.Driver) driver $($driver.Sha256), got $actualHash. Refusing to publish a binary that contradicts our own documentation."
        exit 1
    }
    if ($actualSize -ne $driver.Size) {
        Write-Failure "Size mismatch for $($driver.Path) - the $($driver.Driver) driver is $($driver.Size) bytes, got $actualSize."
        exit 1
    }

    $plan += [pscustomobject]@{ Name = 'applewirelessmouse.sys' ; Source = $driver.Path }
    Write-Host "  Driver verified and included: $($driver.Path) ($($driver.Driver))" -ForegroundColor Green
    if ($needsCert) {
        $plan += [pscustomobject]@{ Name = 'MagicMouseFix.cer' ; Source = $certSource }
        Write-Host "  Certificate included:         $certSource" -ForegroundColor Green
    }
} else {
    Write-Host "  No driver present in tree - building scripts-only kit" -ForegroundColor Yellow
}

# ============================================================================
# Stage, manifest, compress
# ============================================================================

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('mmv3-release-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $OutDir $zipName

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    foreach ($item in $plan) {
        Copy-Item -LiteralPath $item.Source -Destination (Join-Path $staging $item.Name) -Force
    }

    $manifest = foreach ($item in ($plan | Sort-Object -Property Name)) {
        '{0}  {1}' -f (Get-Sha256Hex -Path (Join-Path $staging $item.Name)), $item.Name
    }
    Set-Content -LiteralPath (Join-Path $staging 'SHA256SUMS') -Value $manifest -Encoding ascii

    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
} finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

$zipPath   = (Resolve-Path -LiteralPath $zipPath).Path
$zipHash   = Get-Sha256Hex -Path $zipPath
$zipLength = (Get-Item -LiteralPath $zipPath).Length
Set-Content -LiteralPath "$zipPath.sha256" -Value ('{0}  {1}' -f $zipHash, $zipName) -Encoding ascii

Write-StepOutput -Name 'zip'             -Value $zipPath
Write-StepOutput -Name 'zip_name'        -Value $zipName
Write-StepOutput -Name 'zip_sha256'      -Value $zipHash
Write-StepOutput -Name 'binary_included' -Value ($binaryIncluded.ToString().ToLowerInvariant())

Write-Host ""
Write-Host "Packaged $($plan.Count + 1) files" -ForegroundColor Cyan
($plan | Sort-Object -Property Name | Select-Object -ExpandProperty Name) + 'SHA256SUMS' |
    ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host ""
Write-Host "  zip:             $zipPath" -ForegroundColor Gray
Write-Host "  size:            $zipLength bytes" -ForegroundColor Gray
Write-Host "  sha256:          $zipHash" -ForegroundColor Gray
Write-Host "  sidecar:         $zipPath.sha256" -ForegroundColor Gray
Write-Host "  binary_included: $($binaryIncluded.ToString().ToLowerInvariant())" -ForegroundColor Gray
Write-Host ""

exit 0
