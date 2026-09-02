# startup-repair.ps1 - MagicMouseTray WDF Filter Repair
# SPDX-License-Identifier: MIT
#
# Runs at startup via Windows Scheduled Task (SYSTEM account, 30s delay).
# Detects whether the WDF filter has enumerated all 3 HID collections (COL01,
# COL02, COL03). If any are missing the repair triggers pnputil /restart-device
# on the BTHENUM parent WITH the filter in place, which forces a fresh SDP
# negotiation. The WDF filter intercepts the SDP IOCTL and injects the fixed
# 135-byte descriptor, producing:
#   COL01 -> Generic Desktop Mouse (mouhid, cursor + scroll)
#   COL02 -> Vendor 0xFF00/0x14 (HIDClass, battery via RID=0x90)
#   COL03 -> Vendor 0xFF00/0x27 (HIDClass, raw touch data)
#
# CRITICAL: DO call pnputil /restart-device WITH the filter registered. The WDF
# filter produces the correct 3-TLC descriptor on SDP renegotiation -- unlike the
# old applewirelessmouse.sys which would strip COL02 when the filter was active
# during descriptor re-processing. Old cycle-without-filter repair is WRONG here.
#
# Usage (manual): powershell -ExecutionPolicy Bypass -File startup-repair.ps1
# Usage (scheduled task): registered by install-driver.ps1 - runs automatically.

param(
    [string]$LogFile = "C:\ProgramData\MagicMouseTray\startup-repair.log",
    [int]$SettleSeconds = 12   # wait after restart-device before checking result
)

$MaxLogBytes = 512KB

