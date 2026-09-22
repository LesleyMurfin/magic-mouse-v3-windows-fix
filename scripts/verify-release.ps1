<#
.SYNOPSIS
Verifies a packaged Magic Mouse v3 installer kit before it is published.

.DESCRIPTION
Runs a numbered check list against the release asset produced by
scripts/package-release.ps1 and accumulates failures instead of bailing on the
first one, so a single run reports every defect:

  1. Asset exists and is non-empty.
  2. Published .sha256 sidecar matches the asset's real hash.
  3. Required ship files exist in the archive.
  4. README.txt is present and non-empty.
  5. In-archive SHA256SUMS covers every packaged file with matching hashes.
  6. Packaged Install-MagicMousePatch.ps1 parses as valid PowerShell.
  7. Repo tree passes the provenance invariant (Test-ReleaseProvenance.ps1).
  8. Packaged installer's legacy constants equal the repo installer's.
  9. Packaged SHA256SUMS.txt, README.txt and SECURITY.md agree with what the
     archive actually ships.
 10. One-click layout: every %HERE%-relative path Install.cmd resolves exists
     in the archive at exactly that path.
 11. Shipped driver is Apple's expected binary, byte for byte.
 12. Shipped driver is an AMD64 PE image.
 13. MagicMouseFix.cer, if shipped at all, matches $CertThumbprint.
 14. Asset filename carries the release tag.

Two provenance subjects exist and are checked against different sources of
truth:

  shipped - apple-driver/applewirelessmouse.sys, Apple's unmodified,
            Microsoft-countersigned driver. It is tracked in git, so the truth
            is the bytes: they must hash to $ShippedDriverSha256 at
            $ShippedDriverSize bytes AND match the checksum the kit publishes
            for that same path in installer/SHA256SUMS.txt. No constant is
            scraped out of the installer for it, and the installer itself
            deliberately does not hash-pin it at runtime -- Apple has shipped
            more than one Boot Camp build, so it accepts the driver on
            Authenticode status, signer subject and PE OriginalFilename.
  legacy  - the PatchedResigned variant ($PatchedSha256 / $PatchedSize /
            $CertThumbprint in the installer). No longer shipped. Its constants
            are still verified where they are referenced, but nothing in the
            artifact is required to carry them.

MagicMouseFix.cer belongs to the legacy variant only and is optional: a kit
with no certificate is the normal Apple-route kit and passes. A certificate
that ships and disagrees with $CertThumbprint fails.

Check 7 validates the working tree. Checks 8-13 treat the ARCHIVE as the source
of truth, so an asset built from a different tree, or shipping docs that
contradict its own payload, fails even when the repo itself is consistent.

A missing asset is a hard failure, never a skip. The driver is a required
payload file now that it is tracked in git, so a kit without it fails rather
than degrading to a scripts-only kit.

.PARAMETER ZipPath
Path to the release ZIP to verify.

.PARAMETER RepoRoot
Repository root. Defaults to the parent of the scripts directory.

.PARAMETER Tag
Release tag. When supplied, the asset filename must contain it.

.EXAMPLE
pwsh -File scripts/verify-release.ps1 -ZipPath dist/magic-mouse-v3-fix-v1.0.0-installer.zip -Tag v1.0.0

.NOTES
License: MIT
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ZipPath,

    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:CheckIndex = 0
$script:Checks     = [System.Collections.Generic.List[object]]::new()

# Archive paths. The kit ships the repository layout because Install.cmd
# resolves its payload relative to its own folder; check 10 enforces that.
$InstallerEntry = 'installer/Install-MagicMousePatch.ps1'
$SumsEntry      = 'installer/SHA256SUMS.txt'
$CertEntry      = 'installer/MagicMouseFix.cer'
$DriverEntry    = 'apple-driver/applewirelessmouse.sys'

# The shipped Apple build, by its bytes. Not scraped from the installer: the
# installer identifies Apple's driver by signature, not by hash.
$ShippedDriverSha256 = '08f33d7e3ece2c73950a9706f1c4c9057894eaeaf1c4fb355f261f3c2333378f'
$ShippedDriverSize   = 78424

