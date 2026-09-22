#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that every documented driver constant agrees with the artifact it describes.

.DESCRIPTION
    This repository documents two different driver binaries, and confusing them is the
    exact failure this check exists to prevent:

      shipped  Apple's UNMODIFIED applewirelessmouse.sys, tracked at
               v1-binary-patch/apple-driver/applewirelessmouse.sys. This is the default
               install route. It needs no test signing and no certificate. Its truth is
               the bytes on disk: this script hashes the real file.

      legacy   The byte-patched copy re-signed as CN=MagicMouseFix. No longer shipped,
               still documented, still installable from an existing copy. Its truth is
               the $PatchedSha256 / $PatchedSize / $CertThumbprint triple declared in
               v1-binary-patch/installer/Install-MagicMousePatch.ps1.

    The installer deliberately does NOT hash-pin Apple's binary at runtime: Apple has
    shipped more than one Boot Camp build, so the installer identifies the Apple variant
    by Authenticode status, signer subject and PE OriginalFilename. That is the correct
    runtime model and this script does not second-guess it. Release provenance is a
    different question: the repository ships one specific copy of that binary, so the
    shipped copy IS hash-verifiable here, which is strictly stronger than scraping a
    constant out of a script.

    This script proves that:
      * the tracked .sys is present, and hashes to the pinned release artifact;
      * the legacy triple is still declared in the installer;
      * every 64-hex string and 40-hex thumbprint in every documenting file belongs to
        a known subject, so no file carries a stale or invented constant;
      * every byte-count citation belongs to a known subject;
      * no documenting constant has silently vanished from the tree;
      * SHA256SUMS.txt is real sha256sum output and publishes the shipped checksum
        under apple-driver/applewirelessmouse.sys;
      * no signing key material is tracked in git.

    Emits GitHub Actions error annotations for every finding. Exits 1 on any finding,
    0 when the tree is consistent.

.PARAMETER RepoRoot
    Repository root. Defaults to the directory containing the scripts/ folder; if the
    installer is not found there, parent directories are searched before failing.

.PARAMETER Quiet
    Suppress the summary table. Annotations are always emitted.

.EXAMPLE
    pwsh -File scripts/Test-ReleaseProvenance.ps1

.EXAMPLE
    pwsh -File scripts/Test-ReleaseProvenance.ps1 -RepoRoot . -Quiet
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Quiet
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:FindingCount = 0
$script:ResultRows = New-Object 'System.Collections.Generic.List[object]'

$InstallerRelativePath = 'v1-binary-patch/installer/Install-MagicMousePatch.ps1'
$ShippedRelativePath = 'v1-binary-patch/apple-driver/applewirelessmouse.sys'
$SumsRelativePath = 'v1-binary-patch/installer/SHA256SUMS.txt'
$SelfRelativePath = 'scripts/Test-ReleaseProvenance.ps1'

# The release artifact this repository ships. The tracked .sys must hash to exactly
# this; the pin is what turns "some Apple driver" into "the reviewed Apple driver".
$ShippedPinnedSha256 = '08f33d7e3ece2c73950a9706f1c4c9057894eaeaf1c4fb355f261f3c2333378f'
$ShippedPinnedSize = 78424

# The legacy artifact's expected byte size. The hash and thumbprint are scraped from
# the installer (it is their source of truth); the size is pinned here as well so that
# a silent edit of $PatchedSize cannot quietly relabel every document at once.
$LegacyPinnedSize = 66288

# SHA256SUMS.txt records this hash on purpose, as a comment, under "KNOWN BAD": it is
# the patched-but-never-re-signed binary whose Authenticode reports HashMismatch and
# which the installer refuses. It belongs to no shipped subject, so the generic
# "unknown hash" rule would flag it. Documenting a rejected value is how a user
# recognises the bad copy they already have, so it is allowlisted repository-wide
# rather than being silently deleted from the manifest.
$KnownBadSha256 = @(
    'd22eb163d03a0830ee4ed9c9265044cdd4099974412fa62f4c249bef971129ec'
)

