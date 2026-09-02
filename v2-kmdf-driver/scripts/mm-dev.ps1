<#
.SYNOPSIS
    Magic Mouse driver development cycle - state/build/sign/install/capture in one script.

.DESCRIPTION
    Enforces the loop: Understand state -> Implement -> Test -> Understand state.
    Every step is timestamped and logged to $SessionLog.

    Run from WSL:
        powershell.exe -ExecutionPolicy Bypass -File "D:\mm3-driver\scripts\mm-dev.ps1" -Phase Full

    Run directly (Admin PowerShell):
        .\mm-dev.ps1 -Phase Full
        .\mm-dev.ps1 -Phase State
        .\mm-dev.ps1 -Phase Build
        .\mm-dev.ps1 -Phase Install
        .\mm-dev.ps1 -Phase Capture

.PARAMETER Phase
    State    - Snapshot current PnP + driver state
    Build    - EWDK msbuild (Rebuild)
    Sign     - signtool sign .sys + .cat
    Install  - Remove old driver, install new, restart device
    Verify   - Post-install health check (LowerFilters, COL01 status, oem package)
    Rollback - Remove our filter driver entirely (recovery path)
    Restore  - Re-apply LowerFilters without rebuild (use after BT reconnect)
    Capture  - (Re)start DebugView capturing to $DebugLog
    Full     - State -> Build -> Sign -> Install -> Verify -> State
    Log      - Tail last 40 lines of session log
    Debug    - Tail last 40 MagicMouse lines from debug log
#>
param(
    [ValidateSet('State','Build','Sign','Install','Verify','Rollback','Restore','Capture','Full','Log','Debug')]
    [string]$Phase = 'Full',

    [string]$EwdkRoot   = 'F:\',
    [string]$PkgDir     = 'D:\mm3-pkg',
    [string]$SessionLog = 'C:\mm-dev-session.log',
    [string]$DebugLog   = 'C:\mm3-debug.log',
    [string]$Thumbprint = 'B902C2864315E2DE359450024768CE7D01715C38',
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$VendorPid  = 'VID&0001004c_PID&0323',  # Magic Mouse 2024 - used for device autodetect
    [string]$DbgViewExe = 'C:\SysinternalsSuite\Dbgview.exe',
    [string]$SignToolExe = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe',
    [switch]$NoElevate    # internal flag - set when re-launched as admin to prevent infinite recursion
)

# ---------------------------------------------------------------------------
# Self-elevation - re-launch as admin if needed (UAC prompt once per call)
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Host "[mm-dev] Not Administrator - elevating via UAC (accept the prompt)..." -ForegroundColor Yellow

    # Build relaunch arg list - preserve all bound params + add -NoElevate sentinel
    $relaunchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSCommandPath",'-NoElevate')
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $relaunchArgs += "-$k" }
        } else {
            $relaunchArgs += "-$k"
            $relaunchArgs += "$v"
        }
    }
    if (-not ($PSBoundParameters.ContainsKey('Phase'))) {
        $relaunchArgs += '-Phase'; $relaunchArgs += "$Phase"
    }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
                              -ArgumentList $relaunchArgs `
                              -Verb RunAs -Wait -PassThru `
                              -WindowStyle Normal
        Write-Host "[mm-dev] Elevated phase exited with code $($proc.ExitCode)" -ForegroundColor Cyan
        Write-Host "[mm-dev] Session log: $SessionLog" -ForegroundColor Cyan
        exit $proc.ExitCode
    } catch {
        Write-Host "[mm-dev] Elevation cancelled or failed: $_" -ForegroundColor Red
        exit 2
    }
}

