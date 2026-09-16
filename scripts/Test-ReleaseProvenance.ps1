#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the v1 driver provenance triple is identical everywhere it is documented.

.DESCRIPTION
    The patched driver is described by three empirical constants: its SHA256, its byte
    size, and the Authenticode certificate thumbprint used to sign it. Those constants
    are hand-copied into the installer, the uninstaller, SHA256SUMS.txt, and six
    markdown documents. A single stale copy makes the security documentation lie, which
    trains users to accept a binary nobody verified.

    v1-binary-patch/installer/Install-MagicMousePatch.ps1 is the single source of truth.
    This script scrapes the triple out of it, then proves every other occurrence agrees,
    that no documenting file has silently dropped its copy, that SHA256SUMS.txt is in
    real sha256sum format, and that no signing key material is tracked in git.

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
# Extract the source-of-truth triple
# ============================================================================

$installerPath = Join-RelativePath -Root $RepoRoot -RelativePath $InstallerRelativePath
$installerText = [System.IO.File]::ReadAllText($installerPath)

$shaMatch = [regex]::Match($installerText, '(?m)^\s*\$ExpectedSha256\s*=\s*[''"]([0-9a-fA-F]{64})[''"]')
$sizeMatch = [regex]::Match($installerText, '(?m)^\s*\$ExpectedSize\s*=\s*(\d+)')
$thumbMatch = [regex]::Match($installerText, '(?m)^\s*\$CertThumbprint\s*=\s*[''"]([0-9a-fA-F]{40})[''"]')