$Sha256Shape = '\b[0-9a-fA-F]{64}\b'
$ThumbprintShape = '\b[0-9a-fA-F]{40}\b'

# Byte counts are only in scope when the document actually calls them bytes. The docs
# legitimately cite small struct sizes ("16 bytes") and version numbers, so the pattern
# anchors on the word and accepts both the grouped ("78,424 bytes") and plain
# ("66288 bytes") spellings that the tree uses today.
$SizeShape = '(?i)\b(\d{1,3}(?:,\d{3})+|\d{5,})\s?bytes\b'

# Binary and opaque payloads: never scanned for constants or key blocks.
$BinaryExtensions = @(
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.bmp', '.pdf',
    '.sys', '.cer', '.exe', '.dll', '.pdb', '.zip', '.gz', '.7z',
    '.woff', '.woff2', '.ttf', '.otf', '.mp4', '.webm'
)

# ============================================================================
# Helpers
# ============================================================================

function Join-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $full = $Root
    foreach ($segment in ($RelativePath -split '/')) {
        if ($segment.Length -gt 0) {
            $full = Join-Path -Path $full -ChildPath $segment
        }
    }
    return $full
}

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$RelativePath = '',
        [int]$LineNumber = 0
    )
    $annotation = '::error'
    if ($RelativePath.Length -gt 0) {
        $annotation += " file=$RelativePath"
        if ($LineNumber -gt 0) {
            $annotation += ",line=$LineNumber"
        }
    }
    Write-Host "$annotation::$Message"
    $script:FindingCount++
}

function Add-ResultRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Found,
        [Parameter(Mandatory = $true)][string]$Result
    )
    $script:ResultRows.Add([PSCustomObject]@{
        Name     = $Name
        Expected = $Expected
        Found    = $Found
        Result   = $Result
    })
}

function Get-PatternOccurrence {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    $occurrences = New-Object 'System.Collections.Generic.List[object]'
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($FullPath)) {
        $lineNumber++
        foreach ($match in [regex]::Matches($line, $Pattern)) {
            $capture = $match.Value
            if ($match.Groups.Count -gt 1 -and $match.Groups[1].Success) {
                $capture = $match.Groups[1].Value
            }
            $occurrences.Add([PSCustomObject]@{
                LineNumber = $lineNumber
                Value      = $match.Value
                Capture    = $capture
            })
        }
    }
    return , $occurrences
}

function Write-ResultTable {
    param([Parameter(Mandatory = $true)][object[]]$Row)

    $headers = @('Name', 'Expected', 'Found', 'Result')
    $widths = @($headers[0].Length, $headers[1].Length, $headers[2].Length, $headers[3].Length)
    foreach ($item in $Row) {
        if ($item.Name.Length     -gt $widths[0]) { $widths[0] = $item.Name.Length }
        if ($item.Expected.Length -gt $widths[1]) { $widths[1] = $item.Expected.Length }
        if ($item.Found.Length    -gt $widths[2]) { $widths[2] = $item.Found.Length }
        if ($item.Result.Length   -gt $widths[3]) { $widths[3] = $item.Result.Length }
    }

    $format = "{0,-$($widths[0])}  {1,-$($widths[1])}  {2,-$($widths[2])}  {3,-$($widths[3])}"
    Write-Host ($format -f $headers[0], $headers[1], $headers[2], $headers[3])
    Write-Host ($format -f ('-' * $widths[0]), ('-' * $widths[1]), ('-' * $widths[2]), ('-' * $widths[3]))
    foreach ($item in $Row) {
        Write-Host ($format -f $item.Name, $item.Expected, $item.Found, $item.Result)
    }
}

# ============================================================================
# Locate the repository root
# ============================================================================

$resolvedRoot = ''
$probe = $RepoRoot
for ($depth = 0; $depth -lt 4; $depth++) {
    if ($null -eq $probe -or $probe.Length -eq 0) { break }
    if (Test-Path -LiteralPath (Join-RelativePath -Root $probe -RelativePath $InstallerRelativePath) -PathType Leaf) {
        $resolvedRoot = (Resolve-Path -LiteralPath $probe).Path
        break
    }
    $probe = Split-Path -Parent $probe
}

