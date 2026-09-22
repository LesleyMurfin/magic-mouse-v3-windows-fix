<#
.SYNOPSIS
Packages the Magic Mouse v3 installer kit as a release asset.

.DESCRIPTION
Builds dist/magic-mouse-v3-fix-<Tag>-installer.zip plus a .sha256 sidecar from
the tracked repository tree, and writes an in-archive SHA256SUMS manifest that
covers every packaged file.

The archive reproduces the repository layout instead of flattening it, because
Install.cmd resolves its two payload paths relative to its own folder:

    Install.cmd                              <- double-click, self-elevating
    installer\Install-MagicMousePatch.ps1    <- %HERE%installer\...
    installer\Uninstall-MagicMousePatch.ps1
    installer\SHA256SUMS.txt
    apple-driver\applewirelessmouse.sys      <- %HERE%apple-driver\...
    LICENSE, SECURITY.md, DMCA-NOTICE.md, README.txt, SHA256SUMS

A flattened kit contains every file and still breaks the one-click route, so the
layout is part of the contract, not cosmetics.

Apple's applewirelessmouse.sys is the shipped route. It is tracked in git,
unmodified and Microsoft-countersigned, so it needs no certificate and no test
signing. It is a required payload file: packaging hashes the real bytes and
refuses to publish unless they match the checksum published for
apple-driver/applewirelessmouse.sys in installer/SHA256SUMS.txt. The file on
disk and the checksum the kit publishes for it cannot disagree in a release.

MagicMouseFix.cer belongs to the legacy PatchedResigned variant only -- the
byte-patched, re-signed driver that is no longer shipped. It is therefore
OPTIONAL: a kit without it is the normal, complete Apple-route kit. When it is
staged it is packaged next to the installer, where $CertPath expects it.

