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
  8. Packaged installer constants equal the repo installer's constants.
  9. Packaged SHA256SUMS.txt, README.txt and SECURITY.md agree with the
     packaged installer.
 10. The legacy patched driver and its certificate both ship, or neither does.
 11. Shipped driver is one of the two known binaries, at its documented size.
 12. Shipped driver is an AMD64 PE image.
 13. Asset filename carries the release tag.

Check 7 validates the working tree. Checks 8-11 treat the ARCHIVE as the
source of truth, so an asset built from a different tree, or shipping docs that
contradict its own installer, fails even when the repo itself is consistent.

Two applewirelessmouse.sys binaries are known: Apple's unmodified,
Microsoft-countersigned driver, pinned below because the installer identifies
it by signer rather than by hash and which needs no certificate; and the legacy
byte-patched copy re-signed as CN=MagicMouseFix, whose constants the packaged
installer declares and which cannot install without MagicMouseFix.cer.

A missing asset is a hard failure, never a skip. The driver checks are
no-ops-with-note when applewirelessmouse.sys is not redistributed in the
archive (see DMCA-NOTICE.md).

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

# The shipped Apple driver; see the .DESCRIPTION note on why it is pinned here.
# Test-ReleaseProvenance.ps1 fails if this pin drifts from the rest of the tree.
$script:AppleSha256 = '08f33d7e3ece2c73950a9706f1c4c9057894eaeaf1c4fb355f261f3c2333378f'
$script:AppleSize   = [int64]78424

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

