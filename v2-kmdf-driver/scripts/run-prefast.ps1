<#
.SYNOPSIS
    PREfast static analysis gate for M12 driver builds.

.DESCRIPTION
    Invokes PREfast as part of an EWDK msbuild pass with RunCodeAnalysis=true.
    Captures per-warning structured output, emits prefast-results.json and
    prefast-report.md to the OutputDir.

    Exit 0 = 0 warnings (gate passes).
    Exit 1 = 1+ warnings (gate fails; PR is blocked).

    Designed to be called by Phase 3 driver agents or from run-quality-gates.ps1.
    No EWDK installed on the host? The script exits 2 with a clear diagnostic.

.PARAMETER SolutionPath
    Absolute path to M12.sln (or .vcxproj). Must be a Windows path accessible
    from the admin-queue context.

.PARAMETER Configuration
    msbuild Configuration property. Default: Release. Valid: Release, Debug.

.PARAMETER Platform
    msbuild Platform property. Default: x64.

.PARAMETER EwdkRoot
    Root of the mounted EWDK ISO. Default: F:\  (matches dev-machine convention
    established in M12-PRODUCTION-HYGIENE-FOR-V1.3.md Section 7).

.PARAMETER OutputDir
    Directory where prefast-results.json and prefast-report.md are written.
    Created if absent. Default: C:\mm-dev-queue\prefast-<timestamp>

.PARAMETER LogFile
    Full path for verbose build log. Default: OutputDir\prefast-build.log

.EXAMPLE
    # Called by run-quality-gates.ps1 -- no direct invocation needed in Phase 3.
    .\run-prefast.ps1 -SolutionPath 'C:\src\driver\M12.sln' -Configuration Release -Platform x64

.EXAMPLE
    # Standalone test (when M12.sln exists, Phase 3+):
    .\run-prefast.ps1 -SolutionPath '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\driver\M12.sln'
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
    $line = "[$ts][prefast][$Level] $Msg"
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
    $OutputDir = "C:\mm-dev-queue\prefast-$ts"
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

if (-not $LogFile) {
    $LogFile = Join-Path $OutputDir 'prefast-build.log'
}

$JsonOut = Join-Path $OutputDir 'prefast-results.json'
$MdOut   = Join-Path $OutputDir 'prefast-report.md'

Write-Log "=== run-prefast.ps1 ==="
Write-Log "Solution   : $SolutionPath"
Write-Log "Config     : $Configuration / $Platform"
Write-Log "EWDK root  : $EwdkRoot"
Write-Log "Output dir : $OutputDir"

# ---------------------------------------------------------------------------
# Pre-flight: verify EWDK and solution
# ---------------------------------------------------------------------------
$setupCmd = Join-Path $EwdkRoot 'BuildEnv\SetupBuildEnv.cmd'
if (-not (Test-Path $setupCmd)) {
    Write-Log "EWDK SetupBuildEnv.cmd not found at: $setupCmd" 'ERROR'
    Write-Log "Mount the EWDK ISO at $EwdkRoot before running PREfast." 'ERROR'
    exit 2
}

if (-not (Test-Path $SolutionPath)) {
    Write-Log "Solution not found: $SolutionPath" 'ERROR'
    Write-Log "Phase 3 must create M12.sln before this gate runs." 'ERROR'
    exit 2
}

# ---------------------------------------------------------------------------
# Invoke EWDK msbuild with RunCodeAnalysis=true
# This is the canonical PREfast invocation pattern for KMDF drivers on EWDK.
# SetupBuildEnv.cmd sets PATH/INCLUDE/LIB; 'call' ensures it returns before
# msbuild runs (LaunchBuildEnv.cmd uses /k which spawns interactive shell).
# ---------------------------------------------------------------------------
Write-Log "Starting PREfast msbuild pass..." 'INFO'

$buildCmd = @"
call "$setupCmd" >NUL 2>&1 && msbuild "$SolutionPath" /p:Configuration=$Configuration /p:Platform=$Platform /p:RunCodeAnalysis=true /t:Build /nologo /v:diagnostic
"@