# ============================================================================
# Helpers
# ============================================================================

function Write-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Pass,
        [string]$Detail = ''
    )

    $script:CheckIndex++
    $script:Checks.Add([pscustomobject]@{
        Index  = $script:CheckIndex
        Name   = $Name
        Pass   = $Pass
        Detail = $Detail
    })

    if ($Pass) {
        Write-Host ("  [{0,2}] PASS  {1}" -f $script:CheckIndex, $Name) -ForegroundColor Green
        if ($Detail) { Write-Host "          $Detail" -ForegroundColor Gray }
    } else {
        Write-Host "::error::$Name - $Detail"
        Write-Host ("  [{0,2}] FAIL  {1}" -f $script:CheckIndex, $Name) -ForegroundColor Red
        if ($Detail) { Write-Host "          $Detail" -ForegroundColor Yellow }
    }
}

function Get-ZipEntryHash {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string]$Name
    )

    $entry  = $Archive.GetEntry($Name)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    $stream = $entry.Open()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-ZipEntryText {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string]$Name
    )

    $entry  = $Archive.GetEntry($Name)
    $stream = $entry.Open()
    $reader = [System.IO.StreamReader]::new($stream)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Expand-ZipEntry {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Destination
    )

    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Archive.GetEntry($Name), $Destination, $true)
    return $Destination
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64) {
        throw "File is too small to contain a DOS header ($($bytes.Length) bytes)"
    }
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'Missing MZ signature at offset 0x00'
    }

    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or ($peOffset + 6) -ge $bytes.Length) {
        throw "e_lfanew points outside the file (0x$($peOffset.ToString('X')))"
    }
    if ($bytes[$peOffset]     -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0x00 -or $bytes[$peOffset + 3] -ne 0x00) {
        throw "Missing PE\0\0 signature at 0x$($peOffset.ToString('X'))"
    }

    return [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

# The legacy PatchedResigned triple. Apple's driver has no counterpart here on
# purpose: it is identified by signature at install time and by its bytes here.
function Get-InstallerFact {
    param([Parameter(Mandatory)][string]$Path)

    $text  = Get-Content -LiteralPath $Path -Raw
    $sha   = [regex]::Match($text, '\$PatchedSha256\s*=\s*[''"]([0-9A-Fa-f]{64})[''"]')
    $size  = [regex]::Match($text, '\$PatchedSize\s*=\s*([0-9]+)')
    $thumb = [regex]::Match($text, '\$CertThumbprint\s*=\s*[''"]([0-9A-Fa-f]{40})[''"]')
    if (-not $sha.Success -or -not $size.Success -or -not $thumb.Success) {
        throw "Unable to read PatchedSha256/PatchedSize/CertThumbprint from $Path"
    }
    return [pscustomobject]@{
        Sha256     = $sha.Groups[1].Value.ToLowerInvariant()
        Size       = [int64]$size.Groups[1].Value
        Thumbprint = $thumb.Groups[1].Value.ToLowerInvariant()
    }
}

function Write-Verdict {
    $failed = @($script:Checks | Where-Object { -not $_.Pass })

    Write-Host ""
    Write-Host "Summary" -ForegroundColor Cyan
    $script:Checks |
        Select-Object -Property Index,
                                @{ Name = 'Result'; Expression = { if ($_.Pass) { 'PASS' } else { 'FAIL' } } },
                                Name,
                                Detail |
        Format-Table -AutoSize -Wrap |
        Out-Host

    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) of $($script:Checks.Count) checks FAILED" -ForegroundColor Red
        return 1
    }
    Write-Host "All $($script:Checks.Count) checks passed" -ForegroundColor Green
    return 0
}

# ============================================================================
# 1. Asset exists and is non-empty.
# ============================================================================

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$zipName    = Split-Path -Leaf $ZipPath
$zipPresent = Test-Path -LiteralPath $ZipPath -PathType Leaf
$zipLength  = 0