if ($resolvedRoot.Length -eq 0) {
    Add-Finding -Message "Cannot locate $InstallerRelativePath at or above '$RepoRoot'. Pass -RepoRoot explicitly."
    exit 1
}
$RepoRoot = $resolvedRoot

Write-Host "Provenance check: $RepoRoot"
Write-Host ''

# ============================================================================
# Subject 'shipped': the tracked Apple binary. Truth = the bytes on disk.
# ============================================================================

$shippedSha = $ShippedPinnedSha256
$shippedSize = $ShippedPinnedSize
$shippedOnDisk = $false

$shippedFull = Join-RelativePath -Root $RepoRoot -RelativePath $ShippedRelativePath
if (-not (Test-Path -LiteralPath $shippedFull -PathType Leaf)) {
    # A finding, not a crash: the rest of the tree is still worth checking, and the
    # pinned values stand in so documents can still be classified.
    Add-Finding -Message "Shipped driver is missing from the tree. The Apple install route cannot work without it; expected SHA256 $ShippedPinnedSha256, $ShippedPinnedSize bytes." -RelativePath $ShippedRelativePath
    Add-ResultRow -Name 'shipped [on-disk]' -Expected 'file present' -Found 'missing' -Result 'FAIL'
}
else {
    $shippedOnDisk = $true
    $actualSha = (Get-FileHash -LiteralPath $shippedFull -Algorithm SHA256).Hash
    $actualSize = (Get-Item -LiteralPath $shippedFull).Length
    $shippedSha = $actualSha
    $shippedSize = [int]$actualSize

    if ($actualSha -ine $ShippedPinnedSha256) {
        Add-Finding -Message "Shipped driver hashes to '$actualSha' but the pinned release artifact is '$ShippedPinnedSha256'. Either the binary was swapped or the pin is stale; resolve deliberately." -RelativePath $ShippedRelativePath
        Add-ResultRow -Name 'shipped [sha256]' -Expected $ShippedPinnedSha256 -Found $actualSha -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name 'shipped [sha256]' -Expected 'matches pinned artifact' -Found $actualSha -Result 'OK'
    }

    if ($shippedSize -ne $ShippedPinnedSize) {
        Add-Finding -Message "Shipped driver is $shippedSize bytes but the pinned release artifact is $ShippedPinnedSize bytes." -RelativePath $ShippedRelativePath
        Add-ResultRow -Name 'shipped [size]' -Expected "$ShippedPinnedSize" -Found "$shippedSize" -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name 'shipped [size]' -Expected "$ShippedPinnedSize" -Found "$shippedSize" -Result 'OK'
    }
}

# ============================================================================
# Subject 'legacy': the patched + re-signed copy. Truth = the installer constants.
# ============================================================================

$installerPath = Join-RelativePath -Root $RepoRoot -RelativePath $InstallerRelativePath
$installerText = [System.IO.File]::ReadAllText($installerPath)

$legacyShaMatch = [regex]::Match($installerText, '(?m)^\s*\$PatchedSha256\s*=\s*[''"]([0-9a-fA-F]{64})[''"]')
$legacySizeMatch = [regex]::Match($installerText, '(?m)^\s*\$PatchedSize\s*=\s*(\d+)')
$legacyThumbMatch = [regex]::Match($installerText, '(?m)^\s*\$CertThumbprint\s*=\s*[''"]([0-9a-fA-F]{40})[''"]')

$legacyResolved = $true
if (-not $legacyShaMatch.Success) {
    Add-Finding -Message 'Could not extract $PatchedSha256 (64 hex chars) from the installer. The legacy driver is still documented; its source of truth must stay declared here.' -RelativePath $InstallerRelativePath
    $legacyResolved = $false
}
if (-not $legacySizeMatch.Success) {
    Add-Finding -Message 'Could not extract $PatchedSize (integer) from the installer. The legacy driver is still documented; its source of truth must stay declared here.' -RelativePath $InstallerRelativePath
    $legacyResolved = $false
}
if (-not $legacyThumbMatch.Success) {
    Add-Finding -Message 'Could not extract $CertThumbprint (40 hex chars) from the installer. The legacy driver is still documented; its source of truth must stay declared here.' -RelativePath $InstallerRelativePath
    $legacyResolved = $false
}

