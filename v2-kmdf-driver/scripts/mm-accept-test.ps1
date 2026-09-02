<#
.SYNOPSIS
    Magic Mouse 2024 acceptance test - 7 acceptance criteria, pass/fail verdict.

.DESCRIPTION
    Performs read-only checks against the installed driver state and emits:
      - A results table to stdout
      - A JSON file to %LOCALAPPDATA%\mm-accept-test-<ISO>.json

    Run from WSL via mm-accept-test.sh, or directly in an admin PowerShell:
        .\mm-accept-test.ps1

    Checks performed:
      AC-01  LowerFilters contains MagicMouseDriver (NOT applewirelessmouse)
      AC-02  COL01 enumerated and Status=Started
      AC-03  COL02 enumerated and Status=Started
      AC-04  COL01 declares Wheel (UP=0x0001 U=0x0038) or AC Pan (UP=0x000C U=0x0238)
      AC-05  COL02 has vendor battery TLC (UsagePage=0xFF00 Usage=0x0014 InputLen>=3)
      AC-06  Battery readable: HidD_GetInputReport(0x90) on COL02 returns buf[2]=0..100
      AC-07  Kernel debug log (C:\mm3-debug.log) has 'MagicMouse: Descriptor injected'
             within last 60 seconds
      AC-08  Tray app debug log has pct=<0..100> (not pct=-1 or pct=-2) on last line

    Does NOT install/uninstall/modify anything.

.OUTPUTS
    Exit codes: 0=all pass, 1=at least one fail, 2=usage error
#>

param(
    [string]$VendorPid  = 'VID&0001004c_PID&0323',
    [string]$DebugLog   = 'C:\mm3-debug.log',
    [int]$DebugLogMaxAgeSecs = 60
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# P/Invoke shim - HID + SetupAPI (copied from mm-hid-probe.ps1)
# ---------------------------------------------------------------------------
$cs = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class MmHid {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] buf, int len);
    [DllImport("hid.dll")]
    public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);
    [DllImport("hid.dll")]
    public static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")]
    public static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);
    [DllImport("hid.dll")]
    public static extern int HidP_GetValueCaps(int reportType, [Out] HIDP_VALUE_CAPS[] caps,
        ref ushort capsLength, IntPtr preparsedData);

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength,
            FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps,
            NumberInputDataIndices, NumberOutputButtonCaps, NumberOutputValueCaps,
            NumberOutputDataIndices, NumberFeatureButtonCaps, NumberFeatureValueCaps,
            NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential, Pack=4)]
    public struct HIDP_VALUE_CAPS {
        public ushort UsagePage;
        public byte ReportID;
        [MarshalAs(UnmanagedType.U1)] public bool IsAlias;
        public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;
        [MarshalAs(UnmanagedType.U1)] public bool IsRange, IsStringRange, IsDesignatorRange, IsAbsolute;
        [MarshalAs(UnmanagedType.U1)] public bool HasNull;
        public byte Reserved;
        public ushort BitSize, ReportCount;
        public ushort R1, R2, R3, R4, R5;
        public uint UnitsExp, Units;
        public int LogicalMin, LogicalMax, PhysicalMin, PhysicalMax;
        // Range/NotRange union - first slot is UsageMin/Usage
        public ushort UsageOrUsageMin, UsageMax, StringIdxOrMin, StringIdxMax;
        public ushort DesigIdxOrMin, DesigIdxMax, DataIdxOrMin, DataIdxMax;
    }
}

public static class MmSetup {
    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern IntPtr SetupDiGetClassDevs(ref Guid g, string e, IntPtr p, uint f);
    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g,
        uint i, ref SP_DEVICE_INTERFACE_DATA r);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s,
        ref SP_DEVICE_INTERFACE_DATA d, ref SP_DEVICE_INTERFACE_DETAIL_DATA b,
        uint sz, out uint req, IntPtr di);
    [DllImport("setupapi.dll")]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA {
        public uint cbSize; public Guid InterfaceClassGuid; public uint Flags; public IntPtr R;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct SP_DEVICE_INTERFACE_DETAIL_DATA {
        public uint cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=512)]
        public string DevicePath;
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'MmHid').Type) {
    Add-Type -TypeDefinition $cs -Language CSharp
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$HIDP_STATUS_SUCCESS = 0x00110000
$HID_GUID            = [Guid]'4d1e55b2-f16f-11cf-88cb-001111000030'

# ---------------------------------------------------------------------------
# Result accumulator
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[hashtable]]::new()

