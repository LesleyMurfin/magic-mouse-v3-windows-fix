# kmdf-204-pnputil-once.ps1
# pnputil /add-driver a signed unique package. Never oem16, never
# MagicMouseDriver.sys, never PATH-A.
#
# -Stage DEFAULTS to the known-good 2.0.4.1 restore copy, so running this
# with no arguments is always the rollback. Installing anything newer is an
# explicit act: pass the version's own sign stage, e.g.
#   -Stage C:\mm-dev-queue\kmdf-204-sign-2043
[CmdletBinding()]
param(
    [string]$Stage = 'C:\mm-dev-queue\kmdf-204-sign'
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'Kmdf-Common.ps1')

$Inf = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.inf'
$Sys = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.sys'
$Cat = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.cat'

function Fail([int]$c, [string]$m) { Write-Output $m; exit $c }

Write-Output ('===== PNPUTIL start stage=' + $Stage + ' =====')
if (-not (Test-Path -LiteralPath $Inf)) { Fail 2 "missing $Inf" }
if (-not (Test-Path -LiteralPath $Sys)) { Fail 2 "missing $Sys" }
if (-not (Test-Path -LiteralPath $Cat)) { Fail 2 "missing $Cat" }
if (Test-Path -LiteralPath (Join-Path $Stage 'MagicMouseDriver.sys')) {
    Fail 3 'REFUSE live MagicMouseDriver.sys in sign stage'
}
if (Test-Path -LiteralPath (Join-Path $Stage 'applewirelessmouse.sys')) {
    Fail 3 'REFUSE PATH-A in sign stage'
}

$infText = Get-Content -LiteralPath $Inf -Raw
if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') { Fail 3 'INF AddService hijacks live MagicMouseDriver' }
if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') { Fail 3 'INF AddService must be MagicMouseDriver204Scroll' }

# Same gate Install-KMDF.ps1 applies: full 40-char thumbprint, and the
# documented self-signed 'UnknownError' status accepted alongside 'Valid'.
if (-not (Test-KmdfSignedByThumb -Path $Sys -Thumb $script:KmdfSignThumb)) {
    Fail 3 ('REFUSE ' + $Sys + ' - not signed by ' + $script:KmdfSignThumb)
}

Write-Output '=== remove unique oem only (not oem16) ==='
$pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
$blocks = $pnpRaw -split '(?=Published Name:)'
foreach ($block in $blocks) {
    if ($block -notmatch 'MagicMouseDriver-kmdf-204-scroll\.inf') { continue }
    if ($block -match 'Original Name:\s+MagicMouseDriver\.inf') { continue }
    if ($block -match 'Published Name:\s+oem16\.inf') { continue }
    if ($block -match 'Published Name:\s+(oem\d+\.inf)') {
        $oem = $Matches[1]
        if ($oem -eq 'oem16.inf') { Fail 3 'REFUSE delete oem16' }
        Write-Output ("delete unique " + $oem)
        & pnputil.exe /delete-driver $oem /uninstall /force
        Write-Output ('delete_exit=' + $LASTEXITCODE)
    }
}

Write-Output '=== pnputil /add-driver unique INF ==='
& pnputil.exe /add-driver $Inf /install
$add = $LASTEXITCODE
Write-Output ('add_exit=' + $add)
# 3010 is success-with-reboot-required, not failure (same as mm-scroll-tune.ps1).
$rebootRequired = $false
if ($add -eq 3010) {
    Write-Output 'add_exit=3010 is success-with-reboot-required - package staged, reboot to finish'
    $rebootRequired = $true
} elseif ($add -ne 0) {
    Fail $add 'pnputil /add-driver failed'
}


$inst = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'
Write-Output '=== restart 0323 HID instance ==='
& pnputil.exe /restart-device $inst
Write-Output ('restart_exit=' + $LASTEXITCODE)

Start-Sleep -Seconds 3

Write-Output '=== F1 SetFeature (restore MT 14+8N) ==='
$f1 = 'C:\mm-dev-queue\mm-f1-once.ps1'
if (Test-Path -LiteralPath $f1) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f1
    Write-Output ('f1_exit=' + $LASTEXITCODE)
} else {
    Write-Output 'F1 script missing - LastAclReceived will stay 9 until HidD_SetFeature F1'
}


$oem16 = 'C:\Windows\System32\drivers\MagicMouseDriver.sys'
if (Test-Path -LiteralPath $oem16) {
    $h = (Get-FileHash -LiteralPath $oem16 -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Output ('oem16_sha256=' + $h)
    if (-not $h.StartsWith('AD5D244B')) { Fail 3 ('oem16 hash drifted ' + $h) }
}

Write-Output '=== loaded file version ==='
$dest = 'C:\Windows\System32\drivers\MagicMouseDriver-kmdf-204-scroll.sys'
if (Test-Path -LiteralPath $dest) {
    Write-Output ('dest_sha256=' + (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToUpperInvariant())
    Write-Output ('dest_version=' + (Get-Item -LiteralPath $dest).VersionInfo.FileVersion)
}

Write-Output ('===== PNPUTIL done stage=' + $Stage + ' =====')
if ($rebootRequired) {
    Write-Output 'add-driver reported 3010 - reboot required to finish'
    exit 3010
}
exit 0