$legacySha = ''
$legacySize = 0
$legacyThumb = ''
if ($legacyResolved) {
    $legacySha = $legacyShaMatch.Groups[1].Value
    $legacySize = [int]$legacySizeMatch.Groups[1].Value
    $legacyThumb = $legacyThumbMatch.Groups[1].Value

    Add-ResultRow -Name 'legacy [sha256]' -Expected 'declared in installer' -Found $legacySha -Result 'OK'
    Add-ResultRow -Name 'legacy [thumbprint]' -Expected 'declared in installer' -Found $legacyThumb -Result 'OK'

    if ($legacySize -ne $LegacyPinnedSize) {
        Add-Finding -Message "Installer declares `$PatchedSize = $legacySize but the legacy artifact is $LegacyPinnedSize bytes." -RelativePath $InstallerRelativePath
        Add-ResultRow -Name 'legacy [size]' -Expected "$LegacyPinnedSize" -Found "$legacySize" -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name 'legacy [size]' -Expected "$LegacyPinnedSize" -Found "$legacySize" -Result 'OK'
    }
}
else {
    Add-ResultRow -Name 'legacy [triple]' -Expected 'declared in installer' -Found 'unreadable' -Result 'FAIL'
}

Write-Host 'Subjects'
Write-Host "  shipped  SHA256 $shippedSha  size $shippedSize  $(if ($shippedOnDisk) { 'hashed on disk' } else { 'pinned (binary absent)' })"
if ($legacyResolved) {
    Write-Host "  legacy   SHA256 $legacySha  size $legacySize  thumbprint $legacyThumb"
}
else {
    Write-Host '  legacy   UNREADABLE'
}
Write-Host ''

# ============================================================================
# Discover the documenting files
# ============================================================================

# Discovered, never hard-coded: a stale list silently stops covering files that were
# added after it was written. docs/ is the generated GitHub Pages site and is out of
# scope for this pull request's provenance model; .git/ is never a document; and this
# script is skipped because it necessarily contains the constants and the known-bad
# allowlist itself.
$trackedFiles = @()
$gitUsable = $false
try {
    $gitOutput = & git -C $RepoRoot ls-files 2>$null
    if ($LASTEXITCODE -eq 0) {
        $trackedFiles = @($gitOutput | Where-Object { $_.Length -gt 0 })
        $gitUsable = $true
    }
}
catch {
    Write-Host "NOTE: git ls-files unavailable ($($_.Exception.Message))"
}

$documentCandidates = @()
foreach ($tracked in $trackedFiles) {
    if ($tracked -eq $SelfRelativePath) { continue }
    if ($tracked -like 'docs/*') { continue }
    $extension = [System.IO.Path]::GetExtension($tracked).ToLowerInvariant()
    if ($BinaryExtensions -contains $extension) { continue }
    $candidateFull = Join-RelativePath -Root $RepoRoot -RelativePath $tracked
    if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { continue }
    $documentCandidates += $tracked
}

# ============================================================================
# Classify every constant-shaped string in every documenting file
# ============================================================================

$constantCarriers = 0
$shippedShaMentions = 0
$legacyShaMentions = 0
$shippedSizeMentions = 0
$legacySizeMentions = 0
$legacyThumbMentions = 0

