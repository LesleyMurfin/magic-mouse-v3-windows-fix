# sign-driver.ps1 — Sign a .sys + .cat pair with a PFX cert.
# Standalone: powershell -ExecutionPolicy Bypass -File sign-driver.ps1 -SysPath ... -CatPath ... -PfxPath ...
# Via queue: SIGN|<nonce>|<sys-path>|<cat-path>|<pfx-path>|<pfx-pass-env-var>
#
# Empirically validated signtool path: F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe
# (F:\ is the EWDK ISO drive on this dev machine — confirmed in mm-task-runner.ps1)
# Fallback: C:\Program Files (x86)\Windows Kits\10\ for machines with WDK/SDK on C:\
param(
    [Parameter(Mandatory)][string]$SysPath,
    [Parameter(Mandatory)][string]$CatPath,
    [Parameter(Mandatory)][string]$PfxPath,
    [string]$PfxPassEnvVar = ''
)

$ErrorActionPreference = 'Continue'
$tsUrl = 'http://timestamp.digicert.com'

# Auto-discover signtool: try empirical dev-machine path first, then common WDK locations
$signtoolCandidates = @(
    'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe',
    'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe',
    'C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe'
)
$signtool = $signtoolCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $signtool) {
    Write-Error "signtool not found in any known location. Mount EWDK ISO to F:\ or install Windows SDK."
    exit 1
}

if (-not (Test-Path $SysPath)) { Write-Error ".sys not found: $SysPath"; exit 2 }
if (-not (Test-Path $CatPath)) { Write-Error ".cat not found: $CatPath"; exit 2 }

$pfxPass  = if ($PfxPassEnvVar) { [Environment]::GetEnvironmentVariable($PfxPassEnvVar) } else { '' }
$passArgs = if ($pfxPass) { @('/p', $pfxPass) } else { @() }

Write-Host "Signing $SysPath ..."
& $signtool sign /fd sha256 /tr $tsUrl /td sha256 /f $PfxPath @passArgs $SysPath
$rc1 = $LASTEXITCODE

Write-Host "Signing $CatPath ..."
& $signtool sign /fd sha256 /tr $tsUrl /td sha256 /f $PfxPath @passArgs $CatPath
$rc2 = $LASTEXITCODE

if ($rc1 -ne 0) { Write-Error "sys signing failed ($rc1)"; exit $rc1 }
if ($rc2 -ne 0) { Write-Error "cat signing failed ($rc2)"; exit $rc2 }
Write-Host "Both files signed successfully."
exit 0
