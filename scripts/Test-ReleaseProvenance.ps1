#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies every documented driver provenance triple is identical everywhere it appears.

.DESCRIPTION
    This repository documents two distinct driver binaries, and a reader has to be able
    to tell them apart:

      apple   Apple's own applewirelessmouse.sys, unmodified, shipped in-tree under
              v1-binary-patch/apple-driver/ and installed as-is. Microsoft-countersigned,
              so no Test Mode. Install-MagicMousePatch.ps1 deliberately does not hash-pin
              it - Apple has shipped more than one Boot Camp build and a pin there would
              reject a legitimately signed newer copy - so the constants of the copy this
              repository actually ships are pinned in this script instead.
      legacy  The byte-patched, re-signed v1.0.0 artifact. No longer shipped, still
              documented so an existing copy can be identified.
              Install-MagicMousePatch.ps1 remains its source of truth and is scraped
              below for its SHA256, byte size and signing certificate thumbprint.

    Those constants are hand-copied into the installer, the uninstaller, SHA256SUMS.txt,
    the release scripts and six markdown documents. A single stale copy makes the
    security documentation lie, which trains users to accept a binary nobody verified.

    This script proves every occurrence names one of the two known drivers, that no
    documenting file has silently dropped its copy, that SHA256SUMS.txt is in real
    sha256sum format and publishes the shipped Apple driver's checksum under its own
    filename, that a driver present on disk hashes to the triple its location promises,
    and that no signing key material is tracked in git.

    Emits GitHub Actions error annotations for every finding. Exits 1 on any finding,
    0 when the tree is consistent.

.PARAMETER RepoRoot
    Repository root. Defaults to the directory containing the scripts/ folder; if the
    installer is not found there, parent directories are searched before failing.

.PARAMETER Quiet
    Suppress the summary table. Annotations and the binary SKIP line are always emitted.

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
$Sha256Shape = '\b[0-9a-fA-F]{64}\b'
$ThumbprintShape = '\b[0-9a-fA-F]{40}\b'

