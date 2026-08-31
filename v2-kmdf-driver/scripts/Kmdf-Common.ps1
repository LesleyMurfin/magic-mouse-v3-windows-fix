# Shared helpers for the KMDF one-click path.
# Dot-sourced by Invoke-KmdfInstall.ps1 / Invoke-KmdfPostBoot.ps1 / Install-KMDF.ps1.
# Not meant to be run directly.

$script:KmdfDataDir    = 'C:\ProgramData\MagicMouseDriver'
$script:KmdfInstallDir = 'C:\Program Files\MagicMouseDriver'
$script:KmdfLog        = Join-Path $script:KmdfDataDir 'install.log'
$script:KmdfVerifyLog  = Join-Path $script:KmdfDataDir 'verify.log'
$script:KmdfResult     = Join-Path $script:KmdfDataDir 'RESULT.txt'
$script:KmdfState      = Join-Path $script:KmdfDataDir 'state.json'
$script:KmdfTaskInstall  = 'MM-Kmdf-Install'
$script:KmdfTaskPostBoot = 'MM-Kmdf-PostBoot'
$script:KmdfCertSubject  = 'CN=MagicMouseFix'
$script:KmdfCertThumb    = 'B902C2864315E2DE359450024768CE7D01715C38'
# Apr 30 live binary: pointer OK, scroll dead. Keep as fallback, do not treat as final product.
$script:KmdfShaPointerOk = 'AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B'
# May 20 2.0.2.0 WDKTestCert — HID started, pointer dead. Never install.
$script:KmdfShaPointerDead = '559B136AEB869D1B85EE21583BB7BFD72782A31EE476A2622014D87CE6762F30'
$script:KmdfPidPattern   = 'BTHENUM\\\{00001124.*PID&0323'
$script:KmdfServiceName  = 'MagicMouseDriver'

function Initialize-KmdfDataDir {
    if (-not (Test-Path -LiteralPath $script:KmdfDataDir)) {
        New-Item -ItemType Directory -Path $script:KmdfDataDir -Force | Out-Null
    }
}

function Write-KmdfLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'HEAD')]
        [string]$Level = 'INFO',
        [string]$LogPath = $script:KmdfLog
    )
    Initialize-KmdfDataDir
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'HEAD'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-KmdfResult {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'PENDING')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    Initialize-KmdfDataDir
    $body = @(
        "MagicMouseDriver KMDF (PID 0323)"
        "Status : $Status"
        "Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Detail : $Detail"
        "Log    : $script:KmdfLog"
        "Verify : $script:KmdfVerifyLog"
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $script:KmdfResult -Value $body -Encoding UTF8
    Write-KmdfLog -Message "RESULT=$Status $Detail" -Level $(if ($Status -eq 'FAIL') { 'ERROR' } elseif ($Status -eq 'PASS') { 'OK' } else { 'WARN' })
}

function Test-KmdfIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Kmdf0323Device {
    $out = & pnputil.exe /enum-devices 2>&1 | Out-String
    $blocks = $out -split '(?=Instance ID:)'
    $found = @()
    foreach ($block in $blocks) {
        if ($block -notmatch $script:KmdfPidPattern) { continue }
        $id = $null
        if ($block -match 'Instance ID:\s+(\S+)') { $id = $Matches[1].Trim() }
        if (-not $id) { continue }
        $status = 'Unknown'
        if ($block -match 'Status:\s+(\S.+)') { $status = $Matches[1].Trim() }
        $found += [pscustomobject]@{ InstanceId = $id; Status = $status; Raw = $block }
    }
    return $found
}

function Get-KmdfDeviceStack {
    param([Parameter(Mandatory)][string]$InstanceId)
    $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
    if (-not $dev) { return $null }
    try {
        $prop = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction Stop
        return [string]$prop.Data
    } catch {
        return $null
    }
}

