#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Validates internal link integrity of the published docs/ site and of tracked Markdown.

.DESCRIPTION
    Offline link gate. Performs five checks and emits GitHub Actions error annotations
    for every finding:

      1. Internal HTML targets  - every relative href/src in docs/*.html resolves on disk.
      2. Sitemap coverage       - every <loc> maps to a real file, every page is listed,
                                  and 404.html is never listed.
      3. Declared site base     - robots.txt's Sitemap: line declares where the site is
                                  published; every <loc> must live under that base, and
                                  that base must address this sitemap.xml.
      4. Canonical sanity       - every <link rel="canonical"> URL appears as a <loc>.
      5. Markdown links         - every relative ](target) in tracked *.md resolves.

    External HTTP(S) links are deliberately NOT checked: third-party availability is not
    this repository's correctness, and network flake must never redden main.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of the directory containing this script.

.PARAMETER SiteDir
    Published site directory, relative to RepoRoot (or absolute). Defaults to 'docs'.

.PARAMETER SiteBaseUrl
    Published base URL of the site, ending in '/'. Defaults to the base declared by the
    Sitemap: line in <SiteDir>/robots.txt. Pass this only for a site that cannot declare
    its own base; the base is never guessed from the sitemap contents.

.PARAMETER Quiet
    Suppress the per-check count lines and the summary table. Error annotations are
    always emitted.

.OUTPUTS
    Exit code 1 if any finding was recorded, otherwise 0.

.EXAMPLE
    pwsh -File scripts/Test-SiteLink.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent -Path $PSScriptRoot),
    [string]$SiteDir = 'docs',
    [string]$SiteBaseUrl = '',
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRootFull = ''
$script:Finding = [System.Collections.Generic.List[psobject]]::new()
$script:CheckResult = [System.Collections.Generic.List[psobject]]::new()

function Get-RepoRelativePath {
    <#
    .SYNOPSIS
        Convert an absolute path to a forward-slash path relative to the repository root.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { return '' }

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($script:RepoRootFull -and $full.StartsWith($script:RepoRootFull, [System.StringComparison]::Ordinal)) {
        $full = $full.Substring($script:RepoRootFull.Length)
    }
    return ($full -replace '\\', '/').TrimStart('/')
}

function Add-Finding {
    <#
    .SYNOPSIS
        Record a finding and emit the matching GitHub Actions error annotation.
    #>
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$Path = '',
        [int]$Line = 0
    )

    $relative = Get-RepoRelativePath -Path $Path
    $script:Finding.Add([pscustomobject]@{
            Check   = $Check
            Path    = $relative
            Line    = $Line
            Message = $Message
        })

    if ($relative) {
        Write-Host "::error file=$relative,line=$Line::$Message"
    }
    else {
        Write-Host "::error::$Message"
    }
}

function Add-CheckResult {
    <#
    .SYNOPSIS
        Record how many items a check extracted and how many it verified.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Inspected,
        [Parameter(Mandatory)][int]$Checked,
        [Parameter(Mandatory)][string]$Unit
    )

    $script:CheckResult.Add([pscustomobject]@{
            Name      = $Name
            Inspected = $Inspected
            Checked   = $Checked
            Unit      = $Unit
        })
}

function Test-ExternalTarget {
    <#
    .SYNOPSIS
        True when a link target must not be resolved against the filesystem.
    .DESCRIPTION
        Covers absolute URLs of any scheme (http, https, mailto, tel, data, javascript),
        protocol-relative //host/path, fragment-only targets, and empty values.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $trimmed = $Value.Trim()
    if ([string]::IsNullOrEmpty($trimmed)) { return $true }
    if ($trimmed.StartsWith('#')) { return $true }
    if ($trimmed.StartsWith('//')) { return $true }
    if ($trimmed -match '^[A-Za-z][A-Za-z0-9+.-]*:') { return $true }
    return $false
}

function Resolve-LinkTarget {
    <#
    .SYNOPSIS
        Resolve a relative or root-relative link target to an absolute filesystem path.
    .DESCRIPTION
        Strips ?query and #fragment, percent-decodes, resolves '.' and '..' segments,
        and treats a leading '/' as the serving root (GitHub Pages serves the site
        directory at the domain root). With -IndexDirectory, a trailing '/' or an
        existing directory maps to its index.html.
        Returns $null when the value carries no path component.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$RootDirectory,
        [switch]$IndexDirectory
    )

    $path = ($Value.Trim() -split '[?#]', 2)[0]
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }

    $decoded = [System.Uri]::UnescapeDataString($path)
    $rooted = $decoded.StartsWith('/')
    $trailingSlash = $decoded.EndsWith('/')

    $current = if ($rooted) { $RootDirectory } else { $BaseDirectory }
    foreach ($segment in $decoded.Split('/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            $parent = Split-Path -Parent -Path $current
            if ($parent) { $current = $parent }
            continue
        }
        $current = Join-Path -Path $current -ChildPath $segment
    }

    if ($IndexDirectory) {
        if ($trailingSlash -or (Test-Path -LiteralPath $current -PathType Container)) {
            $current = Join-Path -Path $current -ChildPath 'index.html'
        }
    }

    return $current
}

function Get-LineNumber {
    <#
    .SYNOPSIS
        One-based line number of a character offset within a text buffer.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Index
    )

    if ($Index -le 0) { return 1 }
    return ($Text.Substring(0, $Index).Split("`n").Count)
}

function Get-SiteRelativeUrlPath {
    <#
    .SYNOPSIS
        Path of an absolute site URL relative to the site base URL, or $null if outside it.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$BaseUrl
    )

    if (-not $Url.StartsWith($BaseUrl, [System.StringComparison]::Ordinal)) { return $null }
    $relative = $Url.Substring($BaseUrl.Length)
    if ([string]::IsNullOrEmpty($relative) -or $relative.EndsWith('/')) {
        $relative += 'index.html'
    }
    return [System.Uri]::UnescapeDataString($relative)
}

function Get-DeclaredSiteBase {
    <#
    .SYNOPSIS
        Site base URL declared by robots.txt, derived from its Sitemap: line.
    .DESCRIPTION
        robots.txt is the only file in the published site that states where the site is
        served from, so its Sitemap: URL is the authority for the base: the URL with the
        trailing 'sitemap.xml' removed. BaseUrl is empty when robots.txt declares nothing
        usable, and Problem then carries the reason. Callers must treat that as a finding:
        guessing a base makes every downstream URL comparison validate a fiction.
    #>
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$RobotsPath
    )

    $declared = [System.Collections.Generic.List[psobject]]::new()
    $result = [pscustomobject]@{ BaseUrl = ''; Declared = $declared; Problem = ''; ProblemLine = 1 }

    if (-not (Test-Path -LiteralPath $RobotsPath -PathType Leaf)) {
        $result.Problem = 'robots.txt is missing from the published site directory, so the site declares no published base URL.'
        return $result
    }

    $robotsLine = @(Get-Content -LiteralPath $RobotsPath)
    for ($index = 0; $index -lt $robotsLine.Count; $index++) {
        $match = [regex]::Match($robotsLine[$index], '(?i)^\s*Sitemap:\s*(\S+)\s*$')
        if ($match.Success) {
            $declared.Add([pscustomobject]@{ Url = $match.Groups[1].Value; Line = ($index + 1) })
        }
    }

    if ($declared.Count -eq 0) {
        $result.Problem = 'robots.txt has no Sitemap: line, so the site declares neither its sitemap nor its published base URL.'
        return $result
    }

    $base = @()
    foreach ($item in $declared) {
        # [Uri] accepts a bare '/path' as an absolute file:// URI on Unix, so the scheme
        # is asserted explicitly: the base must be a real http(s) location on both runners.
        $uri = $null
        if (-not [System.Uri]::TryCreate($item.Url, [System.UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https')) {
            $result.Problem = "robots.txt Sitemap: '$($item.Url)' is not an absolute http(s) URL, so the published base URL cannot be derived."
            $result.ProblemLine = $item.Line
            return $result
        }
        if (-not $item.Url.EndsWith('/sitemap.xml', [System.StringComparison]::Ordinal)) {
            $result.Problem = "robots.txt Sitemap: '$($item.Url)' does not end with '/sitemap.xml', so the published base URL cannot be derived."
            $result.ProblemLine = $item.Line
            return $result
        }
        $base += $item.Url.Substring(0, $item.Url.Length - 'sitemap.xml'.Length)
    }

    $distinctBase = @($base | Sort-Object -Unique)
    if ($distinctBase.Count -gt 1) {
        $result.Problem = "robots.txt declares conflicting Sitemap: bases ($($distinctBase -join ', ')); the published base URL is ambiguous."
        $result.ProblemLine = $declared[0].Line
        return $result
    }

    $result.BaseUrl = $distinctBase[0]
    return $result
}

function Get-TrackedMarkdownFile {
    <#
    .SYNOPSIS
        Absolute paths of tracked *.md files, falling back to a filesystem walk.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root
    )

    $tracked = @()
    try {
        $output = & git -C $Root ls-files '*.md' 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            $tracked = @($output | Where-Object { $_ } | ForEach-Object {
                    Join-Path -Path $Root -ChildPath ($_ -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                })
        }
    }
    catch {
        $tracked = @()
    }

    if ($tracked.Count -eq 0) {
        $tracked = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.md' |
                Where-Object { $_.FullName -notmatch '(^|[\\/])\.git([\\/]|$)' } |
                ForEach-Object { $_.FullName })
    }

    return @($tracked | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object)
}

# --------------------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    Write-Host "::error::RepoRoot '$RepoRoot' is not a directory."
    exit 1
}
$script:RepoRootFull = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
[System.IO.Path]::DirectorySeparatorChar

$sitePathRaw = if ([System.IO.Path]::IsPathRooted($SiteDir)) {
    $SiteDir
}
else {
    Join-Path -Path $script:RepoRootFull -ChildPath $SiteDir
}

if (-not (Test-Path -LiteralPath $sitePathRaw -PathType Container)) {
    Write-Host "::error::Site directory '$SiteDir' not found under '$RepoRoot'."
    exit 1
}
$siteRoot = (Resolve-Path -LiteralPath $sitePathRaw).Path

if (-not $Quiet) {
    Write-Host "Test-SiteLink"
    Write-Host "  repo root : $($script:RepoRootFull)"
    Write-Host "  site dir  : $(Get-RepoRelativePath -Path $siteRoot)"
}

# The published base URL is declared, never guessed: robots.txt's Sitemap: line is the
# site's own statement of where it is served from, and -SiteBaseUrl overrides it for a
# site that cannot declare one. A site that declares no base cannot be checked at all,
# so that is a finding rather than a fallback.
$robotsPath = Join-Path -Path $siteRoot -ChildPath 'robots.txt'
$robotsDeclaration = Get-DeclaredSiteBase -RobotsPath $robotsPath

if ([string]::IsNullOrWhiteSpace($SiteBaseUrl)) {
    $siteBase = $robotsDeclaration.BaseUrl
    $siteBaseSource = "$(Get-RepoRelativePath -Path $robotsPath) Sitemap:"
}
else {
    $siteBase = if ($SiteBaseUrl.EndsWith('/')) { $SiteBaseUrl } else { $SiteBaseUrl + '/' }
    $siteBaseSource = '-SiteBaseUrl'
}

if ([string]::IsNullOrWhiteSpace($siteBase)) {
    $baseMessage = "$($robotsDeclaration.Problem) Pass -SiteBaseUrl to check a site that cannot declare its own base."
    Add-Finding -Check 'site-base' -Path $robotsPath -Line $robotsDeclaration.ProblemLine -Message $baseMessage
    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'FAIL: 1 finding(s).'
        Write-Host "  [site-base] $(Get-RepoRelativePath -Path $robotsPath):$($robotsDeclaration.ProblemLine): $baseMessage"
    }
    exit 1
}

if (-not $Quiet) {
    Write-Host "  site base : $siteBase (from $siteBaseSource)"
    Write-Host ''
}

$htmlFile = @(Get-ChildItem -LiteralPath $siteRoot -Recurse -File -Filter '*.html' | Sort-Object -Property FullName)

# --------------------------------------------------------------------------------------
# Check 1 - internal HTML href/src targets resolve on disk
# --------------------------------------------------------------------------------------

$attributeRegex = [regex]'(?i)\b(?:href|src)\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$attributeInspected = 0
$attributeChecked = 0

foreach ($file in $htmlFile) {
    $line = @(Get-Content -LiteralPath $file.FullName)
    for ($index = 0; $index -lt $line.Count; $index++) {
        foreach ($match in $attributeRegex.Matches($line[$index])) {
            $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            $attributeInspected++
            if (Test-ExternalTarget -Value $value) { continue }

            $target = Resolve-LinkTarget -Value $value -BaseDirectory $file.DirectoryName -RootDirectory $siteRoot -IndexDirectory
            if ($null -eq $target) { continue }

            $attributeChecked++
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                Add-Finding -Check 'html-target' -Path $file.FullName -Line ($index + 1) `
                    -Message "Broken internal target '$value' (resolves to $(Get-RepoRelativePath -Path $target), which does not exist)"
            }
        }
    }
}

Add-CheckResult -Name 'HTML internal targets' -Inspected $attributeInspected -Checked $attributeChecked -Unit 'href/src values'

# --------------------------------------------------------------------------------------
# Check 2 - sitemap covers exactly the published page set (404.html excluded)
# --------------------------------------------------------------------------------------

$sitemapPath = Join-Path -Path $siteRoot -ChildPath 'sitemap.xml'
$locEntry = @()
$sitemapRaw = ''

if (-not (Test-Path -LiteralPath $sitemapPath -PathType Leaf)) {
    Add-Finding -Check 'sitemap' -Path $sitemapPath -Line 1 -Message 'sitemap.xml is missing from the published site directory.'
}
else {
    $sitemapRaw = Get-Content -LiteralPath $sitemapPath -Raw
    try {
        $null = [xml]$sitemapRaw
    }
    catch {
        Add-Finding -Check 'sitemap' -Path $sitemapPath -Line 1 -Message "sitemap.xml is not well-formed XML: $($_.Exception.Message)"
    }

    $sitemapLine = @(Get-Content -LiteralPath $sitemapPath)
    $locRegex = [regex]'(?i)<loc>\s*([^<\s]+)\s*</loc>'
    for ($index = 0; $index -lt $sitemapLine.Count; $index++) {
        foreach ($match in $locRegex.Matches($sitemapLine[$index])) {
            $locEntry += [pscustomobject]@{ Url = $match.Groups[1].Value; Line = ($index + 1) }
        }
    }
}

$locUrl = @($locEntry | ForEach-Object { $_.Url })
$sitemapRelativePath = @()

foreach ($entry in $locEntry) {
    # A <loc> outside the declared base has no file behind it here; check 3 owns that
    # finding, and the page it failed to index surfaces below as unindexed.
    $relative = Get-SiteRelativeUrlPath -Url $entry.Url -BaseUrl $siteBase
    if ($null -eq $relative) { continue }

    $sitemapRelativePath += $relative

    $target = Resolve-LinkTarget -Value $relative -BaseDirectory $siteRoot -RootDirectory $siteRoot
    if ($null -eq $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Add-Finding -Check 'sitemap' -Path $sitemapPath -Line $entry.Line `
            -Message "Dead sitemap URL '$($entry.Url)': no file at $(Get-RepoRelativePath -Path $target)."
    }

    if ($relative -eq '404.html') {
        Add-Finding -Check 'sitemap' -Path $sitemapPath -Line $entry.Line `
            -Message 'An error page must never be listed in the sitemap: remove the 404.html <loc>.'
    }
}

foreach ($file in $htmlFile) {
    $relative = (Get-RepoRelativePath -Path $file.FullName)
    $siteRelative = $relative.Substring((Get-RepoRelativePath -Path $siteRoot).Length).TrimStart('/')
    if ($siteRelative -eq '404.html') { continue }
    if ($sitemapRelativePath -notcontains $siteRelative) {
        Add-Finding -Check 'sitemap' -Path $file.FullName -Line 1 `
            -Message "Unindexed page: '$siteRelative' has no <loc> entry in sitemap.xml."
    }
}

Add-CheckResult -Name 'Sitemap coverage' -Inspected $locEntry.Count -Checked $htmlFile.Count -Unit '<loc> entries vs html pages'

# --------------------------------------------------------------------------------------
# Check 3 - every <loc> lives under the declared base, and that base addresses this
#           sitemap.xml. Comparing the base against robots.txt would be circular when the
#           base came from robots.txt, so both assertions are made against the sitemap
#           entries and the file on disk instead.
# --------------------------------------------------------------------------------------

$locUnderBase = 0
foreach ($entry in $locEntry) {
    # Scheme asserted explicitly: [Uri] reads a bare '/path' as an absolute file:// URI on
    # Unix, which would smuggle a root-relative <loc> past this gate on ubuntu runners.
    $uri = $null
    if (-not [System.Uri]::TryCreate($entry.Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https')) {
        Add-Finding -Check 'site-base' -Path $sitemapPath -Line $entry.Line `
            -Message "<loc> '$($entry.Url)' is not an absolute http(s) URL; sitemap entries must be fully qualified."
        continue
    }

    if (-not $entry.Url.StartsWith($siteBase, [System.StringComparison]::Ordinal)) {
        Add-Finding -Check 'site-base' -Path $sitemapPath -Line $entry.Line `
            -Message "<loc> '$($entry.Url)' is not under the declared site base '$siteBase' (from $siteBaseSource); the pages do not live where the site says they are published, so crawlers would drop them."
        continue
    }

    $locUnderBase++
}

$expectedSitemapUrl = $siteBase + 'sitemap.xml'
$sitemapUrlChecked = 0

if (-not (Test-Path -LiteralPath $robotsPath -PathType Leaf)) {
    Add-Finding -Check 'site-base' -Path $robotsPath -Line 1 -Message 'robots.txt is missing from the published site directory.'
}
elseif ($robotsDeclaration.Declared.Count -eq 0) {
    Add-Finding -Check 'site-base' -Path $robotsPath -Line 1 `
        -Message 'robots.txt has no Sitemap: line; crawlers will not discover sitemap.xml.'
}
else {
    foreach ($item in $robotsDeclaration.Declared) {
        if ($item.Url -ne $expectedSitemapUrl) {
            Add-Finding -Check 'site-base' -Path $robotsPath -Line $item.Line `
                -Message "robots.txt Sitemap: '$($item.Url)' does not address the sitemap served at the site base '$siteBase' (from $siteBaseSource); expected '$expectedSitemapUrl'."
            continue
        }

        if (-not (Test-Path -LiteralPath $sitemapPath -PathType Leaf)) {
            Add-Finding -Check 'site-base' -Path $robotsPath -Line $item.Line `
                -Message "robots.txt Sitemap: '$expectedSitemapUrl' has nothing behind it: $(Get-RepoRelativePath -Path $sitemapPath) does not exist."
            continue
        }

        $sitemapUrlChecked++
    }
}

Add-CheckResult -Name 'Sitemap URLs vs site base' `
    -Inspected ($locEntry.Count + $robotsDeclaration.Declared.Count) `
    -Checked ($locUnderBase + $sitemapUrlChecked) `
    -Unit '<loc> URLs + robots.txt Sitemap:'

# --------------------------------------------------------------------------------------
# Check 4 - canonical URLs are present in the sitemap
# --------------------------------------------------------------------------------------

$canonicalRegex = [regex]'(?is)<link\b[^>]*\brel\s*=\s*["'']canonical["''][^>]*>'
$hrefRegex = [regex]'(?i)\bhref\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
$canonicalInspected = 0
$canonicalChecked = 0

foreach ($file in $htmlFile) {
    if ($file.Name -eq '404.html') { continue }

    $raw = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in $canonicalRegex.Matches($raw)) {
        $canonicalInspected++
        $hrefMatch = $hrefRegex.Match($match.Value)
        $line = Get-LineNumber -Text $raw -Index $match.Index

        if (-not $hrefMatch.Success) {
            Add-Finding -Check 'canonical' -Path $file.FullName -Line $line `
                -Message 'Canonical <link> has no href attribute.'
            continue
        }

        $url = if ($hrefMatch.Groups[1].Success) { $hrefMatch.Groups[1].Value } else { $hrefMatch.Groups[2].Value }
        $canonicalChecked++
        if ($locUrl -notcontains $url) {
            Add-Finding -Check 'canonical' -Path $file.FullName -Line $line `
                -Message "Self-delisting page: canonical '$url' is not a <loc> in sitemap.xml."
        }
    }
}

Add-CheckResult -Name 'Canonical vs sitemap' -Inspected $canonicalInspected -Checked $canonicalChecked -Unit 'canonical links'

# --------------------------------------------------------------------------------------
# Check 5 - relative Markdown links resolve
# --------------------------------------------------------------------------------------

$markdownFile = Get-TrackedMarkdownFile -Root $script:RepoRootFull
$markdownRegex = [regex]'\]\(\s*<?([^)<>\s]+)>?(?:\s+(?:"[^"]*"|''[^'']*''|\([^)]*\)))?\s*\)'
$markdownInspected = 0
$markdownChecked = 0

foreach ($path in $markdownFile) {
    $directory = Split-Path -Parent -Path $path
    $line = @(Get-Content -LiteralPath $path)
    for ($index = 0; $index -lt $line.Count; $index++) {
        foreach ($match in $markdownRegex.Matches($line[$index])) {
            $value = $match.Groups[1].Value
            $markdownInspected++
            if (Test-ExternalTarget -Value $value) { continue }

            $target = Resolve-LinkTarget -Value $value -BaseDirectory $directory -RootDirectory $script:RepoRootFull
            if ($null -eq $target) { continue }

            $markdownChecked++
            if (-not (Test-Path -LiteralPath $target)) {
                Add-Finding -Check 'markdown-link' -Path $path -Line ($index + 1) `
                    -Message "Broken Markdown link '$value' (resolves to $(Get-RepoRelativePath -Path $target), which does not exist)"
            }
        }
    }
}

Add-CheckResult -Name 'Markdown internal links' -Inspected $markdownInspected -Checked $markdownChecked -Unit 'inline link targets'

# --------------------------------------------------------------------------------------
# Extraction sanity - a check that saw nothing means the extractor is broken
# --------------------------------------------------------------------------------------

foreach ($result in $script:CheckResult) {
    if ($result.Inspected -eq 0) {
        Add-Finding -Check 'extraction' `
            -Message "Check '$($result.Name)' inspected 0 $($result.Unit); the extractor matched nothing, so this gate proved nothing."
    }
}

# --------------------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------------------

if (-not $Quiet) {
    Write-Host ''
    Write-Host 'Check                        Inspected  Verified  Unit'
    Write-Host '---------------------------  ---------  --------  ----------------------------'
    foreach ($result in $script:CheckResult) {
        Write-Host ('{0,-27}  {1,9}  {2,8}  {3}' -f $result.Name, $result.Inspected, $result.Checked, $result.Unit)
    }

    Write-Host ''
    if ($script:Finding.Count -eq 0) {
        Write-Host 'PASS: no broken internal links, sitemap drift, or canonical drift.'
    }
    else {
        Write-Host "FAIL: $($script:Finding.Count) finding(s)."
        foreach ($item in $script:Finding) {
            $where = if ($item.Path) { "$($item.Path):$($item.Line)" } else { '(repository)' }
            Write-Host "  [$($item.Check)] ${where}: $($item.Message)"
        }
    }
}

if ($script:Finding.Count -gt 0) { exit 1 }
exit 0