# The shipped Apple driver, pinned here because the installer identifies it by
# Authenticode signer rather than by hash (see .DESCRIPTION). Every script that has to
# recognise this binary carries the same constant, so scripts/ is one of the hex targets
# below: a stale copy in any of them is a finding like any other.
$AppleSha256 = '08F33D7E3ECE2C73950A9706F1C4C9057894EAEAF1C4FB355F261F3C2333378F'
$AppleSize = 78424

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
            $occurrences.Add([PSCustomObject]@{
                LineNumber = $lineNumber
                Value      = $match.Value
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
Write-Host "Source of truth:  $InstallerRelativePath"
Write-Host ''

# ============================================================================
# Extract the legacy triple; combine it with the pinned Apple triple
# ============================================================================

$installerPath = Join-RelativePath -Root $RepoRoot -RelativePath $InstallerRelativePath
$installerText = [System.IO.File]::ReadAllText($installerPath)

$shaMatch = [regex]::Match($installerText, '(?m)^\s*\$PatchedSha256\s*=\s*[''"]([0-9a-fA-F]{64})[''"]')
$sizeMatch = [regex]::Match($installerText, '(?m)^\s*\$PatchedSize\s*=\s*(\d+)')
$thumbMatch = [regex]::Match($installerText, '(?m)^\s*\$CertThumbprint\s*=\s*[''"]([0-9a-fA-F]{40})[''"]')

if (-not $shaMatch.Success) {
    Add-Finding -Message 'Could not extract $PatchedSha256 (64 hex chars) from the installer. Provenance cannot be verified.' -RelativePath $InstallerRelativePath
}
if (-not $sizeMatch.Success) {
    Add-Finding -Message 'Could not extract $PatchedSize (integer) from the installer. Provenance cannot be verified.' -RelativePath $InstallerRelativePath
}
if (-not $thumbMatch.Success) {
    Add-Finding -Message 'Could not extract $CertThumbprint (40 hex chars) from the installer. Provenance cannot be verified.' -RelativePath $InstallerRelativePath
}
if ($script:FindingCount -gt 0) {
    Write-Host 'FAIL: source of truth is unreadable. No further checks performed.'
    exit 1
}

$expectedSha = $shaMatch.Groups[1].Value
$expectedSize = [int]$sizeMatch.Groups[1].Value
$expectedThumb = $thumbMatch.Groups[1].Value

# Every driver this repository is allowed to name. A hex64 or a byte count anywhere in
# the tree has to be one of these; anything else is a stale copy or an unknown binary.
$drivers = @(
    [PSCustomObject]@{ Name = 'apple';  Sha256 = $AppleSha256;  Size = $AppleSize }
    [PSCustomObject]@{ Name = 'legacy'; Sha256 = $expectedSha;  Size = $expectedSize }
)
$knownSha = @($drivers | ForEach-Object { $_.Sha256 })
$knownSize = @($drivers | ForEach-Object { $_.Size })
$knownShaText = ($drivers | ForEach-Object { "$($_.Name) $($_.Sha256)" }) -join ' | '
$knownSizeText = ($drivers | ForEach-Object { "$($_.Name) $($_.Size)" }) -join ' | '

Write-Host "  apple   SHA256 $AppleSha256 / $AppleSize bytes (pinned here)"
Write-Host "  legacy  SHA256 $expectedSha / $expectedSize bytes (installer)"
Write-Host "  cert    Thumbprint $expectedThumb"
Write-Host ''

Add-ResultRow -Name 'source:$PatchedSha256' -Expected '64 hex chars' -Found $expectedSha -Result 'OK'
Add-ResultRow -Name 'source:$PatchedSize' -Expected 'integer' -Found "$expectedSize" -Result 'OK'
Add-ResultRow -Name 'source:$CertThumbprint' -Expected '40 hex chars' -Found $expectedThumb -Result 'OK'
Add-ResultRow -Name 'pinned:apple' -Expected '64 hex chars + integer' -Found "$AppleSha256 / $AppleSize" -Result 'OK'

# ============================================================================
# 1 + 2 + 5. Cross-file hex agreement and presence
# ============================================================================

# The release scripts are targets too: each pins the Apple SHA256 so it can recognise the
# shipped binary, and a pin that drifts from this one is exactly the stale copy this
# check exists to catch.
$hexTargets = @(
    [PSCustomObject]@{ Path = 'README.md';                                             Sha = $true;  Thumb = $false; RequireSha = $true;  RequireThumb = $false }
    [PSCustomObject]@{ Path = 'SECURITY.md';                                           Sha = $true;  Thumb = $true;  RequireSha = $true;  RequireThumb = $true }
    [PSCustomObject]@{ Path = 'CHANGELOG.md';                                          Sha = $true;  Thumb = $true;  RequireSha = $true;  RequireThumb = $true }
    [PSCustomObject]@{ Path = 'v1-binary-patch/README.md';                             Sha = $true;  Thumb = $true;  RequireSha = $true;  RequireThumb = $true }
    [PSCustomObject]@{ Path = 'v1-binary-patch/installer/Uninstall-MagicMousePatch.ps1'; Sha = $true; Thumb = $true;  RequireSha = $false; RequireThumb = $true }
    [PSCustomObject]@{ Path = 'v1-binary-patch/docs/architecture.md';                   Sha = $false; Thumb = $true;  RequireSha = $false; RequireThumb = $false }
    [PSCustomObject]@{ Path = 'scripts/Test-ReleaseProvenance.ps1';                     Sha = $true;  Thumb = $false; RequireSha = $true;  RequireThumb = $false }
    [PSCustomObject]@{ Path = 'scripts/package-release.ps1';                            Sha = $true;  Thumb = $false; RequireSha = $true;  RequireThumb = $false }
    [PSCustomObject]@{ Path = 'scripts/verify-release.ps1';                             Sha = $true;  Thumb = $false; RequireSha = $true;  RequireThumb = $false }
)

foreach ($target in $hexTargets) {
    $fullPath = Join-RelativePath -Root $RepoRoot -RelativePath $target.Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Add-Finding -Message "Documenting file is missing from the tree: $($target.Path)" -RelativePath $target.Path
        Add-ResultRow -Name "$($target.Path)" -Expected 'file present' -Found 'missing' -Result 'FAIL'
        continue
    }

    $checks = @()
    if ($target.Sha) {
        $checks += [PSCustomObject]@{ Label = 'sha256'; Shape = $Sha256Shape; Accepted = $knownSha; Expected = $knownShaText; Required = $target.RequireSha }
    }
    if ($target.Thumb) {
        $checks += [PSCustomObject]@{ Label = 'thumbprint'; Shape = $ThumbprintShape; Accepted = @($expectedThumb); Expected = $expectedThumb; Required = $target.RequireThumb }
    }

    foreach ($check in $checks) {
        $occurrences = Get-PatternOccurrence -FullPath $fullPath -Pattern $check.Shape
        $bad = 0
        foreach ($occurrence in $occurrences) {
            if ($check.Accepted -notcontains $occurrence.Value) {
                Add-Finding -Message "$($check.Label) names no known artifact: found '$($occurrence.Value)', expected one of $($check.Expected)" -RelativePath $target.Path -LineNumber $occurrence.LineNumber
                $bad++
            }
        }

        $good = $occurrences.Count - $bad
        if ($check.Required -and $good -eq 0) {
            Add-Finding -Message "$($check.Label) is absent: this file must document one of $($check.Expected) and no longer does" -RelativePath $target.Path
            Add-ResultRow -Name "$($target.Path) [$($check.Label)]" -Expected 'at least 1 match' -Found '0 matches' -Result 'FAIL'
            continue
        }

        $result = 'OK'
        if ($bad -gt 0) { $result = 'FAIL' }
        Add-ResultRow -Name "$($target.Path) [$($check.Label)]" -Expected 'all occurrences match' -Found "$good ok / $bad bad" -Result $result
    }
}

# ============================================================================
# 3. Byte size cited in the bug analysis
# ============================================================================

$sizeDocPath = 'v1-binary-patch/docs/bug-analysis.md'
$sizeDocFull = Join-RelativePath -Root $RepoRoot -RelativePath $sizeDocPath
if (-not (Test-Path -LiteralPath $sizeDocFull -PathType Leaf)) {
    Add-Finding -Message "Documenting file is missing from the tree: $sizeDocPath" -RelativePath $sizeDocPath
    Add-ResultRow -Name "$sizeDocPath [size]" -Expected 'file present' -Found 'missing' -Result 'FAIL'
}
else {
    # Only file-size citations are in scope. bug-analysis.md legitimately cites small
    # struct sizes ("16 bytes", "4 bytes", "560 bytes"); a kernel driver is never that
    # small, so 5-or-more-digit byte counts are the driver-size citations.
    $sizeHits = Get-PatternOccurrence -FullPath $sizeDocFull -Pattern '\b\d{5,} bytes\b'
    $agree = 0
    foreach ($hit in $sizeHits) {
        $cited = [int]([regex]::Match($hit.Value, '\d+').Value)
        if ($knownSize -notcontains $cited) {
            Add-Finding -Message "size names no known artifact: cites '$($hit.Value)', expected one of $knownSizeText" -RelativePath $sizeDocPath -LineNumber $hit.LineNumber
        }
        else {
            $agree++
        }
    }
    if ($agree -eq 0) {
        Add-Finding -Message "size is absent: this file must cite one of $knownSizeText bytes and no longer does" -RelativePath $sizeDocPath
        Add-ResultRow -Name "$sizeDocPath [size]" -Expected $knownSizeText -Found 'no citation' -Result 'FAIL'
    }
    else {
        $result = 'OK'
        if ($agree -ne $sizeHits.Count) { $result = 'FAIL' }
        Add-ResultRow -Name "$sizeDocPath [size]" -Expected $knownSizeText -Found "$agree ok / $($sizeHits.Count - $agree) bad" -Result $result
    }
}

# ============================================================================
# 4. SHA256SUMS.txt is real sha256sum output and its driver entry agrees
# ============================================================================

# This manifest is the single justified exception to file-wide hash matching. It is a
# multi-entry sha256sum file: MagicMouseFix.cer (and any future payload) legitimately
# carries a different checksum, so comparing every hex64 here to a driver hash would
# fail on a correct edit. The format is parsed structurally anyway, so the checksum is
# asserted against the entry whose filename is applewirelessmouse.sys instead. Only the
# shipped Apple driver gets a checksum line here - the legacy patched hash is recorded
# as a comment so `sha256sum -c` still passes on a tree that does not carry it - so that
# entry is bound to the Apple hash specifically, not to either-of-two.
#
# Entries are path-qualified relative to v1-binary-patch/ ("apple-driver/..."), so the
# comparison is on the basename.

$sumsPath = 'v1-binary-patch/installer/SHA256SUMS.txt'
$sumsFull = Join-RelativePath -Root $RepoRoot -RelativePath $sumsPath
$driverEntryName = 'applewirelessmouse.sys'
if (-not (Test-Path -LiteralPath $sumsFull -PathType Leaf)) {
    Add-Finding -Message "Documenting file is missing from the tree: $sumsPath" -RelativePath $sumsPath
    Add-ResultRow -Name "$sumsPath [format]" -Expected 'file present' -Found 'missing' -Result 'FAIL'
}
else {
    $sumsLineCount = 0
    $sumsBad = 0
    $driverEntryLine = 0
    $driverEntryHash = ''
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($sumsFull)) {
        $lineNumber++
        if ($line.Trim().Length -eq 0 -or $line.TrimStart().StartsWith('#')) { continue }
        $sumsLineCount++
        $entry = [regex]::Match($line, '^([0-9a-f]{64})  (\S+)$')
        if (-not $entry.Success) {
            Add-Finding -Message "malformed sha256sum line: expected '<64 lowercase hex><two spaces><filename>', got '$line'" -RelativePath $sumsPath -LineNumber $lineNumber
            $sumsBad++
            continue
        }
        if ((Split-Path -Leaf $entry.Groups[2].Value) -ine $driverEntryName) { continue }
        $driverEntryLine = $lineNumber
        $driverEntryHash = $entry.Groups[1].Value
        if ($driverEntryHash -ine $AppleSha256) {
            Add-Finding -Message "checksum mismatch for '$($entry.Groups[2].Value)': got '$driverEntryHash', the shipped Apple driver is '$AppleSha256'" -RelativePath $sumsPath -LineNumber $lineNumber
            $sumsBad++
        }
    }
    if ($sumsLineCount -eq 0) {
        Add-Finding -Message 'contains no checksum entries; every entry was blank or commented out' -RelativePath $sumsPath
        $sumsBad++
    }
    $result = 'OK'
    if ($sumsBad -gt 0) { $result = 'FAIL' }
    Add-ResultRow -Name "$sumsPath [format]" -Expected 'sha256sum format' -Found "$sumsLineCount entries / $sumsBad bad" -Result $result

    if ($driverEntryLine -eq 0) {
        Add-Finding -Message "no '$driverEntryName' entry: this manifest must publish the shipped Apple driver checksum '$AppleSha256'" -RelativePath $sumsPath
        Add-ResultRow -Name "$sumsPath [$driverEntryName]" -Expected $AppleSha256 -Found 'no entry' -Result 'FAIL'
    }
    else {
        $driverResult = 'OK'
        if ($driverEntryHash -ine $AppleSha256) { $driverResult = 'FAIL' }
        Add-ResultRow -Name "$sumsPath [$driverEntryName]" -Expected 'matches apple' -Found $driverEntryHash -Result $driverResult
    }
}

