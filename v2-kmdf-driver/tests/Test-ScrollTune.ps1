# Actual PowerShell execution with fake registry, PnP, native tools, and sleeps.
# No Pester, elevation, installed driver, or attached mouse required.
# -ScriptPath also allows running the same cases against a baseline checkout.
[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '../scripts/mm-scroll-tune.ps1')
)
$ErrorActionPreference = 'Stop'
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$engine = (Get-Process -Id $PID).Path
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('scroll-tune-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null

# Each case gets a fresh process. Functions shadow every host-facing operation
# in the production script, including both .exe invocations. Unexpected paths,
# arguments, or writes throw; no mock delegates to a real registry/device tool.
$wrapper = @'
param([string]$Target, [string]$CasePath)
$ErrorActionPreference = 'Stop'
$global:mockScrollTune = @{
    Case = (Get-Content -LiteralPath $CasePath -Raw | ConvertFrom-Json)
    Service = 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll'
    Instance = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323\MOCK'
    F1 = (Join-Path (Split-Path -Parent $Target) 'mm-f1-once.ps1')
    Writes = @{}
    RestartCalls = 0
    F1Calls = 0
    SleepCalls = 0
}
function Test-Path {
    param([string]$LiteralPath)
    if ($LiteralPath -notin @($($global:mockScrollTune.Service), "$($global:mockScrollTune.Service)\Parameters", $global:mockScrollTune.F1)) {
        throw "Unexpected Test-Path: $LiteralPath"
    }
    return $true
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name)
    if ($LiteralPath -eq "$($global:mockScrollTune.Service)\Parameters" -and $Name -in @('ScrollStep', 'HiResScroll')) {
        return $null
    }
    if ($LiteralPath -eq "$($global:mockScrollTune.Service)\Diag" -and -not $Name) { return $global:mockScrollTune.Case.Diag }
    throw "Unexpected registry read: $LiteralPath $Name"
}
function New-Item { throw 'Unexpected registry creation' }
function Set-ItemProperty {
    param([string]$LiteralPath, [string]$Name, [string]$Type, [int]$Value)
    if ($LiteralPath -ne "$($global:mockScrollTune.Service)\Parameters" -or $Type -ne 'DWord' -or
        $Name -notin @('ScrollStep', 'HiResScroll') -or $global:mockScrollTune.Writes.ContainsKey($Name)) {
        throw "Unexpected registry write: $LiteralPath $Name $Type"
    }
    $global:mockScrollTune.Writes[$Name] = $Value
}
function Get-PnpDevice {
    [CmdletBinding()]
    param([switch]$PresentOnly)
    if (-not $PresentOnly) { throw 'Expected present-only enumeration' }
    [pscustomobject]@{ InstanceId = $global:mockScrollTune.Instance }
}
function pnputil.exe {
    if ($args.Count -ne 2 -or $args[0] -ne '/restart-device' -or $args[1] -ne $global:mockScrollTune.Instance) {
        throw 'Unexpected pnputil invocation'
    }
    $global:mockScrollTune.RestartCalls++
    $global:LASTEXITCODE = [int]$global:mockScrollTune.Case.Restart
}
function powershell.exe {
    if ($args.Count -ne 5 -or $args[0] -ne '-NoProfile' -or
        $args[1] -ne '-ExecutionPolicy' -or $args[2] -ne 'Bypass' -or
        $args[3] -ne '-File' -or $args[4] -ne $global:mockScrollTune.F1) {
        throw 'Unexpected F1 invocation'
    }
    $global:mockScrollTune.F1Calls++
    $global:LASTEXITCODE = [int]$global:mockScrollTune.Case.F1
}
function Start-Sleep {
    param([int]$Seconds)
    if ($Seconds -notin @(2, 3)) { throw 'Unexpected sleep' }
    $global:mockScrollTune.SleepCalls++
}
$parameters = @{ ScrollStep = 16 }
if ($null -ne $global:mockScrollTune.Case.HiRes) { $parameters.HiResScroll = [int]$global:mockScrollTune.Case.HiRes }
& $Target @parameters
$actualExit = $LASTEXITCODE
$expectedWrites = if ($null -ne $global:mockScrollTune.Case.HiRes) { 2 } else { 1 }
$expectedSleeps = if ($global:mockScrollTune.Case.F1 -eq 0) { 2 } else { 1 }
if ($global:mockScrollTune.Writes.Count -ne $expectedWrites -or $global:mockScrollTune.Writes.ScrollStep -ne 16 -or
    ($null -ne $global:mockScrollTune.Case.HiRes -and $global:mockScrollTune.Writes.HiResScroll -ne $global:mockScrollTune.Case.HiRes) -or
    $global:mockScrollTune.RestartCalls -ne 1 -or $global:mockScrollTune.F1Calls -ne 1 -or $global:mockScrollTune.SleepCalls -ne $expectedSleeps) {
    throw 'Mock call assertions failed'
}
Write-Output 'MOCK_CALLS_VERIFIED'
exit $actualExit
'@

