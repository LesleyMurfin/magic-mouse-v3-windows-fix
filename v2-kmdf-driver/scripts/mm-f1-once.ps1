$ErrorActionPreference = 'Continue'
$cs = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MmF1 {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetFeature(SafeFileHandle h, byte[] buf, int len);
    [DllImport("hid.dll")]
    public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);
    [DllImport("hid.dll")]
    public static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")]
    public static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);
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
if (-not ([System.Management.Automation.PSTypeName]'MmF1').Type) {
    Add-Type -TypeDefinition $cs -Language CSharp
}
$HID_GUID = [Guid]'4d1e55b2-f16f-11cf-88cb-001111000030'
$devs = [MmF1]::SetupDiGetClassDevs([ref]$HID_GUID, $null, [IntPtr]::Zero, 0x12)
$col01 = $null
$index = 0
while ($true) {
    $iface = New-Object MmF1+SP_DEVICE_INTERFACE_DATA
    $iface.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($iface)
    if (-not [MmF1]::SetupDiEnumDeviceInterfaces($devs, [IntPtr]::Zero, [ref]$HID_GUID, $index, [ref]$iface)) { break }
    $detail = New-Object MmF1+SP_DEVICE_INTERFACE_DETAIL_DATA
    $detail.cbSize = if ([IntPtr]::Size -eq 8) { 8 } else { 6 }
    $req = 0
    [MmF1]::SetupDiGetDeviceInterfaceDetail($devs, [ref]$iface, [ref]$detail, 512, [ref]$req, [IntPtr]::Zero) | Out-Null
    if ($detail.DevicePath) {
        $dp = $detail.DevicePath.ToLower()
        if (($dp -match 'vid_05ac.*pid_0323' -or $dp -match 'vid&0001004c.*pid&0323') -and $dp -match 'col01') {
            $col01 = $detail.DevicePath
        }
    }
    $index++
}
[MmF1]::SetupDiDestroyDeviceInfoList($devs) | Out-Null
Write-Output "col01=$col01"
if (-not $col01) { Write-Output 'NO_COL01'; exit 2 }

function Try-F1([uint32]$access) {
    Write-Output ("open_access=0x{0:X}" -f $access)
    $h = [MmF1]::CreateFile($col01, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        Write-Output ("CreateFile err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        return
    }
    try {
        $prep = [IntPtr]::Zero
        $featLen = 3
        if ([MmF1]::HidD_GetPreparsedData($h, [ref]$prep)) {
            $caps = New-Object MmF1+HIDP_CAPS
            [void][MmF1]::HidP_GetCaps($prep, [ref]$caps)
            Write-Output ("FeatureReportByteLength=" + $caps.FeatureReportByteLength)
            if ($caps.FeatureReportByteLength -gt 0) { $featLen = [int]$caps.FeatureReportByteLength }
            [void][MmF1]::HidD_FreePreparsedData($prep)
        }
        $buf = New-Object byte[] $featLen
        $buf[0] = 0xF1
        if ($featLen -gt 1) { $buf[1] = 0x02 }
        if ($featLen -gt 2) { $buf[2] = 0x01 }
        $ok = [MmF1]::HidD_SetFeature($h, $buf, $buf.Length)
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Output ("SetFeature ok=$ok err=$err len=$featLen")
    } finally {
        $h.Dispose()
    }
}
Try-F1 0
Try-F1 0xC0000000
exit 0