# ============================================================================
# 6. Real binary, when it happens to be present
# ============================================================================

# Each location promises a specific artifact: apple-driver/ is the shipped, unmodified
# Apple binary; the installer directory and the patch root are where a locally obtained
# legacy patched copy lands. A binary is checked against the triple its own location
# names, so a substituted file fails even though the tree knows two valid hashes.
$binaryCandidates = @(
    [PSCustomObject]@{ Path = 'v1-binary-patch/apple-driver/applewirelessmouse.sys'; Driver = 'apple' }
    [PSCustomObject]@{ Path = 'v1-binary-patch/installer/applewirelessmouse.sys';    Driver = 'legacy' }
    [PSCustomObject]@{ Path = 'v1-binary-patch/applewirelessmouse.sys';              Driver = 'legacy' }
)
$binaryFound = $false
foreach ($candidate in $binaryCandidates) {
    $candidateFull = Join-RelativePath -Root $RepoRoot -RelativePath $candidate.Path
    if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { continue }
    $binaryFound = $true

    $driver = $drivers | Where-Object { $_.Name -eq $candidate.Driver }
    $actualHash = (Get-FileHash -LiteralPath $candidateFull -Algorithm SHA256).Hash
    $actualSize = (Get-Item -LiteralPath $candidateFull).Length

    if ($actualHash -ine $driver.Sha256) {
        Add-Finding -Message "on-disk SHA256 is '$actualHash' but this path must hold the $($driver.Name) driver '$($driver.Sha256)'" -RelativePath $candidate.Path
        Add-ResultRow -Name "$($candidate.Path) [sha256]" -Expected $driver.Sha256 -Found $actualHash -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name "$($candidate.Path) [sha256]" -Expected "matches $($driver.Name)" -Found $actualHash -Result 'OK'
    }

    if ($actualSize -ne $driver.Size) {
        Add-Finding -Message "on-disk size is $actualSize bytes but the $($driver.Name) driver is $($driver.Size)" -RelativePath $candidate.Path
        Add-ResultRow -Name "$($candidate.Path) [size]" -Expected "$($driver.Size)" -Found "$actualSize" -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name "$($candidate.Path) [size]" -Expected "$($driver.Size)" -Found "$actualSize" -Result 'OK'
    }
}

