# Morning finish — sign, install, test

**Driver compiles successfully.** `MagicKbDesc.sys` (10,752 bytes) and `MagicKbDesc.cat` are staged at `C:\Windows\Temp\MagicKbDescStage\`. Three steps remain — all need your explicit approval (kernel driver loading is too high-severity for unattended automation).

## Status from session 2026-05-08

| Step | Status | Where |
|------|--------|-------|
| Source compiled | ✅ | `\\wsl.localhost\Ubuntu\home\lesley\.claude\worktrees\ai-m4-kbd-build-and-test\driver-keyboard\x64\Release\MagicKbDesc.sys` |
| stampinf + Inf2Cat | ✅ | `C:\Windows\Temp\MagicKbDescStage\` (.sys + .cat + .inf) |
| Sign .sys + .cat via M12 cert | ⏸ ready to run |
| `pnputil /add-driver /install /force` | ⏸ ready to run |
| Toggle BT + verify filter in stack | ⏸ ready to run |
| Run `Test-HidD-GetFeature-RID47.ps1` | ⏸ ready to run |

## Run it (all PowerShell as Administrator)

Three steps. Each is a small inline block — copy/paste into your shell.

### Step 1 — Sign the .sys and .cat

Uses the M12 `CN=MagicMouseFix` cert in `LocalMachine\My` (thumbprint `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`). Driven via the existing `MM-Dev-Cycle` scheduled task's `SIGN-FILE` route, which runs as SYSTEM and has private-key access.

```powershell
$thumb    = '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
$queueDir = 'C:\mm-dev-queue'
$stage    = 'C:\Windows\Temp\MagicKbDescStage'

function Sign-One($file) {
    $nonce = 'sign-' + [guid]::NewGuid().ToString().Substring(0,8)
    $req   = "SIGN-FILE|$nonce|$file|$thumb"
    Set-Content "$queueDir\request.txt" $req -Encoding ASCII
    Remove-Item "$queueDir\result.txt" -Force -ErrorAction SilentlyContinue
    schtasks /run /tn MM-Dev-Cycle | Out-Null
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "$queueDir\result.txt") {
            $r = (Get-Content "$queueDir\result.txt" -Raw).Trim()
            if ($r -match "\|$nonce") {
                Write-Host "  $file -> $r"
                return [int]($r -split '\|')[0]
            }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "  TIMEOUT signing $file" -ForegroundColor Red
    return 124
}

Sign-One "$stage\MagicKbDesc.sys"
Sign-One "$stage\MagicKbDesc.cat"

& 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe' verify /pa "$stage\MagicKbDesc.sys"
```

### Step 2 — Install via pnputil

Self-elevates if needed (UAC prompt).

```powershell
$inf = 'C:\Windows\Temp\MagicKbDescStage\MagicKbDesc.inf'
pnputil /add-driver $inf /install /force
```

Verify the new filter binds. Toggle BT off then on in Settings first (Win+I → Bluetooth → toggle radio), wait ~5 seconds for the keyboard to reconnect, then:

```powershell
$kb = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000'
Get-PnpDeviceProperty -InstanceId $kb -KeyName 'DEVPKEY_Device_Stack' | Select-Object -ExpandProperty Data
# Expect: \Driver\HidBth, \Driver\MagicKbDesc, \Driver\BthEnum
# (The MagicKeyboard.sys filter from earlier MagicUtilities install may also be there.
#  That's OK — both filters can coexist; ours hooks the descriptor IRP.)
```

### Step 3 — Test the patch worked

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Hid {
    public const uint GENERIC_READ  = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_RW = 0x00000003;
    public const uint OPEN_EXISTING = 3;
    public static readonly IntPtr INVALID = new IntPtr(-1);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetFeature(IntPtr h, byte[] buf, uint len);
}
'@

$col02 = Get-PnpDevice -Class HIDClass | Where-Object { $_.InstanceId -match 'PID&0239&Col02' -and $_.InstanceId -match '00001124' } | Select-Object -First 1
$key   = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{4d1e55b2-f16f-11cf-88cb-001111000030}"
$path  = (Get-ChildItem $key | Where-Object { $_.PSChildName -match ($col02.InstanceId -replace '\\','#') } | Select-Object -First 1).PSChildName -replace '^##\?#','\\?\' -replace '#\{','#{'

$h = [Hid]::CreateFileW($path, [Hid]::GENERIC_READ -bor [Hid]::GENERIC_WRITE,
    [Hid]::FILE_SHARE_RW, [IntPtr]::Zero, [Hid]::OPEN_EXISTING, 0, [IntPtr]::Zero)
if ($h -eq [Hid]::INVALID) { throw "CreateFile failed err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

$buf = New-Object byte[] 2
$buf[0] = 0x47
$ok = [Hid]::HidD_GetFeature($h, $buf, 2)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
[Hid]::CloseHandle($h) | Out-Null

if ($ok) {
    Write-Host "*** SUCCESS *** [{0:X2} {1:X2}]   BATTERY = $($buf[1])%" -ForegroundColor Green
} else {
    Write-Host "FAILED ok=$ok err=$err" -ForegroundColor Yellow
    if ($err -eq 1) { Write-Host "  err=1 means the descriptor patch didn't apply — re-toggle BT and retry" }
}
```

Expected: `*** SUCCESS *** [47 NN]   BATTERY = NN%` where NN is your keyboard battery percent.

Expected output of step 3:

```
[Col02 / RID 0x47 (Battery Strength) / patched Feature]
  HidD_GetFeature(rid=0x47, len=2)...
  *** SUCCESS *** bytes: [47 NN]   ← NN is battery percent
```

If step 3 still returns `err=1`, the BT toggle didn't re-enumerate the device. Manual fix:
```powershell
pnputil /restart-device "BTHENUM\Dev_E806884B0741"
```
Then re-run step 3.

## Recovery (if anything goes sideways)

Uninstall the driver:
```powershell
pnputil /enum-drivers | findstr /I MagicKbDesc
pnputil /delete-driver oem##.inf /uninstall /force   # use the OEM number from above
```
Then toggle BT off/on. Keyboard returns to default driver state.

## What we proved

Empirical pre-flight (`Test-HidD-GetFeature-0x09.ps1` 2026-05-08):
- `HidD_GetFeature(Col03, RID=0x09, 4)` → SUCCESS, returned `[92 12 02 02]`
- `HidD_GetFeature(Col02, RID=0x47, 2)` → FAIL err=1 ERROR_INVALID_FUNCTION

This proves the only blocker is descriptor validation. After the 4-byte patch this driver inserts (`09 20 B1 02` before Col02's closing `c0 c0`), `hidclass.sys` will parse RID `0x47` as both Input and Feature — same outcome as the working RID `0x09` test.

See `docs/M4-MAC-CAPTURE-FINDINGS-2026-05-08.md` (Empirical update section) for the full architectural rationale.