# Auto-detect device ID by VID/PID (avoids hardcoded MAC that breaks on re-pair)
function Resolve-DeviceId {
    $devs = pnputil /enum-devices /connected 2>&1 | Out-String
    $blocks = $devs -split "(?=Instance ID:)"
    foreach ($b in $blocks) {
        if ($b -match "Instance ID:\s+(BTHENUM\\\{00001124[^\r\n]*$VendorPid[^\r\n]*)" ) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# Derive driver source root from script location (scripts\ -> repo root).
# Guard against $PSScriptRoot being null when called from a scheduled task context.
$DriverRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { 'D:\mm3-driver' }
$BuildOut   = Join-Path $DriverRoot 'x64\Debug'
$VcxProj    = Join-Path $DriverRoot 'MagicMouseDriver.vcxproj'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"
    Add-Content -Path $SessionLog -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'HEAD'  { Write-Host "`n$line" -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Write-Section {
    param([string]$Title)
    $bar = '=' * 60
    $line = "$bar`n=== $Title`n$bar"
    Add-Content -Path $SessionLog -Value $line -Encoding UTF8
    Write-Host "`n$line" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
function Get-DriverState {
    Write-Section "STATE SNAPSHOT - $(Get-Date -Format 'HH:mm:ss')"

    # PnP devices matching our mouse
    Write-Log "--- PnP devices (Magic Mouse 0x0323) ---"
    $devs = pnputil /enum-devices /connected 2>&1
    $relevant = $devs | Select-String -Pattern '0323|MagicMouse|Magic Mouse|COL01|COL02|oem52' -Context 0,5
    if ($relevant) {
        $relevant | ForEach-Object { Write-Log $_.Line }
    } else {
        Write-Log "(no matching connected devices)" 'WARN'
    }

    # Our driver package
    Write-Log "--- Installed driver package ---"
    $pkgs = pnputil /enum-drivers 2>&1
    $ourPkg = ($pkgs | Select-String -Pattern 'MagicMouse|magicmouse' -Context 0,6)
    if ($ourPkg) {
        $ourPkg | ForEach-Object { Write-Log $_.Line }
    } else {
        Write-Log "(MagicMouseDriver not installed)" 'WARN'
    }

    # COL01 / COL02 status
    Write-Log "--- HID child devices ---"
    $col = pnputil /enum-devices 2>&1 | Select-String 'COL01|COL02' -Context 0,4
    if ($col) {
        $col | ForEach-Object { Write-Log $_.Line }
    } else {
        Write-Log "(COL01/COL02 not found)" 'WARN'
    }

    # LowerFilters registry
    Write-Log "--- LowerFilters registry ---"
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0323\9&73b8b28&0&D0C050CC8C4D_C00000000'
    try {
        $lf = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
        Write-Log "LowerFilters = $($lf -join ', ')" $(if ($lf -contains 'MagicMouseDriver') {'OK'} else {'WARN'})
    } catch {
        Write-Log "Registry key not found (device not paired?)" 'WARN'
    }

    # Built artifact info
    Write-Log "--- Build artifact ---"
    $sys = Join-Path $BuildOut 'MagicMouseDriver.sys'
    if (Test-Path $sys) {
        $fi = Get-Item $sys
        Write-Log "MagicMouseDriver.sys  size=$($fi.Length)  modified=$($fi.LastWriteTime)" 'OK'
    } else {
        Write-Log "MagicMouseDriver.sys not found at $BuildOut" 'WARN'
    }

    # Last debug entries
    Write-Log "--- Last 15 MagicMouse debug lines ---"
    if (Test-Path $DebugLog) {
        $lines = Get-Content $DebugLog | Select-String 'MagicMouse' | Select-Object -Last 15
        if ($lines) { $lines | ForEach-Object { Write-Log $_.Line } }
        else { Write-Log "(no MagicMouse entries yet)" }
    } else {
        Write-Log "(debug log not found - DebugView not running?)" 'WARN'
    }

    Write-Log "State snapshot complete." 'OK'
}

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------
function Build-Driver {
    Write-Section "BUILD - $(Get-Date -Format 'HH:mm:ss')"

    if (-not (Test-Path $VcxProj)) {
        Write-Log "vcxproj not found: $VcxProj" 'ERROR'
        return $false
    }

    # Use SetupBuildEnv.cmd directly (sets env vars and returns).
    # NOT LaunchBuildEnv.cmd: that wraps SetupBuildEnv in `cmd /k` which spawns
    # an interactive shell that never exits, hanging the entire pipeline.
    $ewdkSetup = Join-Path $EwdkRoot 'BuildEnv\SetupBuildEnv.cmd'

    # If not found at $EwdkRoot, scan all ready drives (handles ISO mounted to any letter).
    if (-not (Test-Path $ewdkSetup)) {
        Write-Log "EWDK not at $ewdkSetup - scanning drives..." 'WARN'
        foreach ($drv in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
            $candidate = Join-Path $drv.RootDirectory.FullName 'BuildEnv\SetupBuildEnv.cmd'
            if (Test-Path $candidate) {
                $ewdkSetup = $candidate
                Write-Log "Found EWDK at $ewdkSetup" 'OK'
                break
            }
        }
    }

    if (-not (Test-Path $ewdkSetup)) {
        Write-Log "EWDK SetupBuildEnv.cmd not found on any drive. Mount the ISO first." 'ERROR'
        return $false
    }

    Write-Log "Running EWDK msbuild (Rebuild) via temp batch file..."
    # Write a temp .bat to avoid PowerShell→cmd double-quote mangling.
    # cmd /c with embedded quotes produces '""' is not recognized errors.
    $tempBat = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.bat'
    @"
@echo off
call "$ewdkSetup" >NUL 2>&1
if errorlevel 1 (
    echo [BUILD] EWDK SetupBuildEnv.cmd failed >&2
    exit /b 1
)
msbuild "$VcxProj" /p:Configuration=Debug /p:Platform=x64 /t:Rebuild /nologo /v:minimal /p:SignFiles=false /p:EnableCodeSigning=false
"@ | Out-File -FilePath $tempBat -Encoding ASCII
    Write-Log "Batch file: $tempBat"
    $output = cmd /c $tempBat 2>&1
    Remove-Item $tempBat -Force -ErrorAction SilentlyContinue
    $output | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }

    $sys     = Join-Path $BuildOut 'MagicMouseDriver.sys'
    $presign = 'C:\mm3-presign\MagicMouseDriver.sys'

    if (Test-Path $sys) {
        Write-Log "Build succeeded: $sys" 'OK'
        return $true
    } elseif (Test-Path $presign) {
        # SIGNTASK failed and deleted the .sys, but BackupPreSign saved it before sign ran.
        Write-Log "SIGNTASK deleted .sys - restoring from BackupPreSign ($presign)" 'WARN'
        Copy-Item $presign $sys -Force
        Write-Log "Build succeeded (presign restored): $sys" 'OK'
        return $true
    } else {
        Write-Log "Build FAILED - .sys not produced and no presign backup found." 'ERROR'
        # Show last 20 lines of build output
        $output | Select-Object -Last 20 | ForEach-Object { Write-Log $_ 'ERROR' }
        return $false
    }
}

# ---------------------------------------------------------------------------
# SIGN
# ---------------------------------------------------------------------------
function Sign-Driver {
    Write-Section "SIGN - $(Get-Date -Format 'HH:mm:ss')"

    if (-not (Test-Path $SignToolExe)) {
        # Try to find signtool in common WDK locations
        $candidates = @(
            'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe',
            'C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe'
        )
        $SignToolExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $SignToolExe) {
            Write-Log "signtool.exe not found - install Windows SDK/WDK" 'ERROR'
            return $false
        }
    }

    $targets = @(
        (Join-Path $BuildOut 'MagicMouseDriver.sys'),
        (Join-Path $BuildOut 'MagicMouseDriver.cat')
    )

    $ok = $true
    foreach ($target in $targets) {
        if (-not (Test-Path $target)) {
            Write-Log "Not found, skipping: $target" 'WARN'
            continue
        }
        Write-Log "Signing: $(Split-Path -Leaf $target)"
        $result = & $SignToolExe sign /sm /v /sha1 $Thumbprint /fd SHA256 /t $TimestampUrl $target 2>&1
        $result | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Signed OK: $(Split-Path -Leaf $target)" 'OK'
        } else {
            Write-Log "Sign FAILED: $(Split-Path -Leaf $target)" 'ERROR'
            $ok = $false
        }
    }
    return $ok
}

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------
function Get-CurrentOemPackage {
    # Robust line-by-line parse of pnputil /enum-drivers to find our oem*.inf number.
    # Used only for informational Verify checks; Install no longer calls pnputil /add-driver
    # (it hangs in SYSTEM context due to silent cert-trust dialogs).
    $out = pnputil /enum-drivers 2>&1
    $currentOem = $null
    $candidate  = $null
    foreach ($line in $out) {
        if ($line -match 'Published Name:\s+(oem\d+\.inf)') {
            $candidate = $Matches[1]
        }
        if ($line -match 'magicmousedriver\.inf' -and $candidate) {
            $currentOem = $candidate
            break
        }
    }
    return $currentOem
}

function Uninstall-DriverDirect {
    # Order matters: remove LowerFilters FIRST, restart device (unloads .sys from stack),
    # THEN sc.exe delete + Remove-Item .sys. Trying to delete a loaded .sys fails with
    # "used by another process" even after sc.exe delete marks the service for deletion.
    $devId = Resolve-DeviceId
    if ($devId) {
        $rp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId"
        try {
            $lf = (Get-ItemProperty $rp -ErrorAction Stop).LowerFilters
            if ($lf -contains 'MagicMouseDriver') {
                $newLf = @($lf | Where-Object { $_ -ne 'MagicMouseDriver' })
                if ($newLf.Count -gt 0) {
                    Set-ItemProperty $rp -Name LowerFilters -Value $newLf -Type MultiString
                } else {
                    Remove-ItemProperty $rp -Name LowerFilters -ErrorAction SilentlyContinue
                }
                Write-Log "LowerFilters: removed MagicMouseDriver - restarting device to unload driver" 'OK'
                pnputil /restart-device $devId 2>&1 | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
                Start-Sleep -Seconds 2
            }
        } catch { }
    }

    Write-Log "Stopping service..."
    sc.exe stop MagicMouseDriver 2>&1 | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
    Write-Log "Deleting service..."
    $scDel = sc.exe delete MagicMouseDriver 2>&1
    $scDel | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }

    $sysDest = 'C:\Windows\System32\drivers\MagicMouseDriver.sys'
    if (Test-Path $sysDest) {
        Remove-Item $sysDest -Force -ErrorAction SilentlyContinue
        if (Test-Path $sysDest) {
            Write-Log "$sysDest still locked after device restart - attempting rename workaround" 'WARN'
            Rename-Item $sysDest "$sysDest.old" -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "Removed $sysDest" 'OK'
        }
    }
}

