# pre-reboot-checkpoint.ps1
# Runs immediately before reboot. Captures current MagicKbDesc state and
# verifies the staging dir + driver-store entries are still there so the
# post-reboot validate script doesn't have to rebuild from scratch.
#
# Run:
#   powershell.exe -ExecutionPolicy Bypass -File pre-reboot-checkpoint.ps1

param(
    [string]$StagingDir = 'C:\mm-dev-queue\kbd-stage-kbd-stage-1778263483',
    [string]$DeviceInstanceId = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000'
)

$ErrorActionPreference = 'Continue'
$pass = $true

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $tag = if ($Ok) { 'OK  ' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host "[$tag] $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
    if (-not $Ok) { $script:pass = $false }
}

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Pre-Reboot Checkpoint — MagicKbDesc state" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# Staging dir
$stageInf = Join-Path $StagingDir 'MagicKbDesc.inf'
$stageSys = Join-Path $StagingDir 'MagicKbDesc.sys'
$stageCat = Join-Path $StagingDir 'magickbdesc.cat'
Check -Name "Staging INF present" -Ok (Test-Path $stageInf) -Detail $stageInf
Check -Name "Staging SYS present" -Ok (Test-Path $stageSys) -Detail $stageSys
Check -Name "Staging CAT present" -Ok (Test-Path $stageCat) -Detail $stageCat

if (Test-Path $stageSys) {
    $stageMd5 = (Get-FileHash -Algorithm MD5 $stageSys).Hash.ToLower()
    Check -Name "Staging SYS MD5 = e11d8b97660d6b9324e82225c37201c0" `
          -Ok ($stageMd5 -eq 'e11d8b97660d6b9324e82225c37201c0') `
          -Detail "actual: $stageMd5"
}

# Driver store
$dsRoot = 'C:\Windows\System32\DriverStore\FileRepository'
$dsHash = Get-ChildItem $dsRoot -Filter 'magickbdesc.inf_amd64_*' -Directory -ErrorAction SilentlyContinue
Check -Name "Driver store has magickbdesc package" -Ok ($dsHash.Count -gt 0) `
      -Detail "Found: $($dsHash.Name -join ', ')"

# pnputil enum
$enum = pnputil /enum-drivers 2>&1 | Out-String
$hasOem57 = $enum -match 'oem57\.inf' -and $enum -match 'magickbdesc'
Check -Name "pnputil enum-drivers shows magickbdesc as oem57.inf" -Ok $hasOem57

# Service state
$scOut = sc.exe query MagicKbDesc 2>&1 | Out-String
if ($scOut -match 'marked for deletion') {
    Check -Name "Service state" -Ok $false -Detail "marked for deletion (REBOOT REQUIRED)"
} elseif ($scOut -match 'does not exist') {
    Check -Name "Service state" -Ok $true -Detail "not registered (clean — INSTALL-DRIVER will create)"
} else {
    Check -Name "Service state" -Ok $true -Detail ($scOut -split "`n" | Select-String 'STATE' | ForEach-Object { $_.Line.Trim() })
}

# Device LowerFilters reg
$drv = (Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $DeviceInstanceId) -ErrorAction SilentlyContinue).Driver
if ($drv) {
    $lf = (Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $drv) -ErrorAction SilentlyContinue).LowerFilters
    Check -Name "Device LowerFilters includes MagicKbDesc" -Ok ($lf -contains 'MagicKbDesc') `
          -Detail "Driver class instance: $drv  LowerFilters: $($lf -join ',')"
} else {
    Check -Name "Device class instance lookup" -Ok $false -Detail "no Driver value at $DeviceInstanceId"
}

# Branch state
$gitState = & git -C '\\wsl.localhost\Ubuntu\home\lesley\.claude\worktrees\ai-m4-kbd-inf-fix-final' log --oneline -1 2>&1 | Out-String
Check -Name "Worktree branch HEAD" -Ok ($gitState -match 'fix\(kbd-driver\): peer-review B1\+B2\+B4') `
      -Detail $gitState.Trim()

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
if ($pass) {
    Write-Host "  ALL CHECKS PASSED — safe to reboot now." -ForegroundColor Green
    Write-Host "  After reboot run:" -ForegroundColor White
    Write-Host "    powershell.exe -ExecutionPolicy Bypass -File post-reboot-validate.ps1" -ForegroundColor Yellow
} else {
    Write-Host "  ONE OR MORE CHECKS FAILED — fix before reboot." -ForegroundColor Red
}
Write-Host "=================================================================" -ForegroundColor Cyan
exit $(if ($pass) { 0 } else { 1 })
