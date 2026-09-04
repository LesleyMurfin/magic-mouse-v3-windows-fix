# build-driver.ps1 — Build the KMDF Magic Mouse driver (M13).
# Standalone: powershell -ExecutionPolicy Bypass -File build-driver.ps1
# Via queue: BUILD|<nonce>|Release|x64
#
# Requires EWDK ISO mounted (task runner mounts it automatically when called via queue).
# When running standalone, ensure EWDK is mounted first.
param(
    [string]$Config   = 'Release',
    [string]$Platform = 'x64',
    [string]$SlnPath  = ''
)

$ErrorActionPreference = 'Continue'

# Ensure queue dir exists for build log
if (-not (Test-Path 'C:\mm-dev-queue')) {
    New-Item -ItemType Directory -Force -Path 'C:\mm-dev-queue' | Out-Null
}

$ewdkSetup = $null
foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
    $c = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
    if (Test-Path $c) { $ewdkSetup = $c; break }
}

if (-not $ewdkSetup) {
    Write-Error "EWDK not found on any mounted drive. Mount the EWDK ISO first."
    exit 1
}

if (-not $SlnPath) {
    # Default to WSL2 path — requires WSL2 to be running
    $SlnPath = '\\wsl.localhost\Ubuntu\home\lesley\projects\magic-mouse-tray\driver\MagicMouseDriver.sln'
}

if (-not (Test-Path $SlnPath)) {
    Write-Error "Solution not found: $SlnPath"
    exit 2
}

$buildLog = 'C:\mm-dev-queue\build-standalone.log'
$cmdLine = '"' + $ewdkSetup + '" && msbuild "' + $SlnPath + '" /m /nr:false /v:minimal /p:Configuration=' + $Config + ' /p:Platform=' + $Platform + ' /p:RunCodeAnalysis=false /p:SignMode=Off'
Write-Host "Building: $SlnPath ($Config|$Platform)"
"=== $cmdLine ===" | Set-Content $buildLog -Encoding ASCII
& cmd.exe /c $cmdLine 2>&1 | Add-Content $buildLog -Encoding ASCII
$rc = $LASTEXITCODE
Write-Host "Build exited $rc. Log: $buildLog"
exit $rc