if (-not $gitUsable) {
    Write-Host 'SKIP: git ls-files unavailable, documenting files could not be discovered'
    Write-Host '::notice::SKIP: git ls-files unavailable, documenting files could not be discovered'
    Add-ResultRow -Name 'documenting files' -Expected 'discovered via git' -Found 'git unavailable' -Result 'SKIP'
}
elseif (-not $legacyResolved) {
    # Without the legacy triple, every legacy citation in the tree would be reported as
    # an unknown constant. That is noise on top of a already-reported root cause.
    Write-Host 'SKIP: legacy triple unreadable, cross-file constant classification not performed'
    Add-ResultRow -Name 'documenting files' -Expected 'all constants known' -Found 'legacy truth missing' -Result 'SKIP'
}
else {
    foreach ($relative in $documentCandidates) {
        $fullPath = Join-RelativePath -Root $RepoRoot -RelativePath $relative

        # SHA256SUMS.txt is a multi-entry sha256sum manifest: MagicMouseFix.cer and any
        # future payload legitimately carry their own checksums, so its well-formed
        # checksum lines are verified structurally below (by filename) instead of being
        # compared to a driver hash here. Its comment lines stay in scope, because a
        # hash quoted in prose can only be a driver hash.
        $structuralLines = @{}
        if ($relative -eq $SumsRelativePath) {
            $sumsLineNumber = 0
            foreach ($line in [System.IO.File]::ReadAllLines($fullPath)) {
                $sumsLineNumber++
                if ([regex]::IsMatch($line, '^[0-9a-f]{64}  \S+$')) {
                    $structuralLines[$sumsLineNumber] = $true
                }
            }
        }

        $fileShipped = 0
        $fileLegacy = 0
        $fileKnownBad = 0
        $fileUnknown = 0

        foreach ($occurrence in (Get-PatternOccurrence -FullPath $fullPath -Pattern $Sha256Shape)) {
            if ($structuralLines.ContainsKey($occurrence.LineNumber)) { continue }
            if ($occurrence.Value -ieq $shippedSha) {
                $fileShipped++
                $shippedShaMentions++
            }
            elseif ($occurrence.Value -ieq $legacySha) {
                $fileLegacy++
                $legacyShaMentions++
            }
            elseif ($KnownBadSha256 -contains $occurrence.Value.ToLowerInvariant()) {
                $fileKnownBad++
            }
            else {
                Add-Finding -Message "unknown driver hash '$($occurrence.Value)': it is neither the shipped Apple driver ($shippedSha) nor the legacy patched driver ($legacySha)" -RelativePath $relative -LineNumber $occurrence.LineNumber
                $fileUnknown++
            }
        }

        # GitHub Actions pins reusable actions by 40-hex commit SHA, which is exactly the
        # shape of a certificate thumbprint. Workflow files are therefore scanned for
        # driver hashes but not for thumbprints.
        $extension = [System.IO.Path]::GetExtension($relative).ToLowerInvariant()
        if ($extension -ne '.yml' -and $extension -ne '.yaml') {
            foreach ($occurrence in (Get-PatternOccurrence -FullPath $fullPath -Pattern $ThumbprintShape)) {
                if ($occurrence.Value -ieq $legacyThumb) {
                    $fileLegacy++
                    $legacyThumbMentions++
                }
                else {
                    Add-Finding -Message "unknown certificate thumbprint '$($occurrence.Value)': the only signing certificate this project documents is $legacyThumb (CN=MagicMouseFix, legacy route)" -RelativePath $relative -LineNumber $occurrence.LineNumber
                    $fileUnknown++
                }
            }
        }

        foreach ($occurrence in (Get-PatternOccurrence -FullPath $fullPath -Pattern $SizeShape)) {
            $cited = [int]($occurrence.Capture -replace ',', '')
            if ($cited -eq $shippedSize) {
                $fileShipped++
                $shippedSizeMentions++
            }
            elseif ($cited -eq $legacySize) {
                $fileLegacy++
                $legacySizeMentions++
            }
            else {
                Add-Finding -Message "unknown driver size '$($occurrence.Value)': it is neither the shipped Apple driver ($shippedSize bytes) nor the legacy patched driver ($legacySize bytes)" -RelativePath $relative -LineNumber $occurrence.LineNumber
                $fileUnknown++
            }
        }

        $total = $fileShipped + $fileLegacy + $fileKnownBad + $fileUnknown
        if ($total -eq 0) { continue }
        $constantCarriers++

        $result = 'OK'
        if ($fileUnknown -gt 0) { $result = 'FAIL' }
        $found = "$fileShipped shipped / $fileLegacy legacy"
        if ($fileKnownBad -gt 0) { $found += " / $fileKnownBad known-bad" }
        if ($fileUnknown -gt 0) { $found += " / $fileUnknown unknown" }
        Add-ResultRow -Name "$relative [constants]" -Expected 'known subjects only' -Found $found -Result $result
    }

    # A scan that matched nothing would otherwise pass silently, which is the one way
    # this check can lie: it would report a clean tree while verifying nothing at all.
    if ($constantCarriers -eq 0) {
        Add-Finding -Message "No documenting file carries a provenance constant. $($documentCandidates.Count) file(s) were scanned; either discovery broke or the documentation lost its constants wholesale."
        Add-ResultRow -Name 'documenting files' -Expected 'at least 1 carrier' -Found "0 of $($documentCandidates.Count) scanned" -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name 'documenting files' -Expected 'at least 1 carrier' -Found "$constantCarriers of $($documentCandidates.Count) scanned" -Result 'OK'
    }

    # Presence: a document that silently drops its copy of a constant is as bad as one
    # that carries a stale copy, and a pure "all occurrences agree" rule cannot see it.
    # The installer's own declarations are excluded so the legacy triple cannot satisfy
    # this check by quoting itself.
    $presenceChecks = @(
        [PSCustomObject]@{ Label = 'shipped sha256';    Count = $shippedShaMentions;  Value = $shippedSha }
        [PSCustomObject]@{ Label = 'shipped size';      Count = $shippedSizeMentions; Value = "$shippedSize bytes" }
        [PSCustomObject]@{ Label = 'legacy sha256';     Count = $legacyShaMentions;   Value = $legacySha }
        [PSCustomObject]@{ Label = 'legacy size';       Count = $legacySizeMentions;  Value = "$legacySize bytes" }
        [PSCustomObject]@{ Label = 'legacy thumbprint'; Count = $legacyThumbMentions; Value = $legacyThumb }
    )
    foreach ($presence in $presenceChecks) {
        if ($presence.Count -eq 0) {
            Add-Finding -Message "$($presence.Label) is documented nowhere in the tree: '$($presence.Value)' must remain verifiable by a reader and no longer appears."
            Add-ResultRow -Name "documented:$($presence.Label)" -Expected 'at least 1 mention' -Found '0 mentions' -Result 'FAIL'
        }
        else {
            Add-ResultRow -Name "documented:$($presence.Label)" -Expected 'at least 1 mention' -Found "$($presence.Count) mentions" -Result 'OK'
        }
    }
}