function Add-Result {
    param(
        [string]$Id,
        [string]$Name,
        [bool]  $Pass,
        [string]$Detail
    )
    $results.Add(@{
        id     = $Id
        name   = $Name
        status = if ($Pass) { 'PASS' } else { 'FAIL' }
        detail = $Detail
    })
}

# ---------------------------------------------------------------------------
# Helper: Resolve BTHENUM device ID for our mouse (by VID/PID)
# ---------------------------------------------------------------------------
function Resolve-MouseDeviceId {
    # Must return the HID-service GUID path ({00001124-...}) -- that is the
    # node where LowerFilters binds.  The SDP/Device-Identification entry
    # ({00001200-...}) is also present but has no LowerFilters; returning it
    # causes AC-01 to always report a false FAIL.
    $devs = pnputil /enum-devices /connected 2>&1 | Out-String
    $blocks = $devs -split "(?=Instance ID:)"
    foreach ($b in $blocks) {
        if ($b -match "Instance ID:\s+(BTHENUM\\\{00001124-0000-1000-8000-00805[Ff]9[Bb]34[Ff][Bb][^\r\n]*$VendorPid[^\r\n]*)") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: enumerate HID interface paths for the mouse (COL01 and COL02)
# Filters by VID/PID in the device path.
# ---------------------------------------------------------------------------
function Get-MouseHidPaths {
    $devs = [MmSetup]::SetupDiGetClassDevs([ref]$HID_GUID, $null, [IntPtr]::Zero, 0x12)
    $paths = @{}
    $index = 0
    while ($true) {
        $iface = New-Object MmSetup+SP_DEVICE_INTERFACE_DATA
        $iface.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($iface)
        if (-not [MmSetup]::SetupDiEnumDeviceInterfaces($devs, [IntPtr]::Zero, [ref]$HID_GUID, $index, [ref]$iface)) {
            break
        }
        $detail = New-Object MmSetup+SP_DEVICE_INTERFACE_DETAIL_DATA
        $detail.cbSize = if ([IntPtr]::Size -eq 8) { 8 } else { 6 }
        [MmSetup]::SetupDiGetDeviceInterfaceDetail($devs, [ref]$iface, [ref]$detail, 512, [ref]$null, [IntPtr]::Zero) | Out-Null
        if ($detail.DevicePath) {
            $dp = $detail.DevicePath.ToLower()
            $isOurMouse = ($dp -match 'vid_05ac.*pid_0323' -or $dp -match 'vid&0001004c.*pid&0323')
            if ($isOurMouse) {
                if ($dp -match 'col01') {
                    $paths['col01'] = $detail.DevicePath
                } elseif ($dp -match 'col02') {
                    $paths['col02'] = $detail.DevicePath
                } else {
                    # Unified single interface (Apple driver mode)
                    if (-not $paths.ContainsKey('unified')) {
                        $paths['unified'] = $detail.DevicePath
                    }
                }
            }
        }
        $index++
    }
    [MmSetup]::SetupDiDestroyDeviceInfoList($devs) | Out-Null
    return $paths
}

# ---------------------------------------------------------------------------
# Helper: open HID handle (zero-access, avoids err=5 on mouhid-owned interface)
# ---------------------------------------------------------------------------
function Open-HidHandle {
    param([string]$Path)
    return [MmHid]::CreateFile($Path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
}

# ---------------------------------------------------------------------------
# Helper: get HIDP_CAPS + InputValueCaps for a given handle
# Returns $null on failure.
# ---------------------------------------------------------------------------
function Get-HidCaps {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    $pd = [IntPtr]::Zero
    if (-not [MmHid]::HidD_GetPreparsedData($Handle, [ref]$pd)) { return $null }
    try {
        $caps = New-Object MmHid+HIDP_CAPS
        $caps.Reserved = [uint16[]]::new(17)
        if ([MmHid]::HidP_GetCaps($pd, [ref]$caps) -ne $HIDP_STATUS_SUCCESS) { return $null }

        $valueCaps = @()
        if ($caps.NumberInputValueCaps -gt 0) {
            $arr = [MmHid+HIDP_VALUE_CAPS[]]::new([int]$caps.NumberInputValueCaps)
            $len = [uint16]$caps.NumberInputValueCaps
            if ([MmHid]::HidP_GetValueCaps(0, $arr, [ref]$len, $pd) -eq $HIDP_STATUS_SUCCESS) {
                $valueCaps = $arr[0..([int]$len-1)]
            }
        }
        return @{ Caps = $caps; ValueCaps = $valueCaps }
    } finally {
        [MmHid]::HidD_FreePreparsedData($pd) | Out-Null
    }
}

# ===========================================================================
# AC-01: LowerFilters contains MagicMouseDriver
# ===========================================================================
$devId = Resolve-MouseDeviceId
if (-not $devId) {
    Add-Result 'AC-01' 'Driver bound (LowerFilters)' $false `
        'Device not connected/paired - no BTHENUM entry for VID&0001004c_PID&0323'
} else {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId"
    try {
        $lf = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
        if ($null -eq $lf) { $lf = @() }
        $lfStr = ($lf -join ', ')
        if ($lf -contains 'MagicMouseDriver') {
            Add-Result 'AC-01' 'Driver bound (LowerFilters)' $true `
                "LowerFilters=[$lfStr] - MagicMouseDriver present"
        } else {
            Add-Result 'AC-01' 'Driver bound (LowerFilters)' $false `
                "LowerFilters=[$lfStr] - MagicMouseDriver NOT found (applewirelessmouse mode?)"
        }
    } catch {
        Add-Result 'AC-01' 'Driver bound (LowerFilters)' $false `
            "Cannot read registry at $regPath : $_"
    }
}

# ===========================================================================
# AC-02/AC-03: COL01 + COL02 both enumerated and Started
# Uses pnputil /enum-devices - parse blocks for COL01 and COL02 status.
# ===========================================================================
$pnpOut = pnputil /enum-devices /connected 2>&1 | Out-String

function Get-ColStatus {
    param([string]$PnpOutput, [string]$ColSuffix)
    # Split on Instance ID: boundaries, find block with our VID/PID + ColXX
    $blocks = $PnpOutput -split "(?=Instance ID:)"
    foreach ($b in $blocks) {
        if ($b -match "VID&0001004c_PID&0323.*$ColSuffix" -or
            $b -match "VID_05AC.*PID_0323.*$ColSuffix") {
            if ($b -match 'Status:\s*(\w+)') {
                return $Matches[1]
            }
            return 'Unknown'
        }
    }
    return $null
}

$col01Status = Get-ColStatus $pnpOut 'Col01'
$col02Status = Get-ColStatus $pnpOut 'Col02'

if ($null -eq $col01Status) {
    Add-Result 'AC-02' 'COL01 enumerated+Started' $false `
        'COL01 not found in pnputil /enum-devices /connected'
} else {
    $pass = ($col01Status -eq 'Started')
    Add-Result 'AC-02' 'COL01 enumerated+Started' $pass `
        "COL01 Status=$col01Status$(if (-not $pass) { ' (expected: Started)' })"
}

if ($null -eq $col02Status) {
    Add-Result 'AC-03' 'COL02 enumerated+Started' $false `
        'COL02 not found - battery child PDO missing (descriptor injection may have failed)'
} else {
    $pass = ($col02Status -eq 'Started')
    Add-Result 'AC-03' 'COL02 enumerated+Started' $pass `
        "COL02 Status=$col02Status$(if (-not $pass) { ' (expected: Started)' })"
}

# ===========================================================================
# HID path enumeration (shared for AC-04/AC-05/AC-06)
# ===========================================================================
$hidPaths = Get-MouseHidPaths

# ---------------------------------------------------------------------------
# AC-04: COL01 declares Wheel or AC Pan usage via HidP_GetValueCaps
# ---------------------------------------------------------------------------
$col01Path = $hidPaths['col01']
if (-not $col01Path) {
    Add-Result 'AC-04' 'COL01 scroll usage declared' $false `
        'COL01 HID interface path not found (device not enumerated or not in split mode)'
} else {
    $h = Open-HidHandle $col01Path
    if ($h.IsInvalid) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Add-Result 'AC-04' 'COL01 scroll usage declared' $false `
            "CreateFile on COL01 failed err=$err path=$col01Path"
    } else {
        try {
            $info = Get-HidCaps $h
            if ($null -eq $info) {
                Add-Result 'AC-04' 'COL01 scroll usage declared' $false `
                    "HidP_GetCaps failed on COL01"
            } else {
                # Wheel: UP=0x0001 U=0x0038  |  AC Pan: UP=0x000C U=0x0238
                $hasWheel  = $info.ValueCaps | Where-Object { $_.UsagePage -eq 0x0001 -and $_.UsageOrUsageMin -eq 0x0038 }
                $hasACPan  = $info.ValueCaps | Where-Object { $_.UsagePage -eq 0x000C -and $_.UsageOrUsageMin -eq 0x0238 }
                $found     = @()
                if ($hasWheel) { $found += 'Wheel(UP=0001,U=0038)' }
                if ($hasACPan) { $found += 'ACPan(UP=000C,U=0238)' }
                $pass = ($found.Count -gt 0)
                if ($pass) {
                    Add-Result 'AC-04' 'COL01 scroll usage declared' $true `
                        "Scroll usages found: $($found -join ', ')"
                } else {
                    $allUsages = ($info.ValueCaps | ForEach-Object { "UP=0x$('{0:X4}' -f $_.UsagePage),U=0x$('{0:X4}' -f $_.UsageOrUsageMin)" }) -join '; '
                    Add-Result 'AC-04' 'COL01 scroll usage declared' $false `
                        "No Wheel/ACPan in COL01 ValueCaps. Found: [$allUsages]"
                }
            }
        } finally {
            $h.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# AC-05: COL02 has vendor battery TLC (UP=0xFF00 U=0x0014 InputLen>=3)
# ---------------------------------------------------------------------------
$col02Path = $hidPaths['col02']
if (-not $col02Path) {
    Add-Result 'AC-05' 'COL02 vendor battery TLC' $false `
        'COL02 HID interface path not found'
} else {
    $h = Open-HidHandle $col02Path
    if ($h.IsInvalid) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Add-Result 'AC-05' 'COL02 vendor battery TLC' $false `
            "CreateFile on COL02 failed err=$err"
    } else {
        try {
            $info = Get-HidCaps $h
            if ($null -eq $info) {
                Add-Result 'AC-05' 'COL02 vendor battery TLC' $false `
                    "HidP_GetCaps failed on COL02"
            } else {
                $caps = $info.Caps
                $upOk  = ($caps.UsagePage -eq 0xFF00)
                $uOk   = ($caps.Usage -eq 0x0014)
                $lenOk = ($caps.InputReportByteLength -ge 3)
                $pass  = $upOk -and $uOk -and $lenOk
                $detail = "UP=0x$('{0:X4}' -f $caps.UsagePage) Usage=0x$('{0:X4}' -f $caps.Usage) InputLen=$($caps.InputReportByteLength)"
                if ($pass) {
                    Add-Result 'AC-05' 'COL02 vendor battery TLC' $true `
                        "Battery TLC confirmed: $detail"
                } else {
                    $why = @()
                    if (-not $upOk)  { $why += "UsagePage=0x$('{0:X4}' -f $caps.UsagePage) (expected 0xFF00)" }
                    if (-not $uOk)   { $why += "Usage=0x$('{0:X4}' -f $caps.Usage) (expected 0x0014)" }
                    if (-not $lenOk) { $why += "InputReportByteLength=$($caps.InputReportByteLength) < 3" }
                    Add-Result 'AC-05' 'COL02 vendor battery TLC' $false `
                        "$($why -join '; ')  [raw: $detail]"
                }
            }
        } finally {
            $h.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# AC-06: Battery readable - HidD_GetInputReport(0x90) on COL02
# ---------------------------------------------------------------------------
if (-not $col02Path) {
    Add-Result 'AC-06' 'Battery read (Report 0x90)' $false `
        'COL02 path not available - skipping read'
} else {
    $h = Open-HidHandle $col02Path
    if ($h.IsInvalid) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Add-Result 'AC-06' 'Battery read (Report 0x90)' $false `
            "CreateFile on COL02 failed err=$err"
    } else {
        try {
            $buf = New-Object byte[] 3
            $buf[0] = 0x90
            $success = $false
            $lastErr = 0
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                $buf[0] = 0x90
                if ([MmHid]::HidD_GetInputReport($h, $buf, $buf.Length)) {
                    $success = $true
                    break
                }
                $lastErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 50 }
            }
            if ($success) {
                $pct = [int]$buf[2]
                if ($pct -ge 0 -and $pct -le 100) {
                    Add-Result 'AC-06' 'Battery read (Report 0x90)' $true `
                        "buf=[0x$('{0:X2}' -f $buf[0]) 0x$('{0:X2}' -f $buf[1]) 0x$('{0:X2}' -f $buf[2])] battery=$pct%"
                } else {
                    Add-Result 'AC-06' 'Battery read (Report 0x90)' $false `
                        "Report returned but buf[2]=$pct is out of range 0-100"
                }
            } else {
                Add-Result 'AC-06' 'Battery read (Report 0x90)' $false `
                    "HidD_GetInputReport failed after 3 attempts, err=$lastErr"
            }
        } finally {
            $h.Close()
        }
    }
}

# ===========================================================================
# AC-07: Kernel debug log has 'MagicMouse: Descriptor injected' within 60s
# ===========================================================================
if (-not (Test-Path $DebugLog)) {
    Add-Result 'AC-07' 'Kernel debug marker (Descriptor injected)' $false `
        "Debug log not found: $DebugLog (DebugView not running, or path wrong)"
} else {
    $cutoff   = (Get-Date).AddSeconds(-$DebugLogMaxAgeSecs)
    $logMtime = (Get-Item $DebugLog).LastWriteTime
    # Read file - look for any line with 'Descriptor injected' pattern
    $matchLine = Get-Content $DebugLog -ErrorAction SilentlyContinue |
        Select-String -Pattern 'MagicMouse.*Descriptor injected|Descriptor injected.*MagicMouse' |
        Select-Object -Last 1

    if (-not $matchLine) {
        Add-Result 'AC-07' 'Kernel debug marker (Descriptor injected)' $false `
            "No 'MagicMouse: Descriptor injected' line found in $DebugLog"
    } else {
        # Try to parse timestamp from DebugView line format: "   N  HH:MM:SS.mmm  message"
        $line = $matchLine.Line
        $timestampParsed = $false
        $withinWindow    = $false

        if ($line -match '\d+\s+(\d{2}:\d{2}:\d{2}\.\d+)\s+') {
            $timeStr = $Matches[1]
            try {
                $today   = (Get-Date).Date
                $entryTs = [datetime]::ParseExact("$($today.ToString('yyyy-MM-dd')) $timeStr",
                    'yyyy-MM-dd HH:mm:ss.fff', $null)
                $timestampParsed = $true
                $withinWindow    = ($entryTs -ge $cutoff)
            } catch { }
        }

        if ($timestampParsed) {
            if ($withinWindow) {
                Add-Result 'AC-07' 'Kernel debug marker (Descriptor injected)' $true `
                    "Found recent log entry: $line"
            } else {
                Add-Result 'AC-07' 'Kernel debug marker (Descriptor injected)' $false `
                    "Entry found but older than ${DebugLogMaxAgeSecs}s: $line"
            }
        } else {
            # Cannot parse timestamp - accept if log file itself was modified recently
            if ($logMtime -ge $cutoff) {
                Add-Result 'AC-07' 'Kernel debug marker (Descriptor injected)' $true `
                    "Found entry (timestamp parse skipped, log modified $(($logMtime).ToString('HH:mm:ss'))): $line"
            } else {
                Add-Result 'AC-07' 'Kernel debug marker (Descriptor injected)' $false `
                    "Entry found but log not updated in ${DebugLogMaxAgeSecs}s. Last modified: $($logMtime.ToString('HH:mm:ss')). Line: $line"
            }
        }
    }
}

# ===========================================================================
# AC-08: Tray app debug log has pct=<0..100>
# ===========================================================================
$trayLog = Join-Path $env:APPDATA 'MagicMouseTray\debug.log'
if (-not (Test-Path $trayLog)) {
    Add-Result 'AC-08' 'Tray app battery reading' $false `
        "Tray debug log not found: $trayLog (tray app not running or never started)"
} else {
    # Get last non-empty line from tray log
    $lastLine = Get-Content $trayLog -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() -ne '' } |
        Select-Object -Last 1

    if (-not $lastLine) {
        Add-Result 'AC-08' 'Tray app battery reading' $false `
            "Tray log is empty: $trayLog"
    } elseif ($lastLine -match 'pct=(-?\d+)') {
        $pctVal = [int]$Matches[1]
        if ($pctVal -ge 0 -and $pctVal -le 100) {
            Add-Result 'AC-08' 'Tray app battery reading' $true `
                "Last tray log line: $lastLine"
        } elseif ($pctVal -eq -1) {
            Add-Result 'AC-08' 'Tray app battery reading' $false `
                "pct=-1 (no mouse found/not connected). Last line: $lastLine"
        } elseif ($pctVal -eq -2) {
            Add-Result 'AC-08' 'Tray app battery reading' $false `
                "pct=-2 (Apple driver in unified mode - battery inaccessible). Last line: $lastLine"
        } else {
            Add-Result 'AC-08' 'Tray app battery reading' $false `
                "pct=$pctVal out of expected range. Last line: $lastLine"
        }
    } else {
        Add-Result 'AC-08' 'Tray app battery reading' $false `
            "No pct=N pattern in last tray log line: $lastLine"
    }
}

# ===========================================================================
# Emit results table
# ===========================================================================
# Force array context so .Count works under Set-StrictMode v2 even with 0 matches.
# Without @(), Where-Object returns $null when no items match, and .Count on $null
# throws under StrictMode -> downstream variables stay unset.
$passCount = @($results | Where-Object { $_.status -eq 'PASS' }).Count
$failCount = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
$total     = @($results).Count

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Magic Mouse 2024 Acceptance Test"      -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$colW = @{Id=6; Status=6; Name=36; Detail=60}

# Header
$header = "{0,-$($colW.Id)}  {1,-$($colW.Status)}  {2,-$($colW.Name)}  {3}" -f `
    'CHECK', 'STATUS', 'CRITERION', 'DETAIL'
Write-Host $header -ForegroundColor White
Write-Host ('-' * 120)

foreach ($r in $results) {
    $color = if ($r.status -eq 'PASS') { 'Green' } else { 'Red' }
    $nameClipped   = if ($r.name.Length   -gt $colW.Name)   { $r.name.Substring(0,$colW.Name-1)   + '...' } else { $r.name }
    $detailClipped = if ($r.detail.Length -gt $colW.Detail) { $r.detail.Substring(0,$colW.Detail-1) + '...' } else { $r.detail }
    $line = "{0,-$($colW.Id)}  {1,-$($colW.Status)}  {2,-$($colW.Name)}  {3}" -f `
        $r.id, $r.status, $nameClipped, $detailClipped
    Write-Host $line -ForegroundColor $color
}

Write-Host ('-' * 120)

$verdict = if ($failCount -eq 0) { 'PASS' } else { 'FAIL' }
$verdictColor = if ($failCount -eq 0) { 'Green' } else { 'Red' }
Write-Host ""
Write-Host "VERDICT: $verdict  ($passCount/$total passed)" -ForegroundColor $verdictColor
if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "To roll back and restore native behavior:" -ForegroundColor Yellow
    Write-Host "  ./scripts/mm-dev.sh rollback" -ForegroundColor Yellow
}
Write-Host ""

# ===========================================================================
# Write JSON results file
# ===========================================================================
$isoTs  = (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss')
$jsonOut = Join-Path $env:LOCALAPPDATA "mm-accept-test-${isoTs}.json"

$jsonPayload = [ordered]@{
    tool         = 'mm-accept-test'
    version      = '1.0.0'
    timestamp    = (Get-Date -Format 'o')
    device_pid   = $VendorPid
    verdict      = $verdict
    pass_count   = $passCount
    fail_count   = $failCount
    total_checks = $total
    checks       = $results | ForEach-Object {
        [ordered]@{
            id     = $_.id
            name   = $_.name
            status = $_.status
            detail = $_.detail
        }
    }
} | ConvertTo-Json -Depth 4

try {
    $jsonPayload | Out-File -FilePath $jsonOut -Encoding UTF8 -Force
    Write-Host "Results written: $jsonOut" -ForegroundColor Cyan
} catch {
    Write-Host "WARNING: could not write JSON results: $_" -ForegroundColor Yellow
}

# Exit code: 0=all pass, 1=at least one fail
exit $(if ($failCount -eq 0) { 0 } else { 1 })