function Set-KmdfSoleLowerFilter {
    param([Parameter(Mandatory)][string]$InstanceId)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    if (-not (Test-Path -LiteralPath $regPath)) {
        Write-KmdfLog -Message "Enum key missing: $regPath" -Level 'ERROR'
        return $false
    }
    $existing = $null
    try { $existing = (Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop).LowerFilters } catch { $existing = $null }

    $wanted = @($script:KmdfServiceName)
    $same = $false
    if ($existing -is [string]) {
        $same = ($existing -eq $script:KmdfServiceName)
    } elseif ($existing) {
        $arr = @($existing)
        $same = ($arr.Count -eq 1 -and $arr[0] -eq $script:KmdfServiceName)
    }

    if ($same) {
        Write-KmdfLog -Message "LowerFilters already sole MagicMouseDriver on $InstanceId" -Level 'OK'
        return $true
    }

    if ($existing) {
        Write-KmdfLog -Message "Replacing LowerFilters '$($existing -join ',')' with MagicMouseDriver only" -Level 'WARN'
    }
    Set-ItemProperty -LiteralPath $regPath -Name 'LowerFilters' -Value $wanted -Type MultiString
    Write-KmdfLog -Message "LowerFilters=MagicMouseDriver (sole) on $InstanceId" -Level 'OK'
    return $true
}

function Test-KmdfHvci {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    if (Test-Path -LiteralPath $key) {
        $enabled = (Get-ItemProperty -LiteralPath $key -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
        if ($enabled -eq 1) { return $true }
    }
    return $false
}

function Test-KmdfTestSigning {
    $out = & bcdedit.exe /enum '{current}' 2>&1 | Out-String
    return [bool]($out -match '(?im)^\s*testsigning\s+Yes\s*$')
}

function Enable-KmdfTestSigning {
    if (Test-KmdfTestSigning) {
        Write-KmdfLog -Message "Test signing already ON" -Level 'OK'
        return $false
    }
    Write-KmdfLog -Message "Enabling test signing (bcdedit /set testsigning on). Desktop watermark is expected. Reboot required before the self-signed .sys will load." -Level 'WARN'
    & bcdedit.exe /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-KmdfLog -Message "bcdedit testsigning failed (exit $LASTEXITCODE)" -Level 'ERROR'
        throw "bcdedit /set testsigning on failed"
    }
    return $true
}

function Find-KmdfSignTool {
    $candidates = @(
        'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe',
        'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe',
        'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22000.0\x64\signtool.exe',
        'C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe'
    )
    foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $candidates += (Join-Path $drv.RootDirectory.FullName 'Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe')
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $found = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '\\x64$' } |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Find-KmdfInf2Cat {
    $found = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter 'inf2cat.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '\\x86$|\\x64$' } |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Find-KmdfMsBuild {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null |
            Select-Object -First 1
        if ($msbuild -and (Test-Path -LiteralPath $msbuild)) { return $msbuild }
    }
    foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $setup = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
        if (Test-Path -LiteralPath $setup) { return "EWDK:$setup" }
    }
    return $null
}

function Invoke-KmdfBluetoothBounce {
    Write-KmdfLog -Message "Bouncing Bluetooth (disable then enable). This is required for HidBth to rebuild the 0323 stack around MagicMouseDriver." -Level 'HEAD'

    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'Bluetooth' -or $_.Name -match 'Bluetooth'
        })
    foreach ($a in $adapters) {
        Write-KmdfLog -Message "Disable-NetAdapter $($a.Name)" -Level 'INFO'
        try {
            Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
        } catch {
            Write-KmdfLog -Message "Disable-NetAdapter $($a.Name): $_" -Level 'WARN'
        }
    }
    Start-Sleep -Seconds 4
    foreach ($a in $adapters) {
        Write-KmdfLog -Message "Enable-NetAdapter $($a.Name)" -Level 'INFO'
        try {
            Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
        } catch {
            Write-KmdfLog -Message "Enable-NetAdapter $($a.Name): $_" -Level 'WARN'
        }
    }
    Start-Sleep -Seconds 5

    $mice = @(Get-Kmdf0323Device)
    foreach ($m in $mice) {
        Write-KmdfLog -Message "pnputil /restart-device $($m.InstanceId)" -Level 'INFO'
        & pnputil.exe /restart-device $m.InstanceId 2>&1 | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
    }
    Start-Sleep -Seconds 3
}

function Save-KmdfState {
    param([hashtable]$State)
    Initialize-KmdfDataDir
    ($State | ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:KmdfState -Encoding UTF8
}

function Read-KmdfState {
    if (-not (Test-Path -LiteralPath $script:KmdfState)) { return @{} }
    try {
        return Get-Content -LiteralPath $script:KmdfState -Raw | ConvertFrom-Json
    } catch {
        return @{}
    }
}