if (-not $shaMatch.Success) {
    Add-Finding -Message 'Could not extract $ExpectedSha256 (64 hex chars) from the installer. Provenance cannot be verified.' -RelativePath $InstallerRelativePath
}
if (-not $sizeMatch.Success) {
    Add-Finding -Message 'Could not extract $ExpectedSize (integer) from the installer. Provenance cannot be verified.' -RelativePath $InstallerRelativePath
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

Write-Host "  SHA256     $expectedSha"
Write-Host "  Size       $expectedSize"
Write-Host "  Thumbprint $expectedThumb"
Write-Host ''

Add-ResultRow -Name 'source:$ExpectedSha256' -Expected '64 hex chars' -Found $expectedSha -Result 'OK'
Add-ResultRow -Name 'source:$ExpectedSize' -Expected 'integer' -Found "$expectedSize" -Result 'OK'
Add-ResultRow -Name 'source:$CertThumbprint' -Expected '40 hex chars' -Found $expectedThumb -Result 'OK'

# ============================================================================
# 1 + 2 + 5. Cross-file hex agreement and presence
# ============================================================================

$hexTargets = @(
    [PSCustomObject]@{ Path = 'README.md';                                             Sha = $true;  Thumb = $false; RequireSha = $true;  RequireThumb = $false }
    [PSCustomObject]@{ Path = 'SECURITY.md';                                           Sha = $true;  Thumb = $true;  RequireSha = $true;  RequireThumb = $true }
    [PSCustomObject]@{ Path = 'CHANGELOG.md';                                          Sha = $true;  Thumb = $true;  RequireSha = $true;  RequireThumb = $true }
    [PSCustomObject]@{ Path = 'v1-binary-patch/README.md';                             Sha = $true;  Thumb = $true;  RequireSha = $true;  RequireThumb = $true }
    [PSCustomObject]@{ Path = 'v1-binary-patch/installer/SHA256SUMS.txt';               Sha = $true;  Thumb = $false; RequireSha = $true;  RequireThumb = $false }
    [PSCustomObject]@{ Path = 'v1-binary-patch/installer/Uninstall-MagicMousePatch.ps1'; Sha = $true; Thumb = $true;  RequireSha = $false; RequireThumb = $true }
    [PSCustomObject]@{ Path = 'v1-binary-patch/docs/architecture.md';                   Sha = $false; Thumb = $true;  RequireSha = $false; RequireThumb = $false }
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
        $checks += [PSCustomObject]@{ Label = 'sha256'; Shape = $Sha256Shape; Expected = $expectedSha; Required = $target.RequireSha }
    }
    if ($target.Thumb) {
        $checks += [PSCustomObject]@{ Label = 'thumbprint'; Shape = $ThumbprintShape; Expected = $expectedThumb; Required = $target.RequireThumb }
    }

    foreach ($check in $checks) {
        $occurrences = Get-PatternOccurrence -FullPath $fullPath -Pattern $check.Shape
        $bad = 0
        foreach ($occurrence in $occurrences) {
            if ($occurrence.Value -ine $check.Expected) {
                Add-Finding -Message "$($check.Label) mismatch: found '$($occurrence.Value)' but the installer declares '$($check.Expected)'" -RelativePath $target.Path -LineNumber $occurrence.LineNumber
                $bad++
            }
        }

        $good = $occurrences.Count - $bad
        if ($check.Required -and $good -eq 0) {
            Add-Finding -Message "$($check.Label) is absent: this file must document '$($check.Expected)' and no longer does" -RelativePath $target.Path
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
        if ($cited -ne $expectedSize) {
            Add-Finding -Message "size mismatch: cites '$($hit.Value)' but the installer declares $expectedSize bytes" -RelativePath $sizeDocPath -LineNumber $hit.LineNumber
        }
        else {
            $agree++
        }
    }
    if ($agree -eq 0) {
        Add-Finding -Message "size is absent: this file must cite '$expectedSize bytes' and no longer does" -RelativePath $sizeDocPath
        Add-ResultRow -Name "$sizeDocPath [size]" -Expected "$expectedSize bytes" -Found 'no citation' -Result 'FAIL'
    }
    else {
        $result = 'OK'
        if ($agree -ne $sizeHits.Count) { $result = 'FAIL' }
        Add-ResultRow -Name "$sizeDocPath [size]" -Expected "$expectedSize bytes" -Found "$agree ok / $($sizeHits.Count - $agree) bad" -Result $result
    }
}

# ============================================================================
# 4. SHA256SUMS.txt is real sha256sum output
# ============================================================================

$sumsPath = 'v1-binary-patch/installer/SHA256SUMS.txt'
$sumsFull = Join-RelativePath -Root $RepoRoot -RelativePath $sumsPath
if (Test-Path -LiteralPath $sumsFull -PathType Leaf) {
    $sumsLineCount = 0
    $sumsBad = 0
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
        if ($entry.Groups[1].Value -ine $expectedSha) {
            Add-Finding -Message "checksum mismatch for '$($entry.Groups[2].Value)': got '$($entry.Groups[1].Value)', installer declares '$expectedSha'" -RelativePath $sumsPath -LineNumber $lineNumber
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
}

# ============================================================================
# 6. Real binary, when it happens to be present
# ============================================================================

$binaryCandidates = @(
    'v1-binary-patch/installer/applewirelessmouse.sys',
    'v1-binary-patch/applewirelessmouse.sys'
)
$binaryFound = $false
foreach ($candidate in $binaryCandidates) {
    $candidateFull = Join-RelativePath -Root $RepoRoot -RelativePath $candidate
    if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { continue }
    $binaryFound = $true

    $actualHash = (Get-FileHash -LiteralPath $candidateFull -Algorithm SHA256).Hash
    $actualSize = (Get-Item -LiteralPath $candidateFull).Length

    if ($actualHash -ine $expectedSha) {
        Add-Finding -Message "on-disk SHA256 is '$actualHash' but the installer declares '$expectedSha'" -RelativePath $candidate
        Add-ResultRow -Name "$candidate [sha256]" -Expected $expectedSha -Found $actualHash -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name "$candidate [sha256]" -Expected 'matches installer' -Found $actualHash -Result 'OK'
    }

    if ($actualSize -ne $expectedSize) {
        Add-Finding -Message "on-disk size is $actualSize bytes but the installer declares $expectedSize" -RelativePath $candidate
        Add-ResultRow -Name "$candidate [size]" -Expected "$expectedSize" -Found "$actualSize" -Result 'FAIL'
    }
    else {
        Add-ResultRow -Name "$candidate [size]" -Expected "$expectedSize" -Found "$actualSize" -Result 'OK'
    }
}

if (-not $binaryFound) {
    Write-Host 'SKIP: binary not present in tree (expected; see DMCA-NOTICE.md)'
    Write-Host '::notice::SKIP: applewirelessmouse.sys not present in tree (expected; see DMCA-NOTICE.md)'
    Add-ResultRow -Name 'applewirelessmouse.sys [on-disk]' -Expected 'hash + size verified' -Found 'not in tree' -Result 'SKIP'
}

# ============================================================================
# 7. Secret hygiene: no signing key material may ever be tracked
# ============================================================================

# Assembled from fragments so this scanner does not flag its own source.
$keyBlockPattern = '-----BEGIN ' + '(RSA |EC |OPENSSH )?' + 'PRIVATE' + ' KEY-----'
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
    Write-Host 'For provenance mismatches, Install-MagicMousePatch.ps1 is the source of truth: update the other files to match it.'
    exit 1
}

Write-Host 'PASS: driver provenance is consistent across every documenting file.'
exit 0
