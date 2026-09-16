<#
.SYNOPSIS
    MAINTAINER TOOL. Builds the community release ZIP for the Magic Mouse v3
    (PID 0323) two-finger scroll driver.

.DESCRIPTION
    Packages EXACTLY the agreed community payload - flat at the archive root,
    plus a single scripts\ folder - and refuses to produce anything else:

        Setup-Community.cmd                        <- the one file a user runs
        Setup-Community.ps1
        Install-KMDF.ps1
        Uninstall-KMDF.cmd
        MagicMouseDriver-kmdf-204-scroll.inf
        MagicMouseDriver-kmdf-204-scroll.sys       <- UNSIGNED, signed on the
                                                      user's own PC by the wizard
        README-FIRST.txt
        SHA256SUMS.txt
        scripts\Kmdf-Common.ps1
        scripts\mm-f1-once.ps1
        scripts\mm-auto-f1-watcher.ps1
        scripts\mm-auto-f1-watcher-install.ps1
        scripts\mm-scroll-tune.ps1

    It fails loudly rather than shipping something wrong:
      * any manifest file missing                        -> fail
      * the staged set differs from the manifest at all  -> fail
      * a forbidden artifact would be packaged           -> fail
        (MagicMouseDriver.sys - the live Apr 30 / oem16 name; any .cat, since
         the catalogue is built on the user's PC; any .cer/.pfx/.p12/.pvk/.key
         signing material; any kmdf-204-* or mm-queue-submit.sh maintainer
         tooling with machine-specific hardcoded paths)
      * signing material or a restore binary sitting in the source tree -> fail
      * the .sys does not hash to the frozen expected value             -> fail

    SHA256SUMS.txt is always regenerated from the real file contents, so the
    ZIP can never carry stale checksums. The copy in the source tree is updated
    too, unless -VerifySumsOnly is given (then a stale copy is an error and
    nothing is written or packaged).

    Nothing here installs, signs, reboots or touches driver state. It reads the
    source tree and writes a ZIP.

.PARAMETER Version
    Release version, used only in the output file name. Default 2.0.4.3.

.PARAMETER SourceRoot
    The v2-kmdf-driver directory to package from. Defaults to this script's
    parent directory, so a plain run from a clone does the right thing.

.PARAMETER OutDir
    Where to write the ZIP. Defaults to %TEMP%\mm-community-zip. Never the
    repository.

.PARAMETER ExpectedSysSha256
    Frozen SHA256 of the UNSIGNED driver binary. Override only when the driver
    is rebuilt, and then update the constant in this script as well.

.PARAMETER VerifySumsOnly
    Read-only check: validate the manifest, the .sys hash and the committed
    SHA256SUMS.txt, then stop. Writes nothing. Useful in CI.

.PARAMETER Force
    Overwrite an existing ZIP of the same name.

.OUTPUTS
    Exit 0  packaged (or verified) successfully
    Exit 20 a validation gate failed - read the message, fix the tree
    Exit 40 unexpected error

.EXAMPLE
    .\make-community-zip.ps1
    .\make-community-zip.ps1 -Version 2.0.4.4 -OutDir D:\release -Force
    .\make-community-zip.ps1 -VerifySumsOnly