function Install-Driver {
    Write-Section "INSTALL - $(Get-Date -Format 'HH:mm:ss')"

    # Uninstall any previous install (no pnputil; direct sc.exe + registry).
    Uninstall-DriverDirect

    # Step 1: Copy .sys to System32\drivers (INF DestinationDir 12 = drivers\).
    $sysSrc  = Join-Path $BuildOut 'MagicMouseDriver.sys'
    $sysDest = 'C:\Windows\System32\drivers\MagicMouseDriver.sys'
    if (-not (Test-Path $sysSrc)) {
        Write-Log ".sys not found at $sysSrc" 'ERROR'
        return $false
    }
    Copy-Item $sysSrc $sysDest -Force
    Write-Log "Copied .sys to $sysDest" 'OK'

    # Step 2: Register kernel service (replaces INF [Install.Services] AddService).
    # sc.exe requires spaces after '=' - this is intentional PowerShell sc.exe syntax.
    # Retry once on exit 1072 (marked for deletion): the previous service object may still
    # be draining references when we arrive here, cleared within ~2s of device restart.
    Write-Log "Creating kernel service MagicMouseDriver"
    $scCreateArgs = @('create','MagicMouseDriver','type=','kernel','start=','demand',
                      'binPath=','system32\drivers\MagicMouseDriver.sys',
                      'DisplayName=','Magic Mouse Driver')
    $scOut = sc.exe @scCreateArgs 2>&1
    $scOut | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
    if ($LASTEXITCODE -eq 1072) {
        Write-Log "sc.exe create returned 1072 (service marked for deletion) - waiting 3s and retrying" 'WARN'
        Start-Sleep -Seconds 3
        $scOut = sc.exe @scCreateArgs 2>&1
        $scOut | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Service created." 'OK'
    } else {
        Write-Log "sc.exe create exited $LASTEXITCODE" 'WARN'
    }

    # Step 3: Resolve device and apply LowerFilters + restart.
    $devId = Resolve-DeviceId
    if (-not $devId) {
        Write-Log "Device not currently connected - driver staged; connect mouse and run Verify" 'WARN'
        return $true
    }
    Write-Log "Device: $devId"

    # Set LowerFilters — MagicMouseDriver(0) below applewirelessmouse(1).
    # Our driver at index 0 patches SDP completion first; applewirelessmouse sees our
    # combined descriptor and does not re-patch. Swapping (test ee18af4) confirmed
    # applewirelessmouse DOES gesture processing but conflicts with our combined descriptor
    # (produces spurious clicks). Gesture processing is deferred to M14 in our own driver.
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId"
    $targetLf = @('MagicMouseDriver', 'applewirelessmouse')
    try {
        $existing = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
        $needsUpdate = ($null -eq $existing) -or
                       ($existing.Count -ne $targetLf.Count) -or
                       ($existing[0] -ne $targetLf[0]) -or
                       ($existing[1] -ne $targetLf[1])
        if ($needsUpdate) {
            Set-ItemProperty $regPath -Name LowerFilters -Value $targetLf -Type MultiString
            Write-Log "LowerFilters set: $($targetLf -join ',')" 'OK'
        } else {
            Write-Log "LowerFilters already correct: $($existing -join ',')" 'OK'
        }
    } catch {
        Write-Log "Cannot set LowerFilters at $regPath : $_" 'ERROR'
        return $false
    }

    # Step 4: Restart device to rebuild stack with new lower filter.
    Write-Log "Restarting device: $devId"
    $out = pnputil /restart-device $devId 2>&1
    $out | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Device restart sent." 'OK'
    } else {
        Write-Log "pnputil /restart-device exited $LASTEXITCODE" 'WARN'
    }

    Start-Sleep -Seconds 4

    # Step 5: Re-apply LowerFilters after restart.
    # pnputil /restart-device triggers a full BTHENUM re-enumeration. PnP re-runs the selected
    # driver INF (oem0.inf / applewirelessmouse.inf) which has a replace-flag AddReg:
    #   HKR,,"LowerFilters",0x00010000,"applewirelessmouse"   <- overwrites our entry
    # The current stack survives the restart with our driver loaded, but the registry is reset.
    # Re-applying here ensures the registry matches reality so the NEXT restart (BT reconnect,
    # reboot) also loads MagicMouseDriver.
    try {
        $postLf = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
        $postNeedsUpdate = ($null -eq $postLf) -or
                           ($postLf.Count -ne $targetLf.Count) -or
                           ($postLf[0] -ne $targetLf[0]) -or
                           ($postLf[1] -ne $targetLf[1])
        if ($postNeedsUpdate) {
            Set-ItemProperty $regPath -Name LowerFilters -Value $targetLf -Type MultiString
            Write-Log "LowerFilters re-applied post-restart (oem0.inf reset guard): $($targetLf -join ',')" 'OK'
        } else {
            Write-Log "LowerFilters intact post-restart: $($postLf -join ',')" 'OK'
        }
    } catch {
        Write-Log "Cannot re-apply LowerFilters post-restart: $_" 'WARN'
    }

    Write-Log "Install complete." 'OK'
    return $true
}

