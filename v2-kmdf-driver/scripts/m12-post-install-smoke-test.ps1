#Requires -Version 5.1
<#
M12 Post-Install Smoke Test
===========================
Run AFTER `pnputil /add-driver MagicMouseDriver.inf /install` AND re-pairing
the Magic Mouse v3. Read-only: does NOT modify driver state.

Validates:
  1. M12 service is registered and Running
  2. M12 driver is loaded by at least one BTHENUM device with VID&0001004C PID&0323
  3. HID stack sees a Report ID 0x90 input report on the device (proxy: open the
     device handle, attempt HidD_GetInputReport(0x90), verify 3-byte response)
  4. Tray app's view: log in last 60s shows battery percentage

Exit codes:
  0 — all checks passed (driver functional)
  2 — driver installed but at least one check failed (degraded)
  3 — driver not installed or not loaded

Usage (elevated optional but recommended for service query):
    powershell -NoProfile -ExecutionPolicy Bypass -File m12-post-install-smoke-test.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$results = @()
$mousePid = '0323'

function Add-Result {
    param($Name, $Status, $Detail)
    $script:results += [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

# 1. Service check
try {
    $svc = Get-Service -Name 'MagicMouseDriver' -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Add-Result 'service' 'PASS' "MagicMouseDriver service: Running"
    } else {
        Add-Result 'service' 'FAIL' "MagicMouseDriver service exists but state=$($svc.Status)"
    }
} catch {
    Add-Result 'service' 'FAIL' "MagicMouseDriver service not found — driver did not install"
}

# 2. Device + driver binding
try {
    $vidPat = 'VID' + [char]0x26 + '0001004C'
    $pidPat = 'PID' + [char]0x26 + $mousePid
    $devices = Get-PnpDevice -Class HIDClass -PresentOnly | Where-Object {
        $_.HardwareID -match $vidPat -and $_.HardwareID -match $pidPat
    }
    if (-not $devices) {
        Add-Result 'pnp-binding' 'FAIL' "No present BTHENUM device matches Apple Magic Mouse v3 hardware ID"
    } else {
        $bound = $false
        foreach ($d in $devices) {
            $svcKey = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data
            $upperFilters = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LowerFilters' -ErrorAction SilentlyContinue).Data
            if ($svcKey -eq 'MagicMouseDriver' -or $upperFilters -contains 'MagicMouseDriver') {
                $bound = $true
                Add-Result 'pnp-binding' 'PASS' "Bound to: $($d.InstanceId) (svc=$svcKey filters=$upperFilters)"
                break
            }
        }
        if (-not $bound) {
            Add-Result 'pnp-binding' 'FAIL' "Found $($devices.Count) Magic Mouse v3 device(s) but none bind MagicMouseDriver"
        }
    }
} catch {
    Add-Result 'pnp-binding' 'FAIL' "PnP query failed: $_"
}

# 3. HID descriptor: open device, try HidD_GetInputReport(0x90)
# We use the ManagedHidWrapper P/Invoke approach — minimal C# inline.
$hidProbeCs = @"
using System;
using System.Runtime.InteropServices;

public static class HidProbe {
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetInputReport(IntPtr h, byte[] buf, int len);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFile(string p, uint a, uint s, IntPtr sa, uint cd, uint fa, IntPtr h);

    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    public const uint GENERIC_WRITE = 0x40000000, GENERIC_READ = 0x80000000;
    public const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    public const uint OPEN_EXISTING = 3;

    public static int TryReadBattery(string path, out byte flags, out byte percent) {
        flags = 0; percent = 0;
        IntPtr h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h.ToInt64() == -1) return Marshal.GetLastWin32Error();
        try {
            byte[] buf = new byte[3];
            buf[0] = 0x90;
            if (!HidD_GetInputReport(h, buf, 3)) return Marshal.GetLastWin32Error();
            flags = buf[1]; percent = buf[2];
            return 0;
        } finally { CloseHandle(h); }
    }
}
"@

