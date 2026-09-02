# post-reboot-validate.ps1
# End-to-end MagicKbDesc validation after the SCM-marked-for-deletion reboot.
#
# What this does:
#   0.  SCM clean check
#   1.  Re-install oem57 via mm-task-runner queue (INSTALL-DRIVER)
#   2.  Verify service registration is fresh
#   3.  Force-load MagicKbDesc.sys via SC-START-DRIVER; check kernel module list
#   4.  Pause for USER to toggle BT off/on in Settings
#   5.  Check DEVPKEY_Device_Stack for MagicKbDesc
#   6.  Run test.ps1 — empirical battery byte
#
# Run from anywhere on Windows:
#   pwsh.exe -File post-reboot-validate.ps1
# OR (works from \\wsl.localhost\... too):
#   powershell.exe -ExecutionPolicy Bypass -File "<this script>"

param(
    [string]$StagingDir = 'C:\mm-dev-queue\kbd-stage-kbd-stage-1778263483',
    [string]$DeviceInstanceId = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000',
    [string]$QueueDir = 'C:\mm-dev-queue',
    [int]$PollMaxSeconds = 120
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.ForegroundColor = 'White'

function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}

function Invoke-RunnerPhase {
    param(
        [string]$Phase,
        [string[]]$Args = @(),
        [int]$TimeoutSec = 60
    )
    $nonce = "kbd-postrb-$([guid]::NewGuid().ToString().Substring(0,8))"
    $req = ($Phase, $nonce) + $Args -join '|'
    $reqPath = Join-Path $QueueDir 'request.txt'
    $resPath = Join-Path $QueueDir 'result.txt'

    $req | Set-Content -Path $reqPath -Encoding ASCII
    Remove-Item $resPath -ErrorAction SilentlyContinue
    Write-Host "[runner] $Phase | $nonce" -ForegroundColor DarkGray
    schtasks /run /tn MM-Dev-Cycle | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $resPath) {
            $r = (Get-Content $resPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($r -match "\|$nonce") {
                $rc = [int]($r -split '\|')[0]
                Write-Host "[runner] result rc=$rc" -ForegroundColor DarkGray
                return [pscustomobject]@{ Rc = $rc; Nonce = $nonce; Result = $r }
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "[runner] TIMEOUT waiting for $Phase ($nonce) after ${TimeoutSec}s"
}

# --------------------------------------------------------------------------
# Step 0 — SCM clean check
# --------------------------------------------------------------------------
Write-Step "Step 0 — SCM clean check"
$scOut = sc.exe query MagicKbDesc 2>&1 | Out-String
if ($scOut -match 'does not exist as an installed service' -or
    $scOut -match 'The specified service does not exist') {
    Write-Host "OK — SCM is clean (service not registered)." -ForegroundColor Green
} elseif ($scOut -match 'marked for deletion') {
    Write-Host "FAIL — SCM still says marked-for-deletion. Reboot didn't clear it." -ForegroundColor Red
    Write-Host $scOut
    throw "SCM not clean — cannot proceed."
} else {
    Write-Host "WARNING — service still exists after reboot. Will attempt to use it." -ForegroundColor Yellow
    Write-Host ($scOut -split "`n" | Select-Object -First 5 | Out-String)
}

# --------------------------------------------------------------------------
# Step 1 — Re-install the INF cleanly
# --------------------------------------------------------------------------
Write-Step "Step 1 — Re-install oem57 (INSTALL-DRIVER)"
$infPath = Join-Path $StagingDir 'MagicKbDesc.inf'
if (-not (Test-Path $infPath)) {
    throw "INF not found at $infPath — has the staging dir been cleaned up? Re-run STAGE-CAT first."
}

$r1 = Invoke-RunnerPhase -Phase 'INSTALL-DRIVER' -Args @($infPath) -TimeoutSec $PollMaxSeconds
$installLog = Join-Path $QueueDir "install-$($r1.Nonce).log"
if (Test-Path $installLog) {
    $logContent = Get-Content $installLog -Raw
    Write-Host $logContent
    if ($logContent -match 'Added driver packages:\s*1') {
        Write-Host "OK — fresh service registration created." -ForegroundColor Green
    } elseif ($logContent -match 'Added driver packages:\s*0') {
        Write-Host "WARNING — pnputil reports Added=0 (treats package as already present)." -ForegroundColor Yellow
        Write-Host "  Attempting full uninstall + reinstall..." -ForegroundColor Yellow
        Invoke-RunnerPhase -Phase 'UNINSTALL-DRIVER' -Args @('oem57.inf') -TimeoutSec 60 | Out-Null
        Start-Sleep -Seconds 3
        $r1b = Invoke-RunnerPhase -Phase 'INSTALL-DRIVER' -Args @($infPath) -TimeoutSec $PollMaxSeconds
        $log2 = Join-Path $QueueDir "install-$($r1b.Nonce).log"
        Get-Content $log2 -Raw | Write-Host
    }
}

# --------------------------------------------------------------------------
# Step 2 — Verify service registration
# --------------------------------------------------------------------------
Write-Step "Step 2 — Verify service registration"
$qcOut = sc.exe qc MagicKbDesc 2>&1 | Out-String
Write-Host ($qcOut -split "`n" | Select-String 'BINARY|START_TYPE|TYPE' | Out-String)

$sysInDrivers = Test-Path 'C:\Windows\System32\drivers\MagicKbDesc.sys'
Write-Host "C:\Windows\System32\drivers\MagicKbDesc.sys exists? $sysInDrivers"

$svcReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicKbDesc' -ErrorAction SilentlyContinue
if ($svcReg) {
    Write-Host "ImagePath: $($svcReg.ImagePath)" -ForegroundColor White
    Write-Host "Type: $($svcReg.Type)  Start: $($svcReg.Start)  ErrorControl: $($svcReg.ErrorControl)"
    if ($svcReg.ImagePath -match 'magickbdesc\.inf_amd64_19830858ec72e2ad' -or
        $svcReg.ImagePath -match '\\drivers\\MagicKbDesc\.sys') {
        Write-Host "OK — ImagePath points at a valid location." -ForegroundColor Green
    } else {
        Write-Host "FAIL — ImagePath looks stale: $($svcReg.ImagePath)" -ForegroundColor Red
        throw "Service ImagePath is broken."
    }
} else {
    throw "Service registration missing — INSTALL-DRIVER didn't write it."
}

# --------------------------------------------------------------------------
# Step 3 — Force-load + verify kernel module loaded
# --------------------------------------------------------------------------
Write-Step "Step 3 — Force-load MagicKbDesc"
$r3 = Invoke-RunnerPhase -Phase 'SC-START-DRIVER' -Args @('MagicKbDesc') -TimeoutSec 30
$startLog = Join-Path $QueueDir "scstart-$($r3.Nonce).log"
if (Test-Path $startLog) {
    Write-Host (Get-Content $startLog -Raw)
}

Start-Sleep -Seconds 2
$dq = driverquery /v /fo csv 2>&1 | Select-String 'MagicKbDesc'
if ($dq) {
    Write-Host "OK — MagicKbDesc IS loaded in the kernel:" -ForegroundColor Green
    Write-Host $dq
} else {
    Write-Host "FAIL — MagicKbDesc NOT loaded in kernel (driverquery shows nothing)." -ForegroundColor Red
    Write-Host "Check Microsoft-Windows-CodeIntegrity/Operational log for the load error."
    Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 10 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'MagicKbDesc' } |
        Format-List TimeCreated, Id, Message
    throw "Kernel-load failed — investigate before continuing."
}

# --------------------------------------------------------------------------
# Step 4 — USER toggles Bluetooth
# --------------------------------------------------------------------------
Write-Step "Step 4 — USER ACTION REQUIRED"
Write-Host ""
Write-Host "  Open Settings → Bluetooth & devices → toggle Bluetooth OFF, wait 5s, ON." -ForegroundColor Yellow
Write-Host "  Wait for the keyboard to reconnect (it will appear in the device list)." -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter when the keyboard has reconnected"

# --------------------------------------------------------------------------
# Step 5 — Check device stack
# --------------------------------------------------------------------------
Write-Step "Step 5 — Verify MagicKbDesc is in the device stack"
$stack = Get-PnpDeviceProperty -InstanceId $DeviceInstanceId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Data
Write-Host "Stack:"
$stack | ForEach-Object { Write-Host "  $_" }

if ($stack -match 'MagicKbDesc') {
    Write-Host "PASS — filter is bound." -ForegroundColor Green
} else {
    Write-Host "FAIL — MagicKbDesc not in stack." -ForegroundColor Red
    Write-Host "B3 architectural premise falsified — lower filter on BTHENUM PDO doesn't see the descriptor IOCTL." -ForegroundColor Red
    Write-Host "Capturing setupapi log for diagnosis..."
    $diagFile = Join-Path $QueueDir "diag-postrb-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    "=== last 100 setupapi entries mentioning BTHENUM/0239/MagicKbDesc ===" | Set-Content $diagFile
    Get-Content 'C:\Windows\inf\setupapi.dev.log' |
        Select-String 'BTHENUM.*0239|MagicKbDesc' |
        Select-Object -Last 100 |
        ForEach-Object { $_.Line } |
        Add-Content $diagFile
    "" | Add-Content $diagFile
    "=== last 30 System events mentioning MagicKbDesc/HidBth ===" | Add-Content $diagFile
    Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'MagicKbDesc|HidBth' } |
        Select-Object -First 30 |
        Format-List TimeCreated, Id, LevelDisplayName, Message |
        Out-String |
        Add-Content $diagFile
    Write-Host "Diagnosis written to $diagFile" -ForegroundColor Yellow
    exit 1
}

# --------------------------------------------------------------------------
# Step 6 — Empirical battery byte
# --------------------------------------------------------------------------
Write-Step "Step 6 — Empirical battery read"
$testScript = Join-Path $PSScriptRoot 'test.ps1'
if (-not (Test-Path $testScript)) {
    Write-Host "test.ps1 not found at $testScript — running inline check instead." -ForegroundColor Yellow
    & "$PSScriptRoot\check-stack-and-test.ps1" 2>&1
} else {
    & pwsh.exe -NoProfile -File $testScript 2>&1
}

Write-Step "DONE"
Write-Host "If you see *** SUCCESS *** [47 NN] BATTERY = NN% above, M2 closes." -ForegroundColor Green
Write-Host "Send the user a copy of this terminal output for the PR test-plan checkboxes."