# ---------------------------------------------------------------------------
# VERIFY - post-install health check
# ---------------------------------------------------------------------------
function Verify-Install {
    Write-Section "VERIFY - $(Get-Date -Format 'HH:mm:ss')"
    $allOk = $true

    # 1. oem package (INFO only - we bypass pnputil /add-driver, so no oem entry is expected)
    $oem = Get-CurrentOemPackage
    if ($oem) {
        Write-Log "oem package: $oem" 'OK'
    } else {
        Write-Log "No oem package (expected - using direct sc.exe install)" 'INFO'
    }

    # 2. Service exists and .sys present?
    $svc = Get-Service MagicMouseDriver -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "Service MagicMouseDriver: $($svc.Status)" 'OK'
    } else {
        Write-Log "Service MagicMouseDriver not found" 'ERROR'
        $allOk = $false
    }
    $sysDest = 'C:\Windows\System32\drivers\MagicMouseDriver.sys'
    if (Test-Path $sysDest) {
        $sz = (Get-Item $sysDest).Length
        Write-Log ".sys present: $sysDest ($sz bytes)" 'OK'
    } else {
        Write-Log ".sys missing: $sysDest" 'ERROR'
        $allOk = $false
    }

    # 3. Device connected?
    $devId = Resolve-DeviceId
    if (-not $devId) {
        Write-Log "Device not connected - cannot verify runtime state" 'WARN'
        return $allOk
    }
    Write-Log "Device: $devId" 'OK'

    # 4. LowerFilters has MagicMouseDriver?
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId"
    try {
        $lf = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
        if ($lf -contains 'MagicMouseDriver') {
            Write-Log "LowerFilters: $($lf -join ',') (MagicMouseDriver bound)" 'OK'
        } else {
            Write-Log "LowerFilters: $($lf -join ',') - MagicMouseDriver NOT bound" 'ERROR'
            $allOk = $false
        }
    } catch {
        Write-Log "Cannot read LowerFilters at $regPath" 'ERROR'
        $allOk = $false
    }

    # 5. COL01 (HID mouse child) present?
    # Use pnputil /enum-devices without /connected - HID children are not "Bluetooth-connected"
    # but do appear as Started devices under the HID bus.
    $devAll = pnputil /enum-devices 2>&1 | Out-String
    $col01Found = $devAll -match "VID&0001004c_PID&0323&Col01"
    if ($col01Found) {
        Write-Log "COL01 (HID-compliant mouse): enumerated" 'OK'
    } else {
        Write-Log "COL01 not found in device list - HID descriptor may be missing scroll collection" 'WARN'
    }

    # 6. Diag registry keys (written by driver timer at 1Hz to Services\MagicMouseDriver\Diag)
    $diagPath = "HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver\Diag"
    if (Test-Path $diagPath) {
        $diag = Get-ItemProperty $diagPath -ErrorAction SilentlyContinue
        Write-Log "Diag: IoctlInterceptCount=$($diag.IoctlInterceptCount) SdpScanHits=$($diag.SdpScanHits) SdpPatchSuccess=$($diag.SdpPatchSuccess) LastSdpBufSize=$($diag.LastSdpBufSize)" 'OK'
    } else {
        Write-Log "Diag key not yet created at Services\MagicMouseDriver\Diag (driver timer may not have fired or driver not attached to device stack)" 'INFO'
    }

    if ($allOk) {
        Write-Log "VERIFY PASSED - driver bound, .sys present, LowerFilters set" 'OK'
    } else {
        Write-Log "VERIFY FAILED - see findings above" 'ERROR'
    }
    return $allOk
}