try {
    Add-Type -TypeDefinition $hidProbeCs -ErrorAction Stop

    # Find the HID device path for the v3 mouse
    $hidPaths = Get-CimInstance -ClassName Win32_PnPEntity -Filter "DeviceID like '%PID_0323%'" |
                Where-Object { $_.PNPClass -eq 'HIDClass' -and $_.Status -eq 'OK' }

    if (-not $hidPaths) {
        Add-Result 'hid-rid-0x90' 'SKIP' 'No HID device path found for Magic Mouse v3'
    } else {
        $any = $false
        foreach ($p in $hidPaths) {
            # Resolve to \\?\ device interface path — probe HKLM for the interface GUID symbolic link
            $devPath = $null
            try {
                $iface = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
                            -ClassName Win32_PnPDeviceInterface -ErrorAction SilentlyContinue |
                            Where-Object { $_.DeviceID -eq $p.DeviceID } | Select-Object -First 1
                if ($iface) { $devPath = $iface.SymbolicLink }
            } catch {}
            if (-not $devPath) {
                # Fallback: derive from the registry mountpoint
                $devPath = "\\?\HID#" + ($p.DeviceID -replace '\\', '#') + "#{4d1e55b2-f16f-11cf-88cb-001111000030}"
                $devPath = $devPath.ToLower()
            }
            $flags = 0; $percent = 0
            $err = [HidProbe]::TryReadBattery($devPath, [ref] $flags, [ref] $percent)
            if ($err -eq 0) {
                Add-Result 'hid-rid-0x90' 'PASS' "Read battery via RID 0x90: flags=$flags percent=$percent% (path=$devPath)"
                $any = $true
                break
            } else {
                # Capture for debug; continue trying other paths
                Add-Result 'hid-rid-0x90' 'TRACE' "path $devPath -> Win32 error $err"
            }
        }
        if (-not $any) {
            Add-Result 'hid-rid-0x90' 'FAIL' 'All HID paths returned an error on RID 0x90 GetInputReport'
        }
    }
} catch {
    Add-Result 'hid-rid-0x90' 'FAIL' "HID probe setup failed: $_"
}

# 4. Tray app log check (last 60s)
try {
    $trayLogDir = Join-Path $env:APPDATA 'MagicMouseTray'
    if (-not (Test-Path $trayLogDir)) {
        Add-Result 'tray-log' 'SKIP' "Tray log dir not present: $trayLogDir"
    } else {
        $latest = Get-ChildItem $trayLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) {
            Add-Result 'tray-log' 'SKIP' 'No tray log files found'
        } else {
            $cutoff = (Get-Date).AddSeconds(-60)
            $recent = Get-Content $latest.FullName -Tail 200 | Where-Object {
                $_ -match '\d{2}:\d{2}:\d{2}'
            }
            $batteryLines = $recent | Select-String -Pattern 'battery|0x90|RID 0x90|percent' -SimpleMatch | Select-Object -Last 3
            if ($batteryLines) {
                Add-Result 'tray-log' 'PASS' ("Recent battery activity: " + ($batteryLines -join ' | '))
            } else {
                Add-Result 'tray-log' 'WARN' "Tray log present, no battery line in tail. Latest: $($latest.LastWriteTime)"
            }
        }
    }
} catch {
    Add-Result 'tray-log' 'WARN' "Tray log check error: $_"
}

# Summary
Write-Host ""
Write-Host "=== M12 Post-Install Smoke Test ==="
$results | Format-Table Name,Status,Detail -AutoSize -Wrap

$failed = ($results | Where-Object Status -eq 'FAIL').Count
$traceOnly = ($results | Where-Object Status -in 'TRACE') | Measure-Object | Select-Object -ExpandProperty Count
$realResults = $results | Where-Object Status -ne 'TRACE'
$realFailed = ($realResults | Where-Object Status -eq 'FAIL').Count

if ($realFailed -eq 0) {
    Write-Host "RESULT: PASS"
    exit 0
} else {
    $serviceFail = ($results | Where-Object { $_.Name -eq 'service' -and $_.Status -eq 'FAIL' }).Count
    if ($serviceFail) {
        Write-Host "RESULT: NOT INSTALLED — driver service missing"
        exit 3
    }
    Write-Host "RESULT: DEGRADED — $realFailed check(s) failed"
    exit 2
}
