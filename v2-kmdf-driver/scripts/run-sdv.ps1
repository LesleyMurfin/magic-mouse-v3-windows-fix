<#
.SYNOPSIS
    Static Driver Verifier (SDV) gate for M12 driver builds.

.DESCRIPTION
    Invokes SDV via EWDK msbuild using the sdv target. Parses the SDV report
    XML/log for violations. Emits sdv-results.json and sdv-report.md to
    OutputDir for PR-comment integration.

    Exit 0 = 0 violations (gate passes).
    Exit 1 = 1+ violations (gate fails; PR is blocked).
    Exit 2 = pre-flight failure (EWDK not mounted, solution missing).

    SDV is substantially slower than PREfast (minutes to hours for complex
    drivers). For M12 v1 at ~250 LOC total, typical SDV time is 5-20 min.

    Called by Phase 3 driver agents or from run-quality-gates.ps1.

.PARAMETER SolutionPath
    Absolute Windows path to M12.sln. Must be accessible from the admin-queue
    context (e.g. \\wsl.localhost\Ubuntu\... or a local copy).

.PARAMETER EwdkRoot
    Root of the mounted EWDK ISO. Default: F:\

.PARAMETER SdvRuleSet
    SDV rule-set argument passed to /p:Inputs. Default: /check:default.sdv
    (runs the standard KMDF/WDM rule set including cancellation, IRP handling,
    lock discipline, and power management rules).

.PARAMETER OutputDir
    Directory where sdv-results.json and sdv-report.md are written.
    Default: C:\mm-dev-queue\sdv-<timestamp>

.PARAMETER LogFile
    Full path for verbose SDV log. Default: OutputDir\sdv-build.log

.EXAMPLE
    # Standalone (Phase 3+, when M12.sln exists):
    .\run-sdv.ps1 -SolutionPath 'C:\src\driver\M12.sln'

.EXAMPLE
    # With custom rule set:
    .\run-sdv.ps1 -SolutionPath 'C:\src\driver\M12.sln' -SdvRuleSet '/check:WdfDriverEntry.slic'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SolutionPath,

    [string]$EwdkRoot = 'F:\',

    [string]$SdvRuleSet = '/check:default.sdv',

    [string]$OutputDir = '',

    [string]$LogFile = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][sdv][$Level] $Msg"
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

# ---------------------------------------------------------------------------
# Resolve output paths
# ---------------------------------------------------------------------------
if (-not $OutputDir) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = "C:\mm-dev-queue\sdv-$ts"
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

if (-not $LogFile) {
    $LogFile = Join-Path $OutputDir 'sdv-build.log'
}

$JsonOut = Join-Path $OutputDir 'sdv-results.json'
$MdOut   = Join-Path $OutputDir 'sdv-report.md'

Write-Log "=== run-sdv.ps1 ==="
Write-Log "Solution   : $SolutionPath"
Write-Log "EWDK root  : $EwdkRoot"
Write-Log "Rule set   : $SdvRuleSet"
Write-Log "Output dir : $OutputDir"

# ---------------------------------------------------------------------------
# Pre-flight: verify EWDK and solution
# ---------------------------------------------------------------------------
$setupCmd = Join-Path $EwdkRoot 'BuildEnv\SetupBuildEnv.cmd'
if (-not (Test-Path $setupCmd)) {
    Write-Log "EWDK SetupBuildEnv.cmd not found at: $setupCmd" 'ERROR'
    Write-Log "Mount the EWDK ISO at $EwdkRoot before running SDV." 'ERROR'
    exit 2
}

if (-not (Test-Path $SolutionPath)) {
    Write-Log "Solution not found: $SolutionPath" 'ERROR'
    Write-Log "Phase 3 must create M12.sln before this gate runs." 'ERROR'
    exit 2
}

# ---------------------------------------------------------------------------
# Invoke SDV via EWDK msbuild /t:sdv
# Standard invocation documented in Microsoft WDK SDV docs and EWDK conventions.
# /p:Inputs passes the rule-set file path to the SDV task.
# Configuration must be Release/x64 -- SDV does not support Debug config.
# ---------------------------------------------------------------------------
Write-Log "Starting SDV analysis (this can take 5-20 minutes)..." 'INFO'

