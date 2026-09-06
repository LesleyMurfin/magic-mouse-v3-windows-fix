<#
.SYNOPSIS
    Aggregated quality-gate runner for M12 driver PRs.

.DESCRIPTION
    Calls run-prefast.ps1 then run-sdv.ps1 sequentially. Aggregates their
    JSON outputs into a single gate-results.json and gate-report.md.

    Exit 0 only if BOTH PREfast and SDV pass.
    Exit 1 if either gate fails.
    Exit 2 if either gate hits a pre-flight error (EWDK missing, solution missing).

    This is the canonical entry point for Phase 3 driver agents. It is also
    the script whose exit code the admin-task-queue BUILD route checks when
    agents ask "did quality gates pass?".

    Sequential execution is intentional: PREfast is fast (~1-2 min) and
    catches issues SDV would also flag. Running SDV on a PREfast-failing tree
    wastes 5-20 min and produces noise.

.PARAMETER SolutionPath
    Absolute Windows path to M12.sln.

.PARAMETER Configuration
    msbuild Configuration property for PREfast. Default: Release.

.PARAMETER Platform
    msbuild Platform property. Default: x64.

.PARAMETER EwdkRoot
    Root of the mounted EWDK ISO. Default: F:\

.PARAMETER OutputDir
    Parent directory for gate output. PREfast and SDV subdirs created inside.
    Default: C:\mm-dev-queue\quality-gates-<timestamp>

.PARAMETER SkipSdv
    Skip SDV and run only PREfast. Use when a quick pre-commit check is needed
    and full SDV turnaround is too slow. SDV is still required before merge.

.EXAMPLE
    # Full gates (Phase 3 standard run):
    .\run-quality-gates.ps1 -SolutionPath '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\driver\M12.sln'