#>
[CmdletBinding()]
param(
    [string] $Version = '2.0.4.3',
    [string] $SourceRoot,
    [string] $OutDir,
    [string] $ExpectedSysSha256 = '08E91E37AF3B7B9A56E793ADB876BA48FBD61DDFEE446C89A6A1751CABABD6AC',
    [switch] $VerifySumsOnly,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The contract. Order here is the order in SHA256SUMS.txt.
# ---------------------------------------------------------------------------
$Manifest = @(
    'Setup-Community.cmd'
    'Setup-Community.ps1'
    'Install-KMDF.ps1'
    'Uninstall-KMDF.cmd'
    'MagicMouseDriver-kmdf-204-scroll.inf'
    'MagicMouseDriver-kmdf-204-scroll.sys'
    'README-FIRST.txt'
    'SHA256SUMS.txt'
    'scripts\Kmdf-Common.ps1'
    'scripts\mm-f1-once.ps1'
    'scripts\mm-auto-f1-watcher.ps1'
    'scripts\mm-auto-f1-watcher-install.ps1'
    'scripts\mm-scroll-tune.ps1'
)

# SHA256SUMS.txt cannot contain its own hash.
$SumsName    = 'SHA256SUMS.txt'
$DriverSys   = 'MagicMouseDriver-kmdf-204-scroll.sys'
$DriverBytes = 25600

# Never package these, whatever the manifest says.
$ForbiddenPatterns = @(
    'MagicMouseDriver.sys'      # live Apr 30 / oem16 name - would collide on install
    '*.cat'                     # catalogue is built on the user's PC, never shipped
    '*.cer', '*.pfx', '*.p12', '*.pvk', '*.key', '*.snk'   # signing material
    'kmdf-204-*'                # maintainer build/sign tooling, hardcoded EWDK paths
    'mm-queue-submit.sh'        # maintainer dev queue, hardcoded C:\mm-dev-queue
    '*.pdb'
)

# Must not even be lying around in the directory we package from.
$SourceTabooPatterns = @(
    'MagicMouseDriver.sys'
    '*.cat', '*.cer', '*.pfx', '*.p12', '*.pvk', '*.key', '*.snk'
)

function Write-Head([string] $Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Stop-Bad([string] $Title, [string[]] $Detail) {
    Write-Host ''
    Write-Host '###########################################################################' -ForegroundColor Red
    Write-Host "## PACKAGING REFUSED: $Title" -ForegroundColor Red
    Write-Host '###########################################################################' -ForegroundColor Red
    foreach ($d in $Detail) { Write-Host "   $d" -ForegroundColor Red }
    Write-Host ''
    exit 20
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Forbidden([string] $Name, [string[]] $Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $p } }
    return $null
}

trap {
    Write-Host ''
    Write-Host "## UNEXPECTED ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 40
}

# ---------------------------------------------------------------------------
# 0. Resolve paths
# ---------------------------------------------------------------------------
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    Stop-Bad 'source directory does not exist' @("SourceRoot = $SourceRoot")
}
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'mm-community-zip' }

Write-Host ''
Write-Host "Magic Mouse v3 community package builder - version $Version"
Write-Host "  source : $SourceRoot"
Write-Host "  output : $(if ($VerifySumsOnly) { '(verify only, nothing written)' } else { $OutDir })"

# ---------------------------------------------------------------------------
# 1. Every manifest file must exist
# ---------------------------------------------------------------------------
Write-Head 'manifest'
$missing = @()
foreach ($rel in $Manifest) {
    if ($rel -eq $SumsName) { continue }   # regenerated below, may not exist yet
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot $rel) -PathType Leaf)) {
        $missing += $rel
    }
}
if ($missing.Count -gt 0) {
    Stop-Bad "$($missing.Count) file(s) from the release manifest are missing" (
        @('These must exist before a ZIP can be built:') + ($missing | ForEach-Object { "MISSING  $_" })
    )
}
Write-Host "   $($Manifest.Count) manifest entries, all present."

# ---------------------------------------------------------------------------
# 2. No signing material or colliding binary anywhere in the source tree
# ---------------------------------------------------------------------------
Write-Head 'source tree audit'
$scanDirs = @($SourceRoot)
$scriptsDir = Join-Path $SourceRoot 'scripts'
if (Test-Path -LiteralPath $scriptsDir -PathType Container) { $scanDirs += $scriptsDir }

$taboo = @()
foreach ($dir in $scanDirs) {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force)) {
        $hit = Test-Forbidden $f.Name $SourceTabooPatterns
        if ($hit) { $taboo += "$($f.FullName)   [matched '$hit']" }
    }
}
if ($taboo.Count -gt 0) {
    Stop-Bad 'the source tree contains files that must never be near a release' (
        @(
            'Found signing material and/or a colliding driver binary:'
        ) + $taboo + @(
            '',
            'MagicMouseDriver.sys is the live oem16 / Apr 30 name and installing it',
            'would overwrite an existing package. A .cat is built on the user PC, not',
            'shipped. A .cer/.pfx/.p12/.pvk/.key must never leave the signing machine.',
            'Move them out of the driver directory and run this again.'
        )
    )
}
Write-Host "   clean: no .cat / .cer / .pfx / .p12 / .pvk / .key / MagicMouseDriver.sys"

