<#
.SYNOPSIS
Packages the Magic Mouse v3 installer kit as a release asset.

.DESCRIPTION
Stages the installer scripts, checksums and legal/security documents into a
temporary directory, generates an in-archive SHA256SUMS manifest, then writes
dist/magic-mouse-v3-fix-<Tag>-installer.zip plus a .sha256 sidecar.

The signed kernel driver (applewirelessmouse.sys) and its certificate
(MagicMouseFix.cer) are not tracked in git (see DMCA-NOTICE.md). They are
included only when a maintainer has committed them for the tag. When they are
present the driver's real SHA256 and byte length must match the
$ExpectedSha256 / $ExpectedSize constants in Install-MagicMousePatch.ps1 --
shipping a binary that contradicts our own documentation is a hard failure.

When the driver is absent this produces a scripts-only kit and reports
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

function Get-InstallerFact {
    param([string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $sha  = [regex]::Match($text, '\$ExpectedSha256\s*=\s*"([0-9A-Fa-f]{64})"')
    $size = [regex]::Match($text, '\$ExpectedSize\s*=\s*([0-9]+)')
    if (-not $sha.Success -or -not $size.Success) {
        throw "Unable to read ExpectedSha256/ExpectedSize from $Path"
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
Write-Host "  Installer expects SHA256 $($facts.Sha256) / $($facts.Size) bytes" -ForegroundColor Gray

# ============================================================================
# Optional payload: signed driver + certificate
# ============================================================================

$binarySource = $null
$certSource   = $null

foreach ($dir in @($installerDir, $patchDir)) {
    if ($null -eq $binarySource) {
        $candidate = Join-Path $dir 'applewirelessmouse.sys'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $binarySource = $candidate }
    }
    if ($null -eq $certSource) {
        $candidate = Join-Path $dir 'MagicMouseFix.cer'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $certSource = $candidate }
    }
}

$binaryIncluded = $false
if ($null -ne $binarySource) {
    $actualHash = Get-Sha256Hex -Path $binarySource
    $actualSize = (Get-Item -LiteralPath $binarySource).Length

    if ($actualHash -ne $facts.Sha256) {
        Write-Failure "SHA256 mismatch for $binarySource - expected $($facts.Sha256), got $actualHash. Refusing to publish a binary that contradicts Install-MagicMousePatch.ps1."
        exit 1
    }
    if ($actualSize -ne $facts.Size) {
        Write-Failure "Size mismatch for $binarySource - expected $($facts.Size) bytes, got $actualSize."
        exit 1
    }

    $plan += [pscustomobject]@{ Name = 'applewirelessmouse.sys' ; Source = $binarySource }
    $binaryIncluded = $true
    Write-Host "  Driver verified and included: $binarySource" -ForegroundColor Green
} else {
    Write-Host "  Driver not present in tree - building scripts-only kit" -ForegroundColor Yellow
}

if ($null -ne $certSource) {
    $plan += [pscustomobject]@{ Name = 'MagicMouseFix.cer' ; Source = $certSource }
    Write-Host "  Certificate included: $certSource" -ForegroundColor Green
} else {
    Write-Host "  Certificate not present in tree" -ForegroundColor Yellow
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
