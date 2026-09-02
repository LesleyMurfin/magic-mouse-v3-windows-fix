# build.ps1 — compile MagicKbDesc.sys via the M12 EWDK pipeline.
#
# Uses the existing mm-task-runner.ps1 BUILD route which handles
# EWDK ISO mount detection and msbuild invocation. SYSTEM-priv
# scheduled task — driver builds need privileged access for
# certain WDK steps.
#
# Run from project root:
#   powershell -File driver-keyboard\build.ps1

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$slnPath  = Join-Path $PSScriptRoot 'MagicKbDesc.sln'

if (-not (Test-Path $slnPath)) {
    throw "MagicKbDesc.sln not found at $slnPath — has the .vcxproj been authored yet?"
}

# Generate nonce for the queue protocol.
$nonce = 'kbdesc-' + [guid]::NewGuid().ToString().Substring(0,8)
$queueDir = 'C:\mm-dev-queue'
if (-not (Test-Path $queueDir)) { New-Item -ItemType Directory -Path $queueDir | Out-Null }

# BUILD|<nonce>|<config>|<platform>|<sln-path>
$req = "BUILD|$nonce|Release|x64|$slnPath"
Set-Content -Path (Join-Path $queueDir 'request.txt') -Value $req -Encoding ASCII
Remove-Item (Join-Path $queueDir 'result.txt') -Force -ErrorAction SilentlyContinue

Write-Host "[build] Triggering MM-Dev-Cycle BUILD..."
schtasks /run /tn MM-Dev-Cycle | Out-Null

$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    if (Test-Path (Join-Path $queueDir 'result.txt')) {
        $r = (Get-Content (Join-Path $queueDir 'result.txt') -Raw).Trim()
        if ($r -match "\|$nonce") {
            $exitCode = [int]($r -split '\|')[0]
            if ($exitCode -eq 0) {
                Write-Host "[build] OK" -ForegroundColor Green
                Get-ChildItem -Path (Join-Path $PSScriptRoot 'x64\Release\MagicKbDesc.*') -ErrorAction SilentlyContinue | Format-Table Name,Length
                exit 0
            } else {
                Write-Host "[build] FAILED exit=$exitCode" -ForegroundColor Red
                Get-Content (Join-Path $queueDir "build-$nonce.log") -ErrorAction SilentlyContinue | Select-Object -Last 50
                exit $exitCode
            }
        }
    }
    Start-Sleep -Seconds 2
}
throw "[build] timeout waiting for MM-Dev-Cycle to complete"