# ---------------------------------------------------------------------------
# 3. The shipped driver binary must be the frozen unsigned one
# ---------------------------------------------------------------------------
Write-Head 'driver binary'
$sysPath = Join-Path $SourceRoot $DriverSys
$sysItem = Get-Item -LiteralPath $sysPath
$sysHash = Get-Sha256 $sysPath
$expect  = $ExpectedSysSha256.ToLowerInvariant()

if ($sysItem.Length -ne $DriverBytes) {
    Stop-Bad 'the driver binary is the wrong size' @(
        "$DriverSys",
        "  expected $DriverBytes bytes",
        "  actual   $($sysItem.Length) bytes"
    )
}
if ($sysHash -ne $expect) {
    Stop-Bad 'the driver binary does not match the frozen hash' @(
        "$DriverSys",
        "  expected $expect",
        "  actual   $sysHash",
        '',
        'Either the wrong binary is in the tree, or it has been signed in place.',
        'The shipped copy must be the UNSIGNED freeze - each user signs their own.'
    )
}
if (Get-AuthenticodeSignature -LiteralPath $sysPath | Where-Object { $_.Status -ne 'NotSigned' }) {
    Stop-Bad 'the driver binary carries a signature' @(
        'The community build ships UNSIGNED on purpose. A signature here would mean',
        'publishing a kernel binary signed with a private key. Restore the freeze.'
    )
}
Write-Host "   $DriverSys  $($sysItem.Length) bytes  $sysHash"
Write-Host '   UNSIGNED as intended - the wizard signs it on the user PC.'

# ---------------------------------------------------------------------------
# 4. Regenerate SHA256SUMS.txt from the real bytes
# ---------------------------------------------------------------------------
Write-Head 'checksums'
$sumLines = New-Object System.Collections.Generic.List[string]
$sumLines.Add("# SHA256 checksums for the Magic Mouse v3 (PID 0323) scroll driver, community build $Version")
$sumLines.Add('#')
$sumLines.Add('# Verify one file with:   certutil -hashfile <file> SHA256')
$sumLines.Add('#              or:        sha256sum <file>            (Linux / macOS / WSL)')
$sumLines.Add('#')
$sumLines.Add("# $SumsName itself is not listed - it cannot contain its own hash.")
$sumLines.Add('# Regenerated by scripts\make-community-zip.ps1 at release time; a trailing')
$sumLines.Add('# "#" comment on a line is a note, not part of the checksum.')
$sumLines.Add('')

foreach ($rel in $Manifest) {
    if ($rel -eq $SumsName) { continue }
    $h = Get-Sha256 (Join-Path $SourceRoot $rel)
    $line = "$h  $($rel -replace '\\','/')"
    if ($rel -eq $DriverSys) {
        $line += '   # UNSIGNED driver - Setup-Community.cmd signs this locally with a certificate made on your own PC'
    }
    $sumLines.Add($line)
}
$sumsText = ($sumLines -join "`r`n") + "`r`n"
$sumsPath = Join-Path $SourceRoot $SumsName