function Write-Log {
    param([string]$Msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ---- bootstrap ----
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogBytes) {
    $archive = [System.IO.Path]::ChangeExtension($LogFile, "1.log")
    Move-Item $LogFile $archive -Force
}

Write-Log "startup-repair: begin (WDF filter mode)"

# PATH-A v5 SRE-Windows fix (S2): only v3 (PID 0323) has multi-TLC enumeration.
# v1 (030D), v2 (0269), and 0310 use a single TLC and don't have COL02/COL03.
# Running the LowerFilter dance on those PIDs is what triggered BSOD #2 on
# 2026-05-08 (failed v1 repair at 16:01:57 → 0xD1 NULL deref at 16:15:42).
# Restrict the repair scope to v3 only.
$knownPids = @("0323")
$paramsTemplate = "HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseFixV3\Parameters"
$anyRepaired = $false

foreach ($mmPid in $knownPids) {
    if ($mmPid -ne "0323") {
        # Defensive guard: if the array is ever expanded, only v3 must run the repair.
        Write-Log "PID 0x$($mmPid.ToUpper()): skip — only v3 (0323) supports multi-TLC repair (SRE-Windows v5 S2)"
        continue
    }
    # Find BTHENUM parent device (HID service UUID {00001124} only)
    $btDevice = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match "BTHENUM" -and
                       $_.InstanceId -match "00001124" -and
                       $_.InstanceId -match "_PID&$mmPid" -and
                       $_.Status -eq 'OK' } |
        Select-Object -First 1

    if (-not $btDevice) {
        continue  # PID not paired - normal, skip silently
    }

    Write-Log "PID 0x$($mmPid.ToUpper()): BTHENUM = $($btDevice.InstanceId)"

    # Count HIDClass child devices. COL01 is claimed by mouhid (Mouse class) so
    # it does NOT appear in HIDClass. Healthy state: BTHENUM parent + COL02 + COL03
    # = 3 HIDClass devices. Less than 3 means SDP patch did not produce all TLCs.
    $hidDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.Class -eq 'HIDClass' -and
                       $_.InstanceId -match $mmPid -and
                       $_.Status -eq 'OK' })

    $hidCount = $hidDevices.Count
    if ($hidCount -ge 3) {
        Write-Log "PID 0x$($mmPid.ToUpper()): HID OK ($hidCount) - no repair needed"
        continue
    }

    Write-Log "PID 0x$($mmPid.ToUpper()): HID count=$hidCount (need 3) - starting WDF repair"

    $btRegPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $btDevice.InstanceId

    if (-not (Test-Path $btRegPath)) {
        Write-Log "ERROR: registry path not found: $btRegPath"
        continue
    }

    # Step 1: Verify our patched binary is present (PATH-A v5 renamed from
    # applewirelessmouse.sys to MagicMouseFixV3.sys — see SRE-Windows v5 review S1).
    $wdfBin = "C:\Windows\System32\drivers\MagicMouseFixV3.sys"
    $wdfItem = Get-Item $wdfBin -ErrorAction SilentlyContinue
    if (-not $wdfItem) {
        Write-Log "CRITICAL: $wdfBin missing - cannot repair without WDF binary"
        continue
    }
    Write-Log "Step 1: WDF binary present ($($wdfItem.Length) bytes)"

    # Step 2: Verify/set EnableInjection=1
    $paramsKey = $paramsTemplate
    if (-not (Test-Path $paramsKey)) {
        New-Item -Path $paramsKey -Force | Out-Null
    }
    $ei = (Get-ItemProperty $paramsKey -Name "EnableInjection" -ErrorAction SilentlyContinue).EnableInjection
    if ($ei -ne 1) {
        Write-Log "Step 2: EnableInjection=$ei -- setting to 1"
        Set-ItemProperty -Path $paramsKey -Name "EnableInjection" -Value 1 -Type DWord
    } else {
        Write-Log "Step 2: EnableInjection=1 (OK)"
    }

    # Step 3: Verify/set LowerFilters on Enum key (PATH-A v5: MagicMouseFixV3, not applewirelessmouse).
    $lfEnum = (Get-ItemProperty -Path $btRegPath -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
    if (-not ($lfEnum -contains 'MagicMouseFixV3')) {
        Write-Log "Step 3: Enum LowerFilters missing MagicMouseFixV3 -- setting"
        Set-ItemProperty -Path $btRegPath -Name LowerFilters -Value @("MagicMouseFixV3") -Type MultiString -ErrorAction SilentlyContinue
    } else {
        Write-Log "Step 3: Enum LowerFilters OK ($($lfEnum -join ', '))"
    }

    # Step 3b: Verify/set LowerFilters on driver instance (Class) key
    $driverKey = (Get-ItemProperty -Path $btRegPath -Name Driver -ErrorAction SilentlyContinue).Driver
    if ($driverKey) {
        $driverInstPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driverKey"
        if (Test-Path $driverInstPath) {
            $lfClass = (Get-ItemProperty $driverInstPath -Name LowerFilters -ErrorAction SilentlyContinue).LowerFilters
            if (-not ($lfClass -contains 'MagicMouseFixV3')) {
                Write-Log "Step 3b: Class key LowerFilters missing -- setting"
                Set-ItemProperty -Path $driverInstPath -Name LowerFilters -Value @("MagicMouseFixV3") -Type MultiString -ErrorAction SilentlyContinue
            } else {
                Write-Log "Step 3b: Class key LowerFilters OK"
            }
        }
    }

    # Step 4: Restart BTHENUM device WITH WDF filter in place.
    # The filter intercepts IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE and replaces
    # the HIDDescriptorList with our 135-byte 3-TLC descriptor. This produces the
    # correct 3 HID child PDOs without needing to remove the filter first.
    try {
        Write-Log "Step 4: pnputil /restart-device $($btDevice.InstanceId)"
        $out = pnputil /restart-device "$($btDevice.InstanceId)" 2>&1
        $lastLine = ($out | Select-Object -Last 2 | Out-String).TrimEnd()
        Write-Log "  pnp: $lastLine"

        Write-Log "Step 4: waiting $SettleSeconds seconds for SDP negotiation..."
        Start-Sleep -Seconds $SettleSeconds

        # Step 5: Verify result
        $hidAfter = @(Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.Class -eq 'HIDClass' -and
                           $_.InstanceId -match $mmPid -and
                           $_.Status -eq 'OK' })
        $hidAfterCount = $hidAfter.Count

        if ($hidAfterCount -ge 3) {
            Write-Log "REPAIRED: HID OK=$hidAfterCount (COL01 mouhid + COL02 battery + COL03 touch)"
            $anyRepaired = $true
        } else {
            Write-Log "WARNING: repair attempted - HID count=$hidAfterCount (need 3)"
            $hidAfter | ForEach-Object { Write-Log "  found: $($_.InstanceId)" }
            Write-Log "  Possible causes:"
            Write-Log "    - MagicMouseFixV3.sys unsigned or wrong binary (run dist/PATH-A-v5/install.ps1)"
            Write-Log "    - CN=MagicMouseFix cert not in LocalMachine\\TrustedPublisher"
            Write-Log "    - testsigning BCD not active (bcdedit /set testsigning on)"
        }

    } catch {
        Write-Log "ERROR during restart-device: $($_.Exception.Message)"
    }
}

Write-Log "startup-repair: complete (repaired=$anyRepaired)"