# ---------------------------------------------------------------------------
# ROLLBACK - recovery path: remove our filter entirely
# ---------------------------------------------------------------------------
function Rollback-Driver {
    Write-Section "ROLLBACK - $(Get-Date -Format 'HH:mm:ss')"
    # Use direct uninstall (no pnputil /delete-driver which hangs in SYSTEM context).
    Uninstall-DriverDirect
    $devId = Resolve-DeviceId
    if ($devId) {
        Write-Log "Restarting device to drop filter binding..."
        pnputil /restart-device $devId 2>&1 | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
    }
    Write-Log "Rollback complete." 'OK'
    return $true
}

# ---------------------------------------------------------------------------
# RESTORE - re-apply LowerFilters without rebuild (recovery after BT reconnect)
# ---------------------------------------------------------------------------
function Restore-LowerFilters {
    Write-Section "RESTORE LOWERFILTERS - $(Get-Date -Format 'HH:mm:ss')"

    $devId = Resolve-DeviceId
    if (-not $devId) {
        Write-Log "Device not connected - cannot restore LowerFilters" 'WARN'
        return $false
    }
    Write-Log "Device: $devId"

    $regPath  = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId"
    $targetLf = @('applewirelessmouse', 'MagicMouseDriver')
    try {
        $existing = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
        $needsUpdate = ($null -eq $existing) -or
                       ($existing.Count -ne $targetLf.Count) -or
                       ($existing[0] -ne $targetLf[0]) -or
                       ($existing[1] -ne $targetLf[1])
        if (-not $needsUpdate) {
            Write-Log "LowerFilters already correct: $($existing -join ',')" 'OK'
        } else {
            Set-ItemProperty $regPath -Name LowerFilters -Value $targetLf -Type MultiString
            Write-Log "LowerFilters restored: $($targetLf -join ',')" 'OK'

            # Start service if not running
            $svc = Get-Service MagicMouseDriver -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                sc.exe start MagicMouseDriver 2>&1 | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
                Start-Sleep -Seconds 2
                Write-Log "Service start requested." 'OK'
            }

            # Restart device so stack rebuilds with the filter.
            Write-Log "Restarting device to apply restored LowerFilters..."
            pnputil /restart-device $devId 2>&1 | ForEach-Object { Add-Content -Path $SessionLog -Value $_ -Encoding UTF8 }
            Start-Sleep -Seconds 4

            # Re-apply post-restart guard
            $postLf = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).LowerFilters
            $postNeedsUpdate = ($null -eq $postLf) -or ($postLf[0] -ne $targetLf[0]) -or ($postLf[1] -ne $targetLf[1])
            if ($postNeedsUpdate) {
                Set-ItemProperty $regPath -Name LowerFilters -Value $targetLf -Type MultiString
                Write-Log "LowerFilters re-applied post-restart: $($targetLf -join ',')" 'OK'
            }
        }
    } catch {
        Write-Log "Cannot restore LowerFilters at $regPath : $_" 'ERROR'
        return $false
    }

    Write-Log "Restore complete." 'OK'
    return $true
}