if ($VerifySumsOnly) {
    if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
        Stop-Bad "$SumsName is missing" @("expected at $sumsPath")
    }
    $onDisk = [System.IO.File]::ReadAllText($sumsPath)
    if ($onDisk -ne $sumsText) {
        $a = @($onDisk  -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
        $b = @($sumsText -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
        $diff = @(Compare-Object -ReferenceObject $a -DifferenceObject $b |
                  ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
        if ($diff.Count -eq 0) { $diff = @('(only header/whitespace differs)') }
        Stop-Bad "$SumsName is out of date" (
            @('Committed checksums do not match the files on disk:') + $diff +
            @('', 'Run make-community-zip.ps1 without -VerifySumsOnly to regenerate it.')
        )
    }
    Write-Host "   $SumsName matches the files on disk."
    Write-Head 'verify-only run finished - nothing was written'
    exit 0
}

[System.IO.File]::WriteAllText($sumsPath, $sumsText, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "   wrote $sumsPath  ($($Manifest.Count - 1) entries)"

# ---------------------------------------------------------------------------
# 5. Stage exactly the manifest
# ---------------------------------------------------------------------------
Write-Head 'staging'
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("mm-community-stage-" + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($rel in $Manifest) {
        $dst = Join-Path $stage $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $SourceRoot $rel) -Destination $dst -Force
    }

    # ---- 6. Audit what is actually about to be zipped -----------------------
    Write-Head 'payload audit'
    $staged = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force |
                ForEach-Object { $_.FullName.Substring($stage.Length + 1) })

    $extra = @($staged | Where-Object { $Manifest -notcontains $_ })
    if ($extra.Count -gt 0) {
        Stop-Bad 'the payload contains files that are not on the manifest' (
            @('Refusing to ship undeclared files:') + ($extra | ForEach-Object { "UNEXPECTED  $_" })
        )
    }
    $absent = @($Manifest | Where-Object { $staged -notcontains $_ })
    if ($absent.Count -gt 0) {
        Stop-Bad 'the payload is missing manifest files' ($absent | ForEach-Object { "MISSING  $_" })
    }

    $banned = @()
    foreach ($rel in $staged) {
        $hit = Test-Forbidden (Split-Path -Leaf $rel) $ForbiddenPatterns
        if ($hit) { $banned += "$rel   [matched '$hit']" }
    }
    if ($banned.Count -gt 0) {
        Stop-Bad 'the payload contains forbidden artifacts' (
            @('These must never reach a user:') + $banned
        )
    }
    Write-Host "   $($staged.Count) files, set matches the manifest exactly, none forbidden."

    # ---- 7. Zip ------------------------------------------------------------
    Write-Head 'archive'
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $zipPath = Join-Path $OutDir "magic-mouse-v3-scroll-community-$Version.zip"
    if (Test-Path -LiteralPath $zipPath) {
        if (-not $Force) {
            Stop-Bad 'the output ZIP already exists' @($zipPath, 'Pass -Force to overwrite it.')
        }
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal

    # Windows PowerShell 5.1's Compress-Archive writes '\' as the entry
    # separator, which the ZIP spec forbids: anything but Explorer then
    # extracts a file literally called "scripts\mm-f1-once.ps1". Rewrite the
    # entry names so the archive unpacks to a real scripts folder everywhere.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipEntries = @()
    $reader = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try { $zipEntries = @($reader.Entries | ForEach-Object { $_.FullName }) }
    finally { $reader.Dispose() }

    if (@($zipEntries | Where-Object { $_.Contains('\') }).Count -gt 0) {
        $normZip = "$zipPath.normalising"
        if (Test-Path -LiteralPath $normZip) { Remove-Item -LiteralPath $normZip -Force }
        $src = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $dst = [System.IO.Compression.ZipFile]::Open($normZip, 'Create')
            try {
                foreach ($entry in $src.Entries) {
                    $newEntry = $dst.CreateEntry(
                        $entry.FullName.Replace('\', '/'),
                        [System.IO.Compression.CompressionLevel]::Optimal)
                    $inStream  = $entry.Open()
                    $outStream = $newEntry.Open()
                    try { $inStream.CopyTo($outStream) }
                    finally { $outStream.Dispose(); $inStream.Dispose() }
                }
            }
            finally { $dst.Dispose() }
        }
        finally { $src.Dispose() }
        Move-Item -LiteralPath $normZip -Destination $zipPath -Force

        $reader = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try { $zipEntries = @($reader.Entries | ForEach-Object { $_.FullName }) }
        finally { $reader.Dispose() }
    }

    # ---- 8. Report ---------------------------------------------------------
    Write-Head "packaged $($staged.Count) files"
    foreach ($rel in $Manifest) {
        $f = Get-Item -LiteralPath (Join-Path $stage $rel)
        Write-Host ("   {0,8}  {1,-64}  {2}" -f $f.Length, ($rel -replace '\\','/'), (Get-Sha256 $f.FullName))
    }

    Write-Head 'archive entries as a user will see them'
    foreach ($e in ($zipEntries | Sort-Object)) { Write-Host "   $e" }

    $zipItem = Get-Item -LiteralPath $zipPath
    Write-Head 'result'
    Write-Host "   ZIP     : $zipPath"
    Write-Host "   bytes   : $($zipItem.Length)"
    Write-Host "   SHA256  : $(Get-Sha256 $zipPath)"
    Write-Host ''
    Write-Host '   Publish this ZIP as-is. The user unzips it and double-clicks'
    Write-Host '   Setup-Community.cmd - nothing else.'
    Write-Host ''
    exit 0
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