$rawOutput = cmd /c $buildCmd 2>&1
$rawOutput | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding UTF8 }
$buildExitCode = $LASTEXITCODE

Write-Log "msbuild exit code: $buildExitCode"

# ---------------------------------------------------------------------------
# Parse PREfast warnings from build output
# PREfast warnings surface as:  <file>(<line>): warning <Cxxxx>: <message>
# The /analyze flag also emits:  warning C6xxx: <message> [<file>(<line>)]
# We capture both forms.
# ---------------------------------------------------------------------------
$warnings = [System.Collections.Generic.List[hashtable]]::new()

foreach ($line in $rawOutput) {
    if ($line -match '^(.+?)\((\d+)\)\s*:\s*warning\s+(C\d+)\s*:\s*(.+)$') {
        $warnings.Add(@{
            file    = $Matches[1].Trim()
            line    = [int]$Matches[2]
            code    = $Matches[3]
            message = $Matches[4].Trim()
        })
    }
}

$warningCount = $warnings.Count
Write-Log "PREfast warnings found: $warningCount"

# ---------------------------------------------------------------------------
# Emit prefast-results.json
# ---------------------------------------------------------------------------
$result = @{
    tool          = 'prefast'
    timestamp     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    solution      = $SolutionPath
    configuration = $Configuration
    platform      = $Platform
    warning_count = $warningCount
    build_exit    = $buildExitCode
    gate_passed   = ($warningCount -eq 0 -and $buildExitCode -eq 0)
    warnings      = @($warnings)
}

$resultJson = $result | ConvertTo-Json -Depth 5
Set-Content -Path $JsonOut -Value $resultJson -Encoding UTF8
Write-Log "JSON results: $JsonOut" 'OK'

# ---------------------------------------------------------------------------
# Emit prefast-report.md (PR-comment-ready)
# ---------------------------------------------------------------------------
$gateStatus = if ($result.gate_passed) { 'PASS' } else { 'FAIL' }
$mdLines = [System.Collections.Generic.List[string]]::new()
$mdLines.Add("## PREfast Static Analysis Report")
$mdLines.Add("")
$mdLines.Add("| Field | Value |")
$mdLines.Add("|---|---|")
$mdLines.Add("| Gate | $gateStatus |")
$mdLines.Add("| Warnings | $warningCount |")
$mdLines.Add("| Configuration | ${Configuration}/$Platform |")
$mdLines.Add("| msbuild exit | $buildExitCode |")
$mdLines.Add("| Timestamp | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
$mdLines.Add("")

if ($warningCount -gt 0) {
    $mdLines.Add("### Warnings (must be 0 to pass)")
    $mdLines.Add("")
    $mdLines.Add("| # | File | Line | Code | Message |")
    $mdLines.Add("|---|---|---|---|---|")
    $i = 1
    foreach ($w in $warnings) {
        $fname = Split-Path -Leaf $w.file
        $mdLines.Add("| $i | $fname | $($w.line) | $($w.code) | $($w.message) |")
        $i++
    }
    $mdLines.Add("")
    $mdLines.Add("**Action**: Fix all warnings. PREfast gate requires 0 warnings.")
    $mdLines.Add("See full build log: ``$LogFile``")
} else {
    $mdLines.Add("No PREfast warnings. Gate passes.")
}

Set-Content -Path $MdOut -Value ($mdLines -join "`n") -Encoding UTF8
Write-Log "Markdown report: $MdOut" 'OK'

# ---------------------------------------------------------------------------
# Exit
# 0 = gate passes (0 warnings, clean build)
# 1 = gate fails (warnings present or build error)
# 2 = pre-flight failed (EWDK not mounted, solution missing)
# ---------------------------------------------------------------------------
if ($result.gate_passed) {
    Write-Log "PREfast gate: PASS (0 warnings)" 'OK'
    exit 0
} else {
    Write-Log "PREfast gate: FAIL ($warningCount warnings, build_exit=$buildExitCode)" 'ERROR'
    exit 1
}