# ---------------------------------------------------------------------------
# DEBUG CAPTURE
# ---------------------------------------------------------------------------
function Read-Rid27Captures {
    # M14: read RID=0x27 ring buffer from registry (no DebugView required).
    # The driver's 1Hz DiagWorkItem writes:
    #   Diag\HidReadCount   DWORD   total IRP_MJ_READ completions
    #   Diag\Rid27Count     DWORD   how many had buf[0]==0x27
    #   Diag\Rid27SlotsFilled DWORD  slots written (capped at 8)
    #   Diag\Rid27RingBuf   REG_BINARY  8 x 48 bytes of raw reports
    Write-Section "CAPTURE (RID=0x27 ring buffer) - $(Get-Date -Format 'HH:mm:ss')"

    $diagKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver\Diag'
    if (-not (Test-Path $diagKey)) {
        Write-Log "Diag registry key not found - driver not loaded or not M14 build" 'ERROR'
        return $false
    }

    $props        = Get-ItemProperty $diagKey -ErrorAction SilentlyContinue
    $hidReads     = $props.HidReadCount
    $rid27Count   = $props.Rid27Count
    $slotsFilled  = $props.Rid27SlotsFilled
    $ringBuf      = $props.Rid27RingBuf   # byte[] or $null

    Write-Log "HidReadCount=$hidReads  Rid27Count=$rid27Count  SlotsFilled=$slotsFilled" 'OK'

    if (-not $slotsFilled -or $slotsFilled -eq 0) {
        Write-Log "No RID=0x27 captures yet - touch the mouse surface and re-run Capture" 'WARN'
        return $false
    }

    if (-not $ringBuf -or $ringBuf.Length -eq 0) {
        Write-Log "Rid27RingBuf key empty despite SlotsFilled=$slotsFilled" 'WARN'
        return $false
    }

    # Dump each filled slot
    $nSlots = [Math]::Min($slotsFilled, 8)
    Write-Log "--- RID=0x27 ring buffer: $nSlots slot(s) ---"
    for ($i = 0; $i -lt $nSlots; $i++) {
        $offset = $i * 48
        $slot   = $ringBuf[$offset..($offset + 47)]
        $hex    = ($slot | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Write-Log "Slot[$i]: $hex"

        # Layout analysis (Linux hid-magicmouse.c reference)
        $rid     = $slot[0]
        $flags   = $slot[1]
        $ts      = [uint16]($slot[2] + ($slot[3] -shl 8))
        $nFinger = $slot[4]
        Write-Log "  RID=0x{0:X2}  flags=0x{1:X2}  ts={2}  nFingers={3}" -f $rid,$flags,$ts,$nFinger
        # Bytes 5..end: per-finger data (7 bytes each in hid-magicmouse v2/v3)
        if ($nFinger -gt 0) {
            for ($f = 0; $f -lt $nFinger; $f++) {
                $foff = 5 + ($f * 9)
                if ($foff + 8 -ge 48) { break }
                $absX = [int16]($slot[$foff] + ($slot[$foff+1] -shl 8))
                $absY = [int16]($slot[$foff+2] + ($slot[$foff+3] -shl 8))
                Write-Log ("  Finger[$f]: x={0} y={1} raw=[{2}]" -f $absX, $absY,
                    (($slot[$foff..($foff+8)]) | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
            }
        }
    }

    Write-Log "Capture complete." 'OK'
    return $true
}

# ---------------------------------------------------------------------------
# SHOW LOGS
# ---------------------------------------------------------------------------
function Show-SessionLog {
    Write-Section "SESSION LOG (last 40 lines)"
    if (Test-Path $SessionLog) {
        Get-Content $SessionLog | Select-Object -Last 40
    } else {
        Write-Log "No session log yet." 'WARN'
    }
}

function Show-DebugLog {
    Write-Section "DEBUG LOG - MagicMouse entries (last 40)"
    if (Test-Path $DebugLog) {
        $lines = Get-Content $DebugLog | Select-String 'MagicMouse' | Select-Object -Last 40
        if ($lines) { $lines | ForEach-Object { Write-Host $_.Line } }
        else { Write-Log "(no MagicMouse entries)" 'WARN' }
    } else {
        Write-Log "Debug log not found - run: .\mm-dev.ps1 -Phase Capture" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Write-Log "=== mm-dev.ps1 Phase=$Phase ===" 'HEAD'

$exitCode = 0
switch ($Phase) {
    'State'    { Get-DriverState }
    'Build'    { if (-not (Build-Driver))   { $exitCode = 1 } }
    'Sign'     { if (-not (Sign-Driver))    { $exitCode = 1 } }
    'Install'  { if (-not (Install-Driver)) { $exitCode = 1 } }
    'Verify'   { if (-not (Verify-Install)) { $exitCode = 1 } }
    'Rollback' { if (-not (Rollback-Driver)){ $exitCode = 1 } }
    'Restore'  { if (-not (Restore-LowerFilters)) { $exitCode = 1 } }
    'Capture'  { if (-not (Read-Rid27Captures)) { $exitCode = 1 } }
    'Log'      { Show-SessionLog }
    'Debug'    { Show-DebugLog }
    'Full' {
        Get-DriverState
        $ok = Build-Driver
        if ($ok) { $ok = Sign-Driver }
        if ($ok) { $ok = Install-Driver }
        if ($ok) { $ok = Verify-Install }
        Get-DriverState
        if ($ok) {
            Read-Rid27Captures | Out-Null
            Write-Log "Full cycle complete - touch mouse surface then run Capture to read ring buffer." 'OK'
        } else {
            Write-Log "Full cycle FAILED - check session log: $SessionLog" 'ERROR'
            $exitCode = 1
        }
    }
}

Write-Log "Done. Session log: $SessionLog (exit=$exitCode)"
exit $exitCode