$buildCmd = @"
call "$setupCmd" >NUL 2>&1 && msbuild "$SolutionPath" /t:sdv /p:Inputs="$SdvRuleSet" /p:Configuration=Release /p:Platform=x64 /nologo /v:diagnostic
"@

$rawOutput = cmd /c $buildCmd 2>&1
$rawOutput | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding UTF8 }
$buildExitCode = $LASTEXITCODE

Write-Log "msbuild/sdv exit code: $buildExitCode"

# ---------------------------------------------------------------------------
# Locate SDV report artifacts
# SDV writes results to <project-dir>\sdv\ subdirectory.
# Primary output: sdv.dvl.xml (defect list) and sdv-results.xml.
# Also: SDV.log (text summary with pass/fail per rule).
# ---------------------------------------------------------------------------
$slnDir     = Split-Path -Parent $SolutionPath
$sdvDir     = Join-Path $slnDir 'sdv'
$dvlXml     = Join-Path $sdvDir 'sdv.dvl.xml'
$sdvLog     = Join-Path $sdvDir 'SDV.log'
$sdvResults = Join-Path $sdvDir 'sdv-results.xml'

Write-Log "Looking for SDV report at: $sdvDir"

# ---------------------------------------------------------------------------
# Parse violations from SDV.log (text format, reliable fallback)
# Format per rule: "Rule <name>: PASS | FAIL | TIMEOUT | NOT_APPLICABLE"
# Also parse sdv.dvl.xml if available for richer structured data.
# ---------------------------------------------------------------------------
$violations = [System.Collections.Generic.List[hashtable]]::new()
$ruleResults = [System.Collections.Generic.List[hashtable]]::new()
$parseSource = 'none'

if (Test-Path $sdvLog) {
    $parseSource = 'SDV.log'
    Write-Log "Parsing: $sdvLog"
    $logLines = Get-Content $sdvLog
    foreach ($line in $logLines) {
        # Match lines like: "Rule WdfFdoAttachDevice: FAIL" or "Rule ...: PASS"
        if ($line -match 'Rule\s+(\S+)\s*:\s*(PASS|FAIL|TIMEOUT|NOT_APPLICABLE|ERROR)') {
            $ruleName   = $Matches[1]
            $ruleStatus = $Matches[2]
            $entry = @{ rule = $ruleName; status = $ruleStatus }
            $ruleResults.Add($entry)
            if ($ruleStatus -eq 'FAIL' -or $ruleStatus -eq 'ERROR') {
                $violations.Add($entry)
            }
        }
    }
} elseif (Test-Path $dvlXml) {
    # Parse DVL XML as fallback -- element: <Defect RuleName="..." Category="..." ... />
    $parseSource = 'sdv.dvl.xml'
    Write-Log "Parsing: $dvlXml (DVL XML)"
    [xml]$dvl = Get-Content $dvlXml
    $defects = $dvl.SelectNodes('//Defect')
    foreach ($d in $defects) {
        $entry = @{
            rule     = $d.GetAttribute('RuleName')
            status   = 'FAIL'
            category = $d.GetAttribute('Category')
            path     = $d.GetAttribute('SdvDefectPath')
        }
        $violations.Add($entry)
        $ruleResults.Add($entry)
    }
} else {
    Write-Log "No SDV report found at $sdvDir -- SDV may not have run or solution missing M12 project." 'WARN'
    Write-Log "Raw build log: $LogFile" 'WARN'
    $parseSource = 'none'
}

$violationCount = $violations.Count
Write-Log "SDV violations found: $violationCount (parsed from: $parseSource)"