# ============================================================================
# SHA256SUMS.txt is real sha256sum output and publishes the shipped checksum
# ============================================================================

$sumsFull = Join-RelativePath -Root $RepoRoot -RelativePath $SumsRelativePath
$shippedEntryName = 'apple-driver/applewirelessmouse.sys'
if (-not (Test-Path -LiteralPath $sumsFull -PathType Leaf)) {
    Add-Finding -Message "Checksum manifest is missing from the tree: $SumsRelativePath" -RelativePath $SumsRelativePath
    Add-ResultRow -Name "$SumsRelativePath [format]" -Expected 'file present' -Found 'missing' -Result 'FAIL'
}
else {
    $sumsLineCount = 0
    $sumsBad = 0
    $shippedEntryLine = 0
    $shippedEntryHash = ''
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($sumsFull)) {
        $lineNumber++
        if ($line.Trim().Length -eq 0 -or $line.TrimStart().StartsWith('#')) { continue }
        $sumsLineCount++
        $entry = [regex]::Match($line, '^([0-9a-f]{64})  (\S+)$')
        if (-not $entry.Success) {
            Add-Finding -Message "malformed sha256sum line: expected '<64 lowercase hex><two spaces><path>', got '$line'" -RelativePath $SumsRelativePath -LineNumber $lineNumber
            $sumsBad++
            continue
        }
        if ($entry.Groups[2].Value -ine $shippedEntryName) { continue }
        $shippedEntryLine = $lineNumber
        $shippedEntryHash = $entry.Groups[1].Value
        if ($shippedEntryHash -ine $shippedSha) {
            Add-Finding -Message "checksum mismatch for '$shippedEntryName': manifest says '$shippedEntryHash', the tracked binary hashes to '$shippedSha'" -RelativePath $SumsRelativePath -LineNumber $lineNumber
            $sumsBad++
        }
    }
    if ($sumsLineCount -eq 0) {
        Add-Finding -Message 'contains no checksum entries; every line was blank or commented out, so `sha256sum -c` verifies nothing' -RelativePath $SumsRelativePath
        $sumsBad++
    }
    $result = 'OK'
    if ($sumsBad -gt 0) { $result = 'FAIL' }
    Add-ResultRow -Name "$SumsRelativePath [format]" -Expected 'sha256sum format' -Found "$sumsLineCount entries / $sumsBad bad" -Result $result

    if ($shippedEntryLine -eq 0) {
        Add-Finding -Message "no '$shippedEntryName' entry: this manifest must publish the shipped driver checksum '$shippedSha'" -RelativePath $SumsRelativePath
        Add-ResultRow -Name "$SumsRelativePath [$shippedEntryName]" -Expected $shippedSha -Found 'no entry' -Result 'FAIL'
    }
    else {
        $entryResult = 'OK'
        if ($shippedEntryHash -ine $shippedSha) { $entryResult = 'FAIL' }
        Add-ResultRow -Name "$SumsRelativePath [$shippedEntryName]" -Expected 'matches tracked binary' -Found $shippedEntryHash -Result $entryResult
    }
}