if (-not $binaryFound) {
    Write-Host 'SKIP: no applewirelessmouse.sys in the tree at any known location'
    Write-Host '::notice::SKIP: no applewirelessmouse.sys in the tree at any known location (see DMCA-NOTICE.md)'
    Add-ResultRow -Name 'applewirelessmouse.sys [on-disk]' -Expected 'hash + size verified' -Found 'not in tree' -Result 'SKIP'
}

# ============================================================================
# 7. Secret hygiene: no signing key material may ever be tracked
# ============================================================================

# Assembled from fragments so this scanner does not flag its own source.
$keyBlockPattern = '-----BEGIN ' + '(RSA |DSA |EC |OPENSSH |ENCRYPTED )?' + 'PRIVATE' + ' KEY-----'
$forbiddenExtensions = @('.pfx', '.p12', '.snk', '.key')
$skipExtensions = @(
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.bmp', '.pdf',
    '.sys', '.cer', '.exe', '.dll', '.pdb', '.zip', '.gz', '.7z',
    '.woff', '.woff2', '.ttf', '.otf', '.mp4', '.webm'
)

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
        if ($skipExtensions -contains $extension) { continue }

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
    Write-Host 'For legacy-driver mismatches, Install-MagicMousePatch.ps1 is the source of truth; for the shipped Apple driver, the $AppleSha256 / $AppleSize pin at the top of this script is. Update the other files to match.'
    exit 1
}

Write-Host 'PASS: driver provenance is consistent across every documenting file.'
exit 0