.EXAMPLE
    # PREfast only (fast pre-commit check):
    .\run-quality-gates.ps1 -SolutionPath 'C:\src\driver\M12.sln' -SkipSdv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SolutionPath,

    [ValidateSet('Release','Debug')]
    [string]$Configuration = 'Release',

    [ValidateSet('x64','x86','ARM64')]
    [string]$Platform = 'x64',

    [string]$EwdkRoot = 'F:\',

    [string]$OutputDir = '',

    [switch]$SkipSdv
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][quality-gates][$Level] $Msg"
    if ($script:MasterLog) {
        Add-Content -Path $script:MasterLog -Value $line -Encoding UTF8
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'HEAD'  { Write-Host "`n$line" -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
if (-not $OutputDir) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = "C:\mm-dev-queue\quality-gates-$ts"
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$MasterLog   = Join-Path $OutputDir 'quality-gates.log'
$PrefastDir  = Join-Path $OutputDir 'prefast'
$SdvDir      = Join-Path $OutputDir 'sdv'
$JsonOut     = Join-Path $OutputDir 'gate-results.json'
$MdOut       = Join-Path $OutputDir 'gate-report.md'

Write-Log "=== run-quality-gates.ps1 ===" 'HEAD'
Write-Log "Solution   : $SolutionPath"
Write-Log "Config     : $Configuration / $Platform"
Write-Log "EWDK root  : $EwdkRoot"
Write-Log "Output dir : $OutputDir"
Write-Log "Skip SDV   : $($SkipSdv.IsPresent)"

# ---------------------------------------------------------------------------
# Locate sibling scripts (same directory as this script)
# ---------------------------------------------------------------------------
$ScriptDir   = $PSScriptRoot
$PrefastScr  = Join-Path $ScriptDir 'run-prefast.ps1'
$SdvScr      = Join-Path $ScriptDir 'run-sdv.ps1'

foreach ($scr in @($PrefastScr, $SdvScr)) {
    if (-not (Test-Path $scr)) {
        Write-Log "Required script not found: $scr" 'ERROR'
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Gate 1: PREfast
# ---------------------------------------------------------------------------
Write-Log "--- Gate 1: PREfast ---" 'HEAD'
$prefastStart = Get-Date

$prefastArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PrefastScr,
    '-SolutionPath', $SolutionPath,
    '-Configuration', $Configuration,
    '-Platform', $Platform,
    '-EwdkRoot', $EwdkRoot,
    '-OutputDir', $PrefastDir
)
$prefastProc = Start-Process powershell.exe -ArgumentList $prefastArgs -Wait -PassThru -NoNewWindow
$prefastExit = $prefastProc.ExitCode
$prefastDuration = [int](New-TimeSpan -Start $prefastStart -End (Get-Date)).TotalSeconds

Write-Log "PREfast exit: $prefastExit  (${prefastDuration}s)"

$prefastJson = Join-Path $PrefastDir 'prefast-results.json'
$prefastData = $null
if (Test-Path $prefastJson) {
    $prefastData = Get-Content $prefastJson | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Gate 2: SDV (skipped if -SkipSdv or PREfast had pre-flight failure)
# ---------------------------------------------------------------------------
$sdvExit     = -1
$sdvDuration = 0
$sdvData     = $null
$sdvSkipped  = $false

if ($SkipSdv) {
    Write-Log "SDV skipped (SkipSdv flag set)." 'WARN'
    $sdvSkipped = $true
} elseif ($prefastExit -eq 2) {
    Write-Log "SDV skipped: PREfast pre-flight failed (EWDK or solution not found)." 'WARN'
    $sdvSkipped = $true
} else {
    Write-Log "--- Gate 2: SDV ---" 'HEAD'
    $sdvStart = Get-Date

    $sdvArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SdvScr,
        '-SolutionPath', $SolutionPath,
        '-EwdkRoot', $EwdkRoot,
        '-OutputDir', $SdvDir
    )
    $sdvProc = Start-Process powershell.exe -ArgumentList $sdvArgs -Wait -PassThru -NoNewWindow
    $sdvExit = $sdvProc.ExitCode
    $sdvDuration = [int](New-TimeSpan -Start $sdvStart -End (Get-Date)).TotalSeconds

    Write-Log "SDV exit: $sdvExit  (${sdvDuration}s)"

    $sdvJsonPath = Join-Path $SdvDir 'sdv-results.json'
    if (Test-Path $sdvJsonPath) {
        $sdvData = Get-Content $sdvJsonPath | ConvertFrom-Json
    }
}

# ---------------------------------------------------------------------------
# Aggregate result
# Gate passes only if both pass (or SDV explicitly skipped with note).
# SDV skip = gate does NOT fully pass (blocks PR merge; only PREfast-check mode).
# ---------------------------------------------------------------------------
$prefastPassed = ($prefastExit -eq 0)
$sdvPassed     = ($sdvExit -eq 0)
# Senior-dev review MAJ-1: previous $allPassed had wrong operator precedence
# (always evaluated as $prefastPassed alone) and was unused downstream.
# Removed entirely; downstream logic uses $fullyPassed / $preOnlyMode.

# Fully passed = both exit 0 with no skip required.
# Partial (PREfast only) = informational; merge still blocked pending SDV.
$fullyPassed = ($prefastExit -eq 0 -and $sdvExit -eq 0)
$preOnlyMode = ($prefastExit -eq 0 -and $sdvSkipped)

# ---------------------------------------------------------------------------
# Emit gate-results.json
# ---------------------------------------------------------------------------
$aggregate = @{
    tool           = 'quality-gates'
    timestamp      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    solution       = $SolutionPath
    configuration  = "$Configuration/$Platform"
    fully_passed   = $fullyPassed
    prefast_only   = $preOnlyMode
    prefast = @{
        exit     = $prefastExit
        passed   = $prefastPassed
        duration = $prefastDuration
        warnings = if ($prefastData) { $prefastData.warning_count } else { -1 }
        report   = (Join-Path $PrefastDir 'prefast-report.md')
        json     = $prefastJson
    }
    sdv = @{
        exit       = $sdvExit
        passed     = $sdvPassed
        skipped    = $sdvSkipped
        duration   = $sdvDuration
        violations = if ($sdvData) { $sdvData.violation_count } else { -1 }
        report     = (Join-Path $SdvDir 'sdv-report.md')
        json       = (Join-Path $SdvDir 'sdv-results.json')
    }
}

$aggregateJson = $aggregate | ConvertTo-Json -Depth 5
Set-Content -Path $JsonOut -Value $aggregateJson -Encoding UTF8
Write-Log "Aggregate JSON: $JsonOut" 'OK'

# ---------------------------------------------------------------------------
# Emit gate-report.md (PR-comment-ready, combines both gates)
# ---------------------------------------------------------------------------
$overallStatus = if ($fullyPassed) { 'PASS' } elseif ($preOnlyMode) { 'PARTIAL (SDV pending)' } else { 'FAIL' }

$prefastStatus = if ($prefastPassed) { 'PASS' } elseif ($prefastExit -eq 2) { 'PRE-FLIGHT ERROR' } else { 'FAIL' }
$sdvStatus     = if ($sdvSkipped)    { 'SKIPPED' } elseif ($sdvPassed) { 'PASS' } elseif ($sdvExit -eq 2) { 'PRE-FLIGHT ERROR' } else { 'FAIL' }

$mdLines = [System.Collections.Generic.List[string]]::new()
$mdLines.Add("## M12 Quality Gates Report")
$mdLines.Add("")
$mdLines.Add("| Gate | Status | Detail | Duration |")
$mdLines.Add("|---|---|---|---|")

$prefastWarn  = if ($prefastData) { "$($prefastData.warning_count) warnings" } else { 'n/a' }
$sdvViol      = if ($sdvData) { "$($sdvData.violation_count) violations" } else { if ($sdvSkipped) { 'skipped' } else { 'n/a' } }

$mdLines.Add("| PREfast | $prefastStatus | $prefastWarn | ${prefastDuration}s |")
$mdLines.Add("| SDV     | $sdvStatus     | $sdvViol     | ${sdvDuration}s |")
$mdLines.Add("")
$mdLines.Add("**Overall: $overallStatus**")
$mdLines.Add("")

if ($fullyPassed) {
    $mdLines.Add("Both PREfast and SDV passed. PR may proceed to reviewer chain.")
} elseif ($preOnlyMode) {
    $mdLines.Add("PREfast passed. SDV was skipped (SkipSdv mode). Full SDV run required before merge.")
} else {
    $mdLines.Add("One or more gates failed. PR is blocked until all gates pass.")
    $mdLines.Add("")
    if (-not $prefastPassed) {
        $prefastMd = Join-Path $PrefastDir 'prefast-report.md'
        $mdLines.Add("**PREfast details**: see ``$prefastMd``")
    }
    if (-not $sdvPassed -and -not $sdvSkipped) {
        $sdvMd = Join-Path $SdvDir 'sdv-report.md'
        $mdLines.Add("**SDV details**: see ``$sdvMd``")
    }
}

$mdLines.Add("")
$mdLines.Add("---")
$mdLines.Add("_Generated by run-quality-gates.ps1 at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')_")

Set-Content -Path $MdOut -Value ($mdLines -join "`n") -Encoding UTF8
Write-Log "Aggregate report: $MdOut" 'OK'

# ---------------------------------------------------------------------------
# Copy individual gate reports alongside aggregate for easy browsing
# ---------------------------------------------------------------------------
$prefastMdSrc = Join-Path $PrefastDir 'prefast-report.md'
if (Test-Path $prefastMdSrc) {
    Copy-Item $prefastMdSrc (Join-Path $OutputDir 'prefast-report.md') -Force
}
$sdvMdSrc = Join-Path $SdvDir 'sdv-report.md'
if (Test-Path $sdvMdSrc) {
    Copy-Item $sdvMdSrc (Join-Path $OutputDir 'sdv-report.md') -Force
}

# ---------------------------------------------------------------------------
# Final summary + exit
# ---------------------------------------------------------------------------
Write-Log "=== QUALITY GATES SUMMARY ===" 'HEAD'
Write-Log "PREfast : $prefastStatus (exit $prefastExit, ${prefastDuration}s)"
Write-Log "SDV     : $sdvStatus (exit $sdvExit, ${sdvDuration}s)"
Write-Log "Overall : $overallStatus"
Write-Log "Output  : $OutputDir"

if ($fullyPassed) {
    Write-Log "Quality gates: FULLY PASSED" 'OK'
    exit 0
} elseif ($prefastExit -eq 2 -or $sdvExit -eq 2) {
    Write-Log "Quality gates: PRE-FLIGHT ERROR -- EWDK or solution not found" 'ERROR'
    exit 2
} else {
    Write-Log "Quality gates: FAILED -- fix issues and re-run" 'ERROR'
    exit 1
}