# ============================================================================
# Secret hygiene: no signing key material may ever be tracked
# ============================================================================

# Assembled from fragments so this scanner does not flag its own source.
$keyBlockPattern = '-----BEGIN ' + '(RSA |DSA |EC |OPENSSH |ENCRYPTED )?' + 'PRIVATE' + ' KEY-----'
# .cer is a public certificate and is allowed; .pfx/.p12/.snk/.key carry private keys.
$forbiddenExtensions = @('.pfx', '.p12', '.snk', '.key')

if (-not $gitUsable) {
    Write-Host 'SKIP: git ls-files unavailable, secret hygiene gate not enforced'
    Write-Host '::notice::SKIP: git ls-files unavailable, secret hygiene gate not enforced'
    Add-ResultRow -Name 'secret hygiene' -Expected 'no tracked key material' -Found 'git unavailable' -Result 'SKIP'
}
else {
    $secretHits = 0
    foreach ($tracked in $trackedFiles) {
        $extension = [System.IO.Path]::GetExtension($tracked).ToLowerInvariant()
        if ($forbiddenExtensions -contains $extension) {
            Add-Finding -Message "tracked key material: '$extension' files must never be committed (this project signs kernel drivers)" -RelativePath $tracked
            $secretHits++
            continue
        }
        if ($BinaryExtensions -contains $extension) { continue }

        $trackedFull = Join-RelativePath -Root $RepoRoot -RelativePath $tracked
        if (-not (Test-Path -LiteralPath $trackedFull -PathType Leaf)) { continue }
        if ([regex]::IsMatch([System.IO.File]::ReadAllText($trackedFull), $keyBlockPattern)) {
            Add-Finding -Message 'tracked private key block detected; rotate the key and purge it from history' -RelativePath $tracked
            $secretHits++
        }
    }
    $result = 'OK'
    if ($secretHits -gt 0) { $result = 'FAIL' }
    Add-ResultRow -Name 'secret hygiene' -Expected 'no tracked key material' -Found "$($trackedFiles.Count) files / $secretHits hits" -Result $result
}

# ============================================================================
# Summary
# ============================================================================

if (-not $Quiet) {
    Write-Host ''
    Write-ResultTable -Row $script:ResultRows.ToArray()
}

Write-Host ''
if ($script:FindingCount -gt 0) {
    Write-Host "FAIL: $($script:FindingCount) finding(s); see the annotations above."
    Write-Host 'Truth for the shipped Apple driver is the tracked binary itself; truth for the legacy patched driver is Install-MagicMousePatch.ps1. Update the documents to match, never the other way around.'
    exit 1
}

Write-Host 'PASS: every documented constant agrees with the artifact it describes.'
exit 0