# ---------------------------------------------------------------------------
# Gate determination
# Pass only if: msbuild exit = 0 AND parse succeeded AND 0 FAIL/ERROR rules.
# Senior-dev review MAJ-3: previous logic falsely PASSED when SDV exited 0 but
# produced no artifacts (SDK mismatch, cancelled run, missing M12 project).
# Now: parseSource = 'none' is a hard FAIL even if exit code is 0.
# A non-zero msbuild exit also fails (infrastructure failure, not just violations).
# ---------------------------------------------------------------------------
$reportFound = ($parseSource -ne 'none')
$gatePassed  = ($violationCount -eq 0 -and $buildExitCode -eq 0 -and $reportFound)
if (-not $reportFound) {
    Write-Log "Gate FAIL: SDV produced no parseable report. Cannot confirm what was checked." 'ERROR'
}

# ---------------------------------------------------------------------------
# Emit sdv-results.json
# ---------------------------------------------------------------------------
$result = @{
    tool            = 'sdv'
    timestamp       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    solution        = $SolutionPath
    rule_set        = $SdvRuleSet
    violation_count = $violationCount
    rule_count      = $ruleResults.Count
    build_exit      = $buildExitCode
    parse_source    = $parseSource
    gate_passed     = $gatePassed
    violations      = @($violations)
    all_rules       = @($ruleResults)
}

$resultJson = $result | ConvertTo-Json -Depth 5
Set-Content -Path $JsonOut -Value $resultJson -Encoding UTF8
Write-Log "JSON results: $JsonOut" 'OK'

# ---------------------------------------------------------------------------
# Emit sdv-report.md
# ---------------------------------------------------------------------------
$gateStatus = if ($gatePassed) { 'PASS' } else { 'FAIL' }

$mdLines = [System.Collections.Generic.List[string]]::new()
$mdLines.Add("## Static Driver Verifier (SDV) Report")
$mdLines.Add("")
$mdLines.Add("| Field | Value |")
$mdLines.Add("|---|---|")
$mdLines.Add("| Gate | $gateStatus |")
$mdLines.Add("| Violations | $violationCount |")
$mdLines.Add("| Rules checked | $($ruleResults.Count) |")
$mdLines.Add("| Rule set | $SdvRuleSet |")
$mdLines.Add("| msbuild exit | $buildExitCode |")
$mdLines.Add("| Report source | $parseSource |")
$mdLines.Add("| Timestamp | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
$mdLines.Add("")

if ($violationCount -gt 0) {
    $mdLines.Add("### Violations (must be 0 to pass)")
    $mdLines.Add("")
    $mdLines.Add("| # | Rule | Status | Detail |")
    $mdLines.Add("|---|---|---|---|")
    $i = 1
    foreach ($v in $violations) {
        $detail = if ($v.ContainsKey('path')) { $v.path } else { '' }
        $mdLines.Add("| $i | $($v.rule) | $($v.status) | $detail |")
        $i++
    }
    $mdLines.Add("")
    $mdLines.Add("**Action**: Fix all FAIL/ERROR rules before merge. SDV gate requires 0 violations.")
    $mdLines.Add("Full SDV log: ``$sdvLog``")
    $mdLines.Add("Full build log: ``$LogFile``")
} elseif ($parseSource -eq 'none') {
    $mdLines.Add("**Warning**: SDV report artifacts not found. SDV may not have run.")
    $mdLines.Add("Check build log: ``$LogFile``")
} else {
    $mdLines.Add("No SDV violations across $($ruleResults.Count) rules. Gate passes.")
}

Set-Content -Path $MdOut -Value ($mdLines -join "`n") -Encoding UTF8
Write-Log "Markdown report: $MdOut" 'OK'

# ---------------------------------------------------------------------------
# Exit
# 0 = gate passes (0 violations)
# 1 = gate fails (violations present or build failure)
# 2 = pre-flight failed (EWDK not mounted, solution missing)
# ---------------------------------------------------------------------------
if ($gatePassed) {
    Write-Log "SDV gate: PASS (0 violations, $($ruleResults.Count) rules checked)" 'OK'
    exit 0
} else {
    Write-Log "SDV gate: FAIL ($violationCount violations, build_exit=$buildExitCode)" 'ERROR'
    exit 1
}