Write-Host ""
Write-Host "Verifying release asset $zipName" -ForegroundColor Cyan

if ($zipPresent) {
    $ZipPath   = (Resolve-Path -LiteralPath $ZipPath).Path
    $zipLength = (Get-Item -LiteralPath $ZipPath).Length
}

Write-Check -Name 'Asset exists and is non-empty' `
            -Pass ($zipPresent -and $zipLength -gt 0) `
            -Detail $(if ($zipPresent) { "$ZipPath ($zipLength bytes)" } else { "not found: $ZipPath" })

if (-not $zipPresent -or $zipLength -le 0) {
    exit (Write-Verdict)
}

# ============================================================================
# 2. Published checksum for the download itself.
# ============================================================================

$sidecarPath = "$ZipPath.sha256"
$zipHash     = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
    $sidecarRaw  = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()
    $sidecarHash = ([regex]::Match($sidecarRaw, '([0-9A-Fa-f]{64})')).Groups[1].Value.ToLowerInvariant()
    Write-Check -Name 'Sidecar .sha256 matches asset hash' `
                -Pass ($sidecarHash -eq $zipHash) `
                -Detail $(if ($sidecarHash -eq $zipHash) { $zipHash } else { "sidecar=$sidecarHash actual=$zipHash" })
} else {
    Write-Check -Name 'Sidecar .sha256 matches asset hash' -Pass $false -Detail "missing sidecar: $sidecarPath"
}

# ============================================================================
# Open the archive once; read entries straight out of it.
# ============================================================================

# The driver is on this list because it is tracked in git now: a kit without it
# installs nothing and is a failure, not a lighter variant. MagicMouseFix.cer
# is deliberately absent from it - see check 13.
$mandatory = @(
    'Install.cmd'
    $InstallerEntry
    'installer/Uninstall-MagicMousePatch.ps1'
    $SumsEntry
    $DriverEntry
    'SHA256SUMS'
    'LICENSE'
    'SECURITY.md'
    'DMCA-NOTICE.md'
    'README.txt'
)

$extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('mmv3-verify-' + [guid]::NewGuid().ToString('N'))
$archive    = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