# Missing values and explicit zero are separate cases: PowerShell converts null
# to integer zero, so missing echoes must be detected before numeric comparison.
$cases = @(
    @{ Name = 'missing Diag'; Diag = $null; HiRes = 1; Expected = 7 },
    @{ Name = 'empty Diag'; Diag = @{}; HiRes = 1; Expected = 7 },
    @{ Name = 'missing ScrollStep'; Diag = @{ HiResScroll = 1; F1PayloadForced = 1 }; HiRes = 1; Expected = 7 },
    @{ Name = 'missing requested HiResScroll'; Diag = @{ ScrollStep = 16; F1PayloadForced = 1 }; HiRes = 1; Expected = 7 },
    @{ Name = 'missing disabled HiResScroll'; Diag = @{ ScrollStep = 16 }; HiRes = 0; Expected = 7 },
    @{ Name = 'missing arm counter'; Diag = @{ ScrollStep = 16; HiResScroll = 1 }; HiRes = 1; Expected = 7 },
    @{ Name = 'zero arm counter'; Diag = @{ ScrollStep = 16; HiResScroll = 1; F1PayloadForced = 0 }; HiRes = 1; Expected = 7 },
    @{ Name = 'armed hi-res'; Diag = @{ ScrollStep = 16; HiResScroll = 1; F1PayloadForced = 2 }; HiRes = 1; Expected = 0 },
    @{ Name = 'disabled missing arm counter'; Diag = @{ ScrollStep = 16; HiResScroll = 0 }; HiRes = 0; Expected = 0 },
    @{ Name = 'disabled zero arm counter'; Diag = @{ ScrollStep = 16; HiResScroll = 0; F1PayloadForced = 0 }; HiRes = 0; Expected = 0 },
    @{ Name = 'omitted hi-res'; Diag = @{ ScrollStep = 16 }; HiRes = $null; Expected = 0 },
    @{ Name = 'omitted hi-res with unarmed descriptor'; Diag = @{ ScrollStep = 16; HiResScroll = 1; F1PayloadForced = 0 }; HiRes = $null; Expected = 0 },
    @{ Name = 'omitted hi-res missing ScrollStep'; Diag = @{}; HiRes = $null; Expected = 7 },
    @{ Name = 'ScrollStep mismatch'; Diag = @{ ScrollStep = 8; HiResScroll = 1; F1PayloadForced = 1 }; HiRes = 1; Expected = 3 },
    @{ Name = 'HiResScroll mismatch'; Diag = @{ ScrollStep = 16; HiResScroll = 0; F1PayloadForced = 1 }; HiRes = 1; Expected = 3 },
    @{ Name = 'disable mismatch'; Diag = @{ ScrollStep = 16; HiResScroll = 1 }; HiRes = 0; Expected = 3 },
    @{ Name = 'F1 failure'; Diag = $null; HiRes = 1; F1 = 1; Expected = 6 }
)
$failed = 0
$total = 0
try {
    $wrapperPath = Join-Path $temp 'Invoke-MockedScrollTune.ps1'
    Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding UTF8
    foreach ($case in $cases) {
        # Every case also runs with a pending reboot to protect 3010 precedence.
        foreach ($restart in @(0, 3010)) {
            $case.Restart = $restart
            if (-not $case.ContainsKey('F1')) { $case.F1 = 0 }
            $expected = if ($restart -eq 3010) { 3010 } else { $case.Expected }
            $casePath = Join-Path $temp 'case.json'
            $case | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $casePath -Encoding UTF8
            $output = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -Target $ScriptPath -CasePath $casePath 2>&1)
            $actual = $LASTEXITCODE
            $total++
            if ($actual -ne $expected -or $output -notcontains 'MOCK_CALLS_VERIFIED' -or
                ($expected -ne 0 -and $output -contains '===== scroll tune done =====')) {
                $failed++
                Write-Output "FAIL $($case.Name) restart=$restart expected=$expected actual=$actual"
                $output | Write-Output
            } else {
                Write-Output "PASS $($case.Name) restart=$restart exit=$actual"
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output "Scroll tune regression: $($total - $failed)/$total passed"
if ($failed -gt 0) { exit 1 }
exit 0