$mandatory = @(
    'Install-MagicMousePatch.ps1'
    'Uninstall-MagicMousePatch.ps1'
    'SHA256SUMS.txt'
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
    if ($entryNames -contains 'Install-MagicMousePatch.ps1') {
        $installerCopy = Join-Path $extractDir 'Install-MagicMousePatch.ps1'
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
            $archive.GetEntry('Install-MagicMousePatch.ps1'), $installerCopy, $true)

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($installerCopy, [ref]$tokens, [ref]$errors) | Out-Null

        $parseErrors = @($errors)
        Write-Check -Name 'Packaged installer parses cleanly' `
                    -Pass ($parseErrors.Count -eq 0) `
                    -Detail $(if ($parseErrors.Count -eq 0) { "$(@($tokens).Count) tokens, 0 parse errors" } else { ($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' })
    } else {
        Write-Check -Name 'Packaged installer parses cleanly' -Pass $false -Detail 'Install-MagicMousePatch.ps1 not in archive'
    }

    # ------------------------------------------------------------------------
    # 7. The working tree still satisfies the provenance invariant. This says
    #    nothing about the archive - checks 8-11 do that.
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
    # 8. The packaged installer's constants equal the repo installer's. An
    #    archive built from a different or older tree fails here, which is the
    #    gap check 7 cannot see.
    # ------------------------------------------------------------------------

    $packagedFacts = $null
    $repoFacts     = $null
    $factProblems  = @()

    if ($null -ne $installerCopy) {
        try { $packagedFacts = Get-InstallerFact -Path $installerCopy }
        catch { $factProblems += "packaged installer: $($_.Exception.Message)" }
    } else {
        $factProblems += 'Install-MagicMousePatch.ps1 not in archive'
    }

    $repoInstaller = Join-Path (Join-Path (Join-Path $RepoRoot 'v1-binary-patch') 'installer') 'Install-MagicMousePatch.ps1'
    if (Test-Path -LiteralPath $repoInstaller -PathType Leaf) {
        try { $repoFacts = Get-InstallerFact -Path $repoInstaller }
        catch { $factProblems += "repo installer: $($_.Exception.Message)" }
    } else {
        $factProblems += "missing: $repoInstaller"
    }

    if ($null -ne $packagedFacts -and $null -ne $repoFacts) {
        if ($packagedFacts.Sha256     -ne $repoFacts.Sha256)     { $factProblems += "sha256 packaged=$($packagedFacts.Sha256) repo=$($repoFacts.Sha256)" }
        if ($packagedFacts.Size       -ne $repoFacts.Size)       { $factProblems += "size packaged=$($packagedFacts.Size) repo=$($repoFacts.Size)" }
        if ($packagedFacts.Thumbprint -ne $repoFacts.Thumbprint) { $factProblems += "thumbprint packaged=$($packagedFacts.Thumbprint) repo=$($repoFacts.Thumbprint)" }
    }

    Write-Check -Name 'Packaged installer constants match the repo installer' `
                -Pass ($factProblems.Count -eq 0) `
                -Detail $(if ($factProblems.Count -eq 0) { "$($packagedFacts.Sha256) / $($packagedFacts.Size) bytes / $($packagedFacts.Thumbprint)" } else { $factProblems -join ' | ' })

    # ------------------------------------------------------------------------
    # 9. The packaged documents agree with the PACKAGED installer, so the kit
    #    is internally consistent on the user's disk after download.
    # ------------------------------------------------------------------------

    $docProblems = @()

    if ($null -eq $packagedFacts) {
        $docProblems += 'packaged installer constants unavailable'
    } else {
        $knownSha     = @($script:AppleSha256, $packagedFacts.Sha256)
        $knownShaText = "apple $($script:AppleSha256) | legacy $($packagedFacts.Sha256)"

        # SHA256SUMS.txt is filename-scoped: only the driver's line is bound to a
        # driver hash. Other entries (MagicMouseFix.cer) are legitimately
        # different hashes and are not in scope. Entries are path-qualified
        # relative to v1-binary-patch/ ("apple-driver/..."), so the filename is
        # matched on its basename and the entry is held to the driver its own
        # path names.
        if ($entryNames -contains 'SHA256SUMS.txt') {
            $sumsText   = Get-ZipEntryText -Archive $archive -Name 'SHA256SUMS.txt'
            $driverLine = $null
            foreach ($sumsLine in ($sumsText -split "`r?`n")) {
                $entry = [regex]::Match($sumsLine, '^([0-9A-Fa-f]{64})\s\s?(\S+)\s*$')
                if ($entry.Success -and (Split-Path -Leaf $entry.Groups[2].Value) -ieq 'applewirelessmouse.sys') {
                    $driverLine = $entry
                    break
                }
            }

            if ($null -eq $driverLine) {
                $docProblems += 'SHA256SUMS.txt: no applewirelessmouse.sys entry in sha256sum format'
            } else {
                $entryName = $driverLine.Groups[2].Value
                $entryHash = $driverLine.Groups[1].Value.ToLowerInvariant()
                $entryExpected = if ($entryName -like 'apple-driver/*') { $script:AppleSha256 } else { $packagedFacts.Sha256 }
                if ($entryHash -ne $entryExpected) {
                    $docProblems += "SHA256SUMS.txt: $entryName=$entryHash but that path holds $entryExpected"
                }
            }
        } else {
            $docProblems += 'SHA256SUMS.txt not in archive'
        }

        # Strict by default: in a file that documents these drivers, every 64-hex
        # run names one of the two known binaries and every 40-hex run is the cert
        # thumbprint. A value that is neither driver is a stale copy.
        foreach ($docName in @('README.txt', 'SECURITY.md')) {
            if ($entryNames -notcontains $docName) {
                $docProblems += "$docName not in archive"
                continue
            }

            $docText   = Get-ZipEntryText -Archive $archive -Name $docName
            $shaHits   = @([regex]::Matches($docText, '\b[0-9A-Fa-f]{64}\b')   | ForEach-Object { $_.Value.ToLowerInvariant() })
            $thumbHits = @([regex]::Matches($docText, '\b[0-9A-Fa-f]{40}\b')   | ForEach-Object { $_.Value.ToLowerInvariant() })
            $badSha    = @($shaHits   | Where-Object { $knownSha -notcontains $_ }            | Select-Object -Unique)
            $badThumb  = @($thumbHits | Where-Object { $_ -ne $packagedFacts.Thumbprint } | Select-Object -Unique)

            if ($shaHits.Count   -eq 0) { $docProblems += "${docName}: documents neither driver SHA256 ($knownShaText)" }
            if ($thumbHits.Count -eq 0) { $docProblems += "${docName}: does not document the certificate thumbprint $($packagedFacts.Thumbprint)" }
            if ($badSha.Count   -gt 0) { $docProblems += "${docName}: sha256 $($badSha -join ', ') names no known driver ($knownShaText)" }
            if ($badThumb.Count -gt 0) { $docProblems += "${docName}: thumbprint $($badThumb -join ', ') contradicts packaged $($packagedFacts.Thumbprint)" }
        }
    }

    Write-Check -Name 'Packaged docs agree with the packaged installer' `
                -Pass ($docProblems.Count -eq 0) `
                -Detail $(if ($docProblems.Count -eq 0) { 'SHA256SUMS.txt, README.txt and SECURITY.md name only known drivers and the packaged thumbprint' } else { $docProblems -join ' | ' })

    # ------------------------------------------------------------------------
    # 10. The legacy patched driver and MagicMouseFix.cer are one payload:
    #     Install-MagicMousePatch.ps1 imports the .cer before it copies that
    #     .sys and refuses to run without either, so a kit carrying exactly one
    #     of them cannot install while looking complete. Apple's driver is
    #     Microsoft-countersigned and ships alone - a certificate alongside it
    #     would be a file the kit cannot use.
    # ------------------------------------------------------------------------

    $hasDriver = $entryNames -contains 'applewirelessmouse.sys'
    $hasCert   = $entryNames -contains 'MagicMouseFix.cer'

    $driverCopy    = $null
    $driverHash    = ''
    $driverSize    = 0
    $shippedDriver = 'none'

    if ($hasDriver) {
        $driverCopy = Join-Path $extractDir 'applewirelessmouse.sys'
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
            $archive.GetEntry('applewirelessmouse.sys'), $driverCopy, $true)

        $driverHash = (Get-FileHash -LiteralPath $driverCopy -Algorithm SHA256).Hash.ToLowerInvariant()
        $driverSize = (Get-Item -LiteralPath $driverCopy).Length

        $shippedDriver = if ($driverHash -eq $script:AppleSha256) { 'apple' }
                         elseif ($null -ne $packagedFacts -and $driverHash -eq $packagedFacts.Sha256) { 'legacy' }
                         else { 'unknown' }
    }

    $certRequired = $shippedDriver -eq 'legacy'
    $pairDetail = if (-not $hasDriver -and -not $hasCert) {
        'scripts-only kit: no driver redistributed (binary_included=false)'
    } elseif ($certRequired -and $hasCert) {
        'full legacy kit: applewirelessmouse.sys + MagicMouseFix.cer (binary_included=true)'
    } elseif ($certRequired) {
        'the legacy patched applewirelessmouse.sys ships without MagicMouseFix.cer - the installer imports the certificate before it copies that driver, so this kit cannot install'
    } elseif ($hasCert) {
        "MagicMouseFix.cer ships alongside the $shippedDriver driver, which does not use it - that certificate only trusts the re-signed legacy binary"
    } else {
        "$shippedDriver driver ships alone, as it must: Microsoft-countersigned, no certificate to import (binary_included=true)"
    }

    Write-Check -Name 'Certificate ships exactly when the legacy driver does' -Pass ($hasCert -eq $certRequired) -Detail $pairDetail

    # ------------------------------------------------------------------------
    # 11. Shipped driver is one of the two known binaries, at its own size.
    # 12. Shipped driver is an AMD64 PE image.
    # ------------------------------------------------------------------------

    if ($hasDriver) {
        $expectedSize = switch ($shippedDriver) {
            'apple'  { $script:AppleSize }
            'legacy' { $packagedFacts.Size }
            default  { 0 }
        }

        if ($shippedDriver -eq 'unknown') {
            $known = if ($null -eq $packagedFacts) { "apple $($script:AppleSha256) (packaged installer constants unavailable)" } else { "apple $($script:AppleSha256) | legacy $($packagedFacts.Sha256)" }
            Write-Check -Name 'Shipped driver is a known binary at its documented size' `
                        -Pass $false `
                        -Detail "sha256 $driverHash / $driverSize bytes matches no known driver ($known)"
        } else {
            $sizeOk = $driverSize -eq $expectedSize
            Write-Check -Name 'Shipped driver is a known binary at its documented size' `
                        -Pass $sizeOk `
                        -Detail $(if ($sizeOk) { "$shippedDriver driver: $driverHash / $driverSize bytes" } else { "$shippedDriver driver: size expected $expectedSize actual $driverSize" })
        }

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
        Write-Host "NOTE: scripts-only kit, binary not redistributed" -ForegroundColor Yellow
        Write-Host "      obtain applewirelessmouse.sys per v1-binary-patch/README.md" -ForegroundColor Gray
    }

    # ------------------------------------------------------------------------
    # 13. Asset filename carries the release tag.
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