try {
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    $entryNames = @($archive.Entries | Select-Object -ExpandProperty FullName)

    Write-Host ""
    Write-Host "Archive entries ($($entryNames.Count)):" -ForegroundColor Gray
    foreach ($name in ($entryNames | Sort-Object)) {
        Write-Host "  $name" -ForegroundColor Gray
    }
    Write-Host ""

    # ------------------------------------------------------------------------
    # 3. Required ship files exist.
    # ------------------------------------------------------------------------

    $absent = @($mandatory | Where-Object { $entryNames -notcontains $_ })
    Write-Check -Name 'Required ship files present' `
                -Pass ($absent.Count -eq 0) `
                -Detail $(if ($absent.Count -eq 0) { "$($mandatory.Count) required entries" } else { "missing: $($absent -join ', ')" })

    # ------------------------------------------------------------------------
    # 4. README.txt is readable and non-empty.
    # ------------------------------------------------------------------------

    if ($entryNames -contains 'README.txt') {
        $readmeText = Get-ZipEntryText -Archive $archive -Name 'README.txt'
        Write-Check -Name 'README.txt is non-empty' `
                    -Pass ($readmeText.Trim().Length -gt 0) `
                    -Detail "$($readmeText.Length) characters"
    } else {
        Write-Check -Name 'README.txt is non-empty' -Pass $false -Detail 'README.txt not in archive'
    }

    # ------------------------------------------------------------------------
    # 5. In-archive SHA256SUMS covers every packaged file and every hash matches.
    # ------------------------------------------------------------------------

    if ($entryNames -contains 'SHA256SUMS') {
        $manifest = @{}
        foreach ($line in (Get-ZipEntryText -Archive $archive -Name 'SHA256SUMS') -split "`r?`n") {
            $match = [regex]::Match($line.Trim(), '^([0-9a-f]{64})\s\s?(.+)$')
            if ($match.Success) {
                $manifest[$match.Groups[2].Value.Trim()] = $match.Groups[1].Value
            }
        }

        $payload   = @($entryNames | Where-Object { $_ -ne 'SHA256SUMS' })
        $unlisted  = @($payload | Where-Object { -not $manifest.ContainsKey($_) })
        $mismatch  = @(
            foreach ($name in ($payload | Where-Object { $manifest.ContainsKey($_) })) {
                $actual = Get-ZipEntryHash -Archive $archive -Name $name
                if ($actual -ne $manifest[$name]) { "$name (manifest=$($manifest[$name]) actual=$actual)" }
            }
        )
        $stale = @($manifest.Keys | Where-Object { $payload -notcontains $_ })

        $problem = @($unlisted + $stale + $mismatch)
        $detail  = if ($problem.Count -eq 0) {
            "$($manifest.Count) entries listed, all hashes match"
        } else {
            $parts = @()
            if ($unlisted.Count -gt 0) { $parts += "unlisted: $($unlisted -join ', ')" }
            if ($stale.Count    -gt 0) { $parts += "listed but not packaged: $($stale -join ', ')" }
            if ($mismatch.Count -gt 0) { $parts += "hash mismatch: $($mismatch -join '; ')" }
            $parts -join ' | '
        }
        Write-Check -Name 'In-archive SHA256SUMS is complete and correct' -Pass ($problem.Count -eq 0) -Detail $detail
    } else {
        Write-Check -Name 'In-archive SHA256SUMS is complete and correct' -Pass $false -Detail 'SHA256SUMS not in archive'
    }

    # ------------------------------------------------------------------------
    # 6. Packaged installer parses. A release that ships an unloadable
    #    installer is the failure mode that matters most.
    # ------------------------------------------------------------------------

    $installerCopy = $null
    if ($entryNames -contains $InstallerEntry) {
        $installerCopy = Expand-ZipEntry -Archive $archive -Name $InstallerEntry `
                                         -Destination (Join-Path $extractDir 'Install-MagicMousePatch.ps1')

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($installerCopy, [ref]$tokens, [ref]$errors) | Out-Null

        $parseErrors = @($errors)
        Write-Check -Name 'Packaged installer parses cleanly' `
                    -Pass ($parseErrors.Count -eq 0) `
                    -Detail $(if ($parseErrors.Count -eq 0) { "$(@($tokens).Count) tokens, 0 parse errors" } else { ($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' })
    } else {
        Write-Check -Name 'Packaged installer parses cleanly' -Pass $false -Detail "$InstallerEntry not in archive"
    }

    # ------------------------------------------------------------------------
    # 7. The working tree still satisfies the provenance invariant. This says
    #    nothing about the archive - checks 8-13 do that.
    # ------------------------------------------------------------------------

    $provenanceScript = Join-Path (Join-Path $RepoRoot 'scripts') 'Test-ReleaseProvenance.ps1'
    if (Test-Path -LiteralPath $provenanceScript -PathType Leaf) {
        & pwsh -NoLogo -NoProfile -File $provenanceScript -RepoRoot $RepoRoot | Out-Host
        $provenanceExit = $LASTEXITCODE
        Write-Check -Name 'Repo tree passes the provenance invariant' `
                    -Pass ($provenanceExit -eq 0) `
                    -Detail "Test-ReleaseProvenance.ps1 -RepoRoot $RepoRoot exit=$provenanceExit"
    } else {
        Write-Check -Name 'Repo tree passes the provenance invariant' `
                    -Pass $false `
                    -Detail "missing: $provenanceScript"
    }

    # ------------------------------------------------------------------------
    # 8. The packaged installer's legacy constants equal the repo installer's.
    #    An archive built from a different or older tree fails here, which is
    #    the gap check 7 cannot see.
    # ------------------------------------------------------------------------

    $packagedFacts = $null
    $repoFacts     = $null
    $factProblems  = @()

    if ($null -ne $installerCopy) {
        try { $packagedFacts = Get-InstallerFact -Path $installerCopy }
        catch { $factProblems += "packaged installer: $($_.Exception.Message)" }
    } else {
        $factProblems += "$InstallerEntry not in archive"
    }

    $repoInstaller = Join-Path (Join-Path (Join-Path $RepoRoot 'v1-binary-patch') 'installer') 'Install-MagicMousePatch.ps1'
    if (Test-Path -LiteralPath $repoInstaller -PathType Leaf) {
        try { $repoFacts = Get-InstallerFact -Path $repoInstaller }
        catch { $factProblems += "repo installer: $($_.Exception.Message)" }
    } else {
        $factProblems += "missing: $repoInstaller"
    }

    if ($null -ne $packagedFacts -and $null -ne $repoFacts) {
        if ($packagedFacts.Sha256     -ne $repoFacts.Sha256)     { $factProblems += "legacy sha256 packaged=$($packagedFacts.Sha256) repo=$($repoFacts.Sha256)" }
        if ($packagedFacts.Size       -ne $repoFacts.Size)       { $factProblems += "legacy size packaged=$($packagedFacts.Size) repo=$($repoFacts.Size)" }
        if ($packagedFacts.Thumbprint -ne $repoFacts.Thumbprint) { $factProblems += "thumbprint packaged=$($packagedFacts.Thumbprint) repo=$($repoFacts.Thumbprint)" }
    }

    Write-Check -Name 'Packaged installer legacy constants match the repo installer' `
                -Pass ($factProblems.Count -eq 0) `
                -Detail $(if ($factProblems.Count -eq 0) { "$($packagedFacts.Sha256) / $($packagedFacts.Size) bytes / $($packagedFacts.Thumbprint)" } else { $factProblems -join ' | ' })

    # ------------------------------------------------------------------------
    # 9. The packaged documents agree with what the archive ships, so the kit
    #    is internally consistent on the user's disk after download.
    # ------------------------------------------------------------------------

    $shippedHash = $null
    if ($entryNames -contains $DriverEntry) {
        $shippedHash = Get-ZipEntryHash -Archive $archive -Name $DriverEntry
    }

    $docProblems = @()

    # installer/SHA256SUMS.txt is the checksum file the kit tells users to run
    # sha256sum -c against, from the package root. Its line for the shipped
    # driver must therefore describe the bytes actually in the archive, under
    # exactly the path they are stored at.
    if ($entryNames -notcontains $SumsEntry) {
        $docProblems += "$SumsEntry not in archive"
    } elseif ($null -eq $shippedHash) {
        $docProblems += "$DriverEntry not in archive, so its checksum line cannot be checked"
    } else {
        $sumsText   = Get-ZipEntryText -Archive $archive -Name $SumsEntry
        # Built by concatenation: the quantifier braces below are regex, not
        # format placeholders.
        $driverPattern = '(?m)^([0-9A-Fa-f]{64})\s\s?' + [regex]::Escape($DriverEntry) + '\s*$'
        $driverLine = [regex]::Match($sumsText, $driverPattern)
        if (-not $driverLine.Success) {
            $docProblems += "$($SumsEntry): no '$DriverEntry' entry in sha256sum format"
        } elseif ($driverLine.Groups[1].Value.ToLowerInvariant() -ne $shippedHash) {
            $docProblems += "$($SumsEntry): $DriverEntry=$($driverLine.Groups[1].Value.ToLowerInvariant()) shipped bytes=$shippedHash"
        }
    }

    # In a file that documents this driver, a 64-hex run is one of the two
    # artifacts this project has ever had - the shipped Apple driver or the
    # legacy patched one - and a 40-hex run is the legacy signing thumbprint.
    # Anything else is a stale or invented value. The shipped hash must appear;
    # the legacy values are optional, because the legacy route is not shipped.
    if ($null -eq $shippedHash) {
        $docProblems += 'shipped driver hash unavailable'
    } else {
        $allowedSha = @($shippedHash)
        if ($null -ne $packagedFacts) { $allowedSha += $packagedFacts.Sha256 }

        foreach ($docName in @('README.txt', 'SECURITY.md')) {
            if ($entryNames -notcontains $docName) {
                $docProblems += "$docName not in archive"
                continue
            }

            $docText   = Get-ZipEntryText -Archive $archive -Name $docName
            $shaHits   = @([regex]::Matches($docText, '\b[0-9A-Fa-f]{64}\b') | ForEach-Object { $_.Value.ToLowerInvariant() })
            $thumbHits = @([regex]::Matches($docText, '\b[0-9A-Fa-f]{40}\b') | ForEach-Object { $_.Value.ToLowerInvariant() })
            $badSha    = @($shaHits | Where-Object { $allowedSha -notcontains $_ } | Select-Object -Unique)
            $badThumb  = @()
            if ($null -ne $packagedFacts) {
                $badThumb = @($thumbHits | Where-Object { $_ -ne $packagedFacts.Thumbprint } | Select-Object -Unique)
            }

            if ($shaHits -notcontains $shippedHash) { $docProblems += "${docName}: does not document the shipped driver SHA256 $shippedHash" }
            if ($badSha.Count   -gt 0) { $docProblems += "${docName}: sha256 $($badSha -join ', ') matches neither the shipped driver nor the legacy artifact" }
            if ($badThumb.Count -gt 0) { $docProblems += "${docName}: thumbprint $($badThumb -join ', ') contradicts `$CertThumbprint $($packagedFacts.Thumbprint)" }
        }
    }

    Write-Check -Name 'Packaged docs agree with the shipped payload' `
                -Pass ($docProblems.Count -eq 0) `
                -Detail $(if ($docProblems.Count -eq 0) { "SHA256SUMS.txt, README.txt and SECURITY.md agree with $DriverEntry" } else { $docProblems -join ' | ' })

    # ------------------------------------------------------------------------
    # 10. The one-click route is a layout, not a file list. Install.cmd is what
    #     users double-click and it resolves its payload as %HERE%<relative
    #     path>, so the paths are read back out of the packaged Install.cmd and
    #     required to exist at exactly those places. A kit that flattens the
    #     folders still contains every file and still cannot install.
    # ------------------------------------------------------------------------

    $layoutProblems = @()
    $resolved       = @()

    if ($entryNames -notcontains 'Install.cmd') {
        $layoutProblems += 'Install.cmd not in archive'
    } else {
        $cmdText = Get-ZipEntryText -Archive $archive -Name 'Install.cmd'
        foreach ($match in [regex]::Matches($cmdText, '%HERE%([^"\r\n]+)')) {
            $relative = $match.Groups[1].Value.Trim().Replace('\', '/')
            if ($resolved -notcontains $relative) { $resolved += $relative }
        }

        if ($resolved.Count -eq 0) {
            $layoutProblems += 'Install.cmd resolves no %HERE%-relative payload path'
        }
        foreach ($relative in $resolved) {
            if ($entryNames -notcontains $relative) {
                $layoutProblems += "Install.cmd resolves %HERE%$($relative.Replace('/', '\')) but the archive has no '$relative'"
            }
        }
        foreach ($required in @($InstallerEntry, $DriverEntry)) {
            if ($resolved -notcontains $required) {
                $layoutProblems += "Install.cmd no longer resolves '$required' - the one-click route would not run the shipped installer against the shipped driver"
            }
        }
    }

    Write-Check -Name 'One-click layout matches what Install.cmd resolves' `
                -Pass ($layoutProblems.Count -eq 0) `
                -Detail $(if ($layoutProblems.Count -eq 0) { "Install.cmd -> $($resolved -join ', ')" } else { $layoutProblems -join ' | ' })

    # ------------------------------------------------------------------------
    # 11. Shipped driver is Apple's expected binary, byte for byte.
    # 12. Shipped driver is an AMD64 PE image.
    # ------------------------------------------------------------------------

    if ($entryNames -contains $DriverEntry) {
        $driverCopy = Expand-ZipEntry -Archive $archive -Name $DriverEntry `
                                      -Destination (Join-Path $extractDir 'applewirelessmouse.sys')
        $driverSize = (Get-Item -LiteralPath $driverCopy).Length

        $hashOk = $shippedHash -eq $ShippedDriverSha256
        $sizeOk = $driverSize  -eq $ShippedDriverSize

        $driverDetail = if ($hashOk -and $sizeOk) {
            "$shippedHash / $driverSize bytes, Apple's unmodified driver"
        } else {
            $parts = @()
            if (-not $hashOk) { $parts += "sha256 expected=$ShippedDriverSha256 actual=$shippedHash" }
            if (-not $sizeOk) { $parts += "size expected=$ShippedDriverSize actual=$driverSize" }
            $parts -join ' | '
        }
        Write-Check -Name 'Shipped driver is the expected Apple binary' -Pass ($hashOk -and $sizeOk) -Detail $driverDetail

        $machine    = 0
        $machineErr = ''
        try {
            $machine = Get-PeMachine -Path $driverCopy
        } catch {
            $machineErr = $_.Exception.Message
        }
        Write-Check -Name 'Shipped driver is an AMD64 PE image' `
                    -Pass ($machine -eq 0x8664) `
                    -Detail $(if ($machineErr) { $machineErr } else { "Machine=0x$($machine.ToString('X4'))" })
    } else {
        Write-Check -Name 'Shipped driver is the expected Apple binary' -Pass $false -Detail "$DriverEntry not in archive"
        Write-Check -Name 'Shipped driver is an AMD64 PE image'         -Pass $false -Detail "$DriverEntry not in archive"
    }

    # ------------------------------------------------------------------------
    # 13. The certificate is optional. It only ever mattered to the legacy
    #     PatchedResigned variant, which is not shipped; Apple's driver is
    #     Microsoft-countersigned and imports nothing. So its absence passes,
    #     and its presence is held to $CertThumbprint - the installer refuses
    #     any other certificate anyway, and a kit that ships one it will refuse
    #     is worse than a kit that ships none.
    # ------------------------------------------------------------------------

    if ($entryNames -notcontains $CertEntry) {
        Write-Check -Name 'Certificate, if shipped, matches $CertThumbprint' `
                    -Pass $true `
                    -Detail 'Apple-route kit: no certificate shipped, none required'
    } elseif ($null -eq $packagedFacts) {
        Write-Check -Name 'Certificate, if shipped, matches $CertThumbprint' `
                    -Pass $false `
                    -Detail "$CertEntry ships but `$CertThumbprint could not be read from the packaged installer"
    } else {
        $certCopy   = Expand-ZipEntry -Archive $archive -Name $CertEntry `
                                      -Destination (Join-Path $extractDir 'MagicMouseFix.cer')
        $certThumb  = $null
        $certError  = ''
        try {
            $certThumb = ([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certCopy)).Thumbprint.ToLowerInvariant()
        } catch {
            $certError = $_.Exception.Message
        }

        if ($certError) {
            Write-Check -Name 'Certificate, if shipped, matches $CertThumbprint' `
                        -Pass $false `
                        -Detail "$CertEntry is not a readable X.509 certificate: $certError"
        } else {
            Write-Check -Name 'Certificate, if shipped, matches $CertThumbprint' `
                        -Pass ($certThumb -eq $packagedFacts.Thumbprint) `
                        -Detail $(if ($certThumb -eq $packagedFacts.Thumbprint) { "legacy certificate $certThumb" } else { "cert=$certThumb installer expects=$($packagedFacts.Thumbprint)" })
        }
    }

    # ------------------------------------------------------------------------
    # 14. Asset filename carries the release tag.
    # ------------------------------------------------------------------------

    if ($PSBoundParameters.ContainsKey('Tag') -and -not [string]::IsNullOrWhiteSpace($Tag)) {
        Write-Check -Name 'Asset filename carries the release tag' `
                    -Pass ($zipName -like "*$Tag*") `
                    -Detail "tag=$Tag name=$zipName"
    }
} finally {
    $archive.Dispose()
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
}

exit (Write-Verdict)