Step output note: binary_included kept its name and its meaning ("the kernel
driver ships in this asset"), but it can no longer be false. The driver used to
be an untracked, out-of-band payload that might be absent, producing a
scripts-only kit; it is tracked now, so its absence is a packaging failure
rather than a publishable variant. cert_included carries the one thing that is
genuinely optional today, and driver_sha256 publishes the verified hash.

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

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Archive path of the shipped driver, and the name it is published under in
# installer/SHA256SUMS.txt -- the same string, because the kit ships the repo
# layout.
$ShippedDriverEntry = 'apple-driver/applewirelessmouse.sys'

# Byte length of the exact Apple build whose SHA256 is published in
# installer/SHA256SUMS.txt. The hash already fixes the bytes; the length is
# checked first so a truncated or substituted file is reported in bytes instead
# of as an opaque hash mismatch. Both move together if a newer Boot Camp build
# is ever shipped.
$ShippedDriverSize = 78424

# ============================================================================
# Helpers
# ============================================================================

function Write-Failure {
    param([string]$Message)

    Write-Host "::error::$Message"
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Get-Sha256Hex {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Reads one checksum out of a sha256sum -c manifest. Comment lines and the
# hashes recorded there as prose (the legacy and known-bad artifacts) never
# match, which is exactly why they are comments.
function Get-PublishedSha256 {
    param([string]$Path, [string]$Entry)

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $match = [regex]::Match($line, '^([0-9a-fA-F]{64})\s\s?(\S.*)$')
        if ($match.Success -and $match.Groups[2].Value.Trim() -eq $Entry) {
            return $match.Groups[1].Value.ToLowerInvariant()
        }
    }
    return $null
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
$driverDir    = Join-Path $patchDir 'apple-driver'
$sumsPath     = Join-Path $installerDir 'SHA256SUMS.txt'
$driverPath   = Join-Path $driverDir 'applewirelessmouse.sys'

if (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = Join-Path $RepoRoot $OutDir
}

$zipName = "magic-mouse-v3-fix-$Tag-installer.zip"

Write-Host ""
Write-Host "Packaging $zipName" -ForegroundColor Cyan
Write-Host "  RepoRoot: $RepoRoot" -ForegroundColor Gray
Write-Host "  OutDir:   $OutDir" -ForegroundColor Gray

# name inside the archive <- source on disk. Entry names use '/' so the kit
# extracts with the same layout on every tool; Windows reads them the same way.
$plan = @(
    [pscustomobject]@{ Name = 'Install.cmd'                             ; Source = (Join-Path $patchDir 'Install.cmd') }
    [pscustomobject]@{ Name = 'installer/Install-MagicMousePatch.ps1'   ; Source = (Join-Path $installerDir 'Install-MagicMousePatch.ps1') }
    [pscustomobject]@{ Name = 'installer/Uninstall-MagicMousePatch.ps1' ; Source = (Join-Path $installerDir 'Uninstall-MagicMousePatch.ps1') }
    [pscustomobject]@{ Name = 'installer/SHA256SUMS.txt'                ; Source = $sumsPath }
    [pscustomobject]@{ Name = $ShippedDriverEntry                       ; Source = $driverPath }
    [pscustomobject]@{ Name = 'LICENSE'                                 ; Source = (Join-Path $RepoRoot 'LICENSE') }
    [pscustomobject]@{ Name = 'SECURITY.md'                             ; Source = (Join-Path $RepoRoot 'SECURITY.md') }
    [pscustomobject]@{ Name = 'DMCA-NOTICE.md'                          ; Source = (Join-Path $RepoRoot 'DMCA-NOTICE.md') }
    [pscustomobject]@{ Name = 'README.txt'                              ; Source = (Join-Path $patchDir 'README.md') }
)

$missing = @($plan | Where-Object { -not (Test-Path -LiteralPath $_.Source -PathType Leaf) })
if ($missing.Count -gt 0) {
    foreach ($item in $missing) {
        Write-Failure "Required payload file not found: $($item.Source)"
    }
    exit 1
}

# ============================================================================
# The shipped driver must match the checksum the kit publishes for it
# ============================================================================

$publishedHash = Get-PublishedSha256 -Path $sumsPath -Entry $ShippedDriverEntry
if (-not $publishedHash) {
    Write-Failure "No checksum line for '$ShippedDriverEntry' in $sumsPath. The shipped driver must be published there in sha256sum -c format; refusing to publish a driver the kit makes no claim about."
    exit 1
}

$driverSize = (Get-Item -LiteralPath $driverPath).Length
if ($driverSize -ne $ShippedDriverSize) {
    Write-Failure "Size mismatch for $driverPath - expected $ShippedDriverSize bytes, got $driverSize."
    exit 1
}

$driverHash = Get-Sha256Hex -Path $driverPath
if ($driverHash -ne $publishedHash) {
    Write-Failure "SHA256 mismatch for $driverPath - $sumsPath publishes $publishedHash, the file hashes to $driverHash. Refusing to publish a driver that contradicts the checksums shipped beside it."
    exit 1
}

Write-Host "  Apple driver verified: $driverHash ($driverSize bytes)" -ForegroundColor Green
Write-Host "  Published in $($sumsPath): $ShippedDriverEntry" -ForegroundColor Gray

# ============================================================================
# Optional payload: the legacy certificate
# ============================================================================

# MagicMouseFix.cer only ever mattered to the PatchedResigned variant, which is
# not shipped. Its absence is the normal case and is not a failure. When it is
# staged it goes beside the installer, because Install-MagicMousePatch.ps1
# resolves $CertPath as Join-Path $ScriptRoot 'MagicMouseFix.cer'.
$certSource = $null
foreach ($dir in @($installerDir, $patchDir)) {
    if ($null -eq $certSource) {
        $candidate = Join-Path $dir 'MagicMouseFix.cer'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $certSource = $candidate }
    }
}

$certIncluded = $null -ne $certSource
if ($certIncluded) {
    $plan += [pscustomobject]@{ Name = 'installer/MagicMouseFix.cer' ; Source = $certSource }
    Write-Host "  Legacy certificate staged and included: $certSource" -ForegroundColor Green
} else {
    Write-Host "  No MagicMouseFix.cer staged - Apple-route kit, no certificate needed" -ForegroundColor Gray
}

# ============================================================================
# Manifest and archive
# ============================================================================

$manifest = foreach ($item in ($plan | Sort-Object -Property Name)) {
    '{0}  {1}' -f (Get-Sha256Hex -Path $item.Source), $item.Name
}

$zipPath = Join-Path $OutDir $zipName

if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# Entries are written by name rather than by zipping a staged directory: the
# name in $plan is then the literal entry path, with no dependency on how the
# host platform spells a directory separator.
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in ($plan | Sort-Object -Property Name)) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $item.Source, $item.Name,
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }

    $entry  = $archive.CreateEntry('SHA256SUMS', [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.ASCIIEncoding]::new())
    try {
        foreach ($line in $manifest) { $writer.Write($line); $writer.Write("`r`n") }
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
} finally {
    $archive.Dispose()
}

$zipPath   = (Resolve-Path -LiteralPath $zipPath).Path
$zipHash   = Get-Sha256Hex -Path $zipPath
$zipLength = (Get-Item -LiteralPath $zipPath).Length
Set-Content -LiteralPath "$zipPath.sha256" -Value ('{0}  {1}' -f $zipHash, $zipName) -Encoding ascii

Write-StepOutput -Name 'zip'             -Value $zipPath
Write-StepOutput -Name 'zip_name'        -Value $zipName
Write-StepOutput -Name 'zip_sha256'      -Value $zipHash
Write-StepOutput -Name 'binary_included' -Value 'true'
Write-StepOutput -Name 'cert_included'   -Value ($certIncluded.ToString().ToLowerInvariant())
Write-StepOutput -Name 'driver_sha256'   -Value $driverHash

Write-Host ""
Write-Host "Packaged $($plan.Count + 1) files" -ForegroundColor Cyan
($plan | Sort-Object -Property Name | Select-Object -ExpandProperty Name) + 'SHA256SUMS' |
    ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Write-Host ""
Write-Host "  zip:             $zipPath" -ForegroundColor Gray
Write-Host "  size:            $zipLength bytes" -ForegroundColor Gray
Write-Host "  sha256:          $zipHash" -ForegroundColor Gray
Write-Host "  sidecar:         $zipPath.sha256" -ForegroundColor Gray
Write-Host "  driver_sha256:   $driverHash" -ForegroundColor Gray
Write-Host "  binary_included: true" -ForegroundColor Gray
Write-Host "  cert_included:   $($certIncluded.ToString().ToLowerInvariant())" -ForegroundColor Gray
Write-Host ""

exit 0
