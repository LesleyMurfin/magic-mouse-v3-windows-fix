# v1.0.0 — Binary Patch Installer

**SHIP-BLOCKER for PID 0323.** The package file is **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`**. It has caused BSOD 0xD1 (`DRIVER_IRQL_NOT_LESS_OR_EQUAL`). It is **not** the 0323 product. Never name it `MagicMouseDriver.sys`. Windows would still copy it to `applewirelessmouse.sys` if someone ran this historical installer.

Use **`../v2-kmdf-driver/Install-KMDF.cmd`** (KMDF artifact `MagicMouseDriver-kmdf-2.0.4-scroll.sys`, INF dest `MagicMouseDriver.sys`, sole LowerFilters, 0323 only). Do not dual-filter this binary with MagicMouseDriver.

---

**STATUS: Historical only — do not ship**

This directory contains the PATH-A binary patch approach: a pre-built, patched kernel driver packaged as `applewirelessmouse-patched-pathA-SHIPBLOCKER.sys` and PowerShell installer/uninstaller. The Windows service name remains `applewirelessmouse.sys`.

## Quick Start

### 1. Verify Your Hardware

Open Device Manager and locate your Magic Mouse:

1. **Windows Key + X** → Device Manager
2. Expand **Human Interface Devices**
3. Find **Apple Magic Mouse**
4. Right-click → **Properties**
5. Go to **Details** tab
6. In the dropdown, select **Hardware Ids**
7. You should see something like:
   ```
   BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004C_PID&0323\6&11223344_0
   ```
   **Look for `PID&0323`** — if you don't see this, you don't have Magic Mouse v3 (2024), and this patch won't help.

### 2. Download & Verify

1. Extract this repository to your preferred location (e.g., `C:\Program Files\MagicMousePatch\`)

2. **Verify the driver binary integrity:**
   ```powershell
   # Open PowerShell (Windows Key + X → PowerShell)
   # Navigate to this directory
   cd "C:\Program Files\MagicMousePatch\v1-binary-patch"
   
   # Check the SHA256 hash
   (Get-FileHash "applewirelessmouse-patched-pathA-SHIPBLOCKER.sys" -Algorithm SHA256).Hash
   ```
   
   **Expected output:**
   ```
   370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03
   ```
   
   **If the hash does not match, stop. Do not install.** Your download may be corrupted.

3. **Verify certificate thumbprint** (optional but recommended):
   ```powershell
   $cert = Get-AuthenticodeSignature "applewirelessmouse-patched-pathA-SHIPBLOCKER.sys"
   $cert.SignerCertificate.Thumbprint
   ```
   
   **Expected output:**
   ```
   16940C0F937D569363560D5FEC5CD8FA6D6D9BCE
   ```

### 3. Run Installer

1. **Open PowerShell as Administrator:**
   - Windows Key + X
   - Select **Windows PowerShell (Admin)** or **Windows Terminal (Admin)**
   - If prompted by User Account Control, click **Yes**

2. **Navigate to installer directory:**
   ```powershell
   cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
   ```

3. **Run the installer:**
   ```powershell
   .\Install-MagicMousePatch.ps1
   ```

4. **Wait for prompts:**
   - **Certificate Trust Prompt:** Click **Yes** when Windows Security asks "Do you want to install this device software?"
   - **Administrator Confirmation:** Click **Yes** if prompted
   - **Reboot Instruction:** The script will tell you when to reboot

### 4. Reboot

When the installer finishes, reboot your computer:

```powershell
shutdown /r /t 60 /c "Magic Mouse Patch installing - system will reboot in 60 seconds"
```

Or manually:
- Windows Key + Power button
- Click **Restart**

**Important:** Do NOT skip the reboot. The driver will not load until after a reboot.

## Verify Installation

After rebooting, verify the patch installed correctly:

### Check 1: Service Status

```powershell
# Open PowerShell (no admin required for this check)
sc query applewirelessmouse
```

Expected output:
```
SERVICE_NAME: applewirelessmouse
        TYPE               : 1  KERNEL_DRIVER
        STATE              : 4  RUNNING
        WIN32_EXIT_CODE    : 0  (0x0)
        SERVICE_EXIT_CODE  : 0  (0x0)
        CHECKPOINT         : 0x0
        WAIT_HINT          : 0x0
```

If STATE shows `4 RUNNING`, the driver is loaded — good!

### Check 2: Device Manager

1. Windows Key + X → Device Manager
2. Expand **Human Interface Devices**
3. Find **Apple Magic Mouse**
4. Should show no warning icons (yellow triangle = problem)

### Check 3: Scroll Test

1. Open any application with scrollable content (web browser, text editor, etc.)
2. Position your cursor over the scrollable area
3. Scroll using the Magic Mouse wheel — should respond smoothly
4. Try scrolling in both directions

### Check 4: Event Log (Optional)

To see if the driver loaded correctly:

```powershell
# View recent kernel PnP events
Get-WinEvent -LogName "Microsoft-Windows-Kernel-PnP/Configuration" -MaxEvents 20 | Format-List TimeCreated, Message | head -20
```

Look for entries mentioning "applewirelessmouse" or the device ID.

## Uninstall

If you need to remove the patch:

1. **Open PowerShell as Administrator**

2. **Navigate to installer directory:**
   ```powershell
   cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
   ```

3. **Run uninstaller:**
   ```powershell
   .\Uninstall-MagicMousePatch.ps1
   ```

4. **Reboot when prompted**

The uninstaller will:
- Remove the applewirelessmouse service
- Delete the patched driver from System32\drivers\
- Restore the original driver from backup (if it exists)
- Remove the MagicMouseFix certificate from certificate stores
- Remove registry entries
- Clean up C:\ProgramData\MagicMousePatch\

After reboot, your system will be back to its original state before the patch was installed.

## Troubleshooting

### Issue: Certificate Trust Prompt Never Appears

**Cause:** Your system may have a policy preventing certificate installation.

**Fix:**
```powershell
# Try installing certificate manually
$cert = Get-AuthenticodeSignature "applewirelessmouse-patched-pathA-SHIPBLOCKER.sys"
# If this shows no signer, the binary is corrupted

# Try importing certificate directly
$cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("MagicMouseFix.cer")
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$store.Add($cer)
$store.Close()
```

Then run the installer again.

### Issue: "Access Denied" When Running Installer

**Cause:** PowerShell execution policy blocks scripts.

**Fix:**
```powershell
# Check current policy
Get-ExecutionPolicy

# Temporarily allow script execution for this session
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

# Then run installer
.\Install-MagicMousePatch.ps1
```

### Issue: Scroll Still Doesn't Work After Installation

**Symptoms:**
- Installer completed successfully
- Service is running (`sc query applewirelessmouse` shows STATE: 4)
- Device Manager shows no warnings
- But scroll still doesn't work

**Diagnostic steps:**
1. Turn off Magic Mouse, wait 30 seconds, turn back on
2. Wait 10 seconds for reconnection
3. Try scroll again
4. If still broken, collect event logs:
   ```powershell
   wevtutil epl "Microsoft-Windows-Kernel-PnP/Configuration" C:\pnp-config.evtx
   wevtutil epl "Microsoft-Windows-DeviceSetupManager/Admin" C:\dsm-admin.evtx
   ```
   And open a GitHub issue with these logs attached.

### Issue: System Crashes or Instability After Installation

**This should not happen.** If it does:

1. Boot into Safe Mode (Shift + Restart during boot)
2. Open PowerShell as Administrator
3. Run uninstaller:
   ```powershell
   cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
   .\Uninstall-MagicMousePatch.ps1
   ```
4. Reboot normally
5. Open a GitHub issue with:
   - Exact error or crash message
   - Windows version and build (winver)
   - System event log (wevtutil epl "System" C:\system.evtx)

## File Manifest

```
v1-binary-patch/
├── README.md (this file)
├── applewirelessmouse-patched-pathA-SHIPBLOCKER.sys (PATH-A package, 66 KB; never MagicMouseDriver.sys)
├── MagicMouseFix.cer (code-signing certificate)
├── installer/
│   ├── Install-MagicMousePatch.ps1 (main installer)
│   ├── Uninstall-MagicMousePatch.ps1 (uninstaller)
│   └── applewirelessmouse-patched-pathA-SHIPBLOCKER.sys (optional copy; Windows dest remains applewirelessmouse.sys)
├── docs/
│   ├── bug-analysis.md (detailed problem explanation)
│   └── architecture.md (how the filter driver works)
```

## For v2 Users (Future)

v1.0.0 (this PATH-A binary) is **not** the 0323 product. The 0323 product is KMDF `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (FileVersion 2.0.4.0; INF dest `MagicMouseDriver.sys`).

See `/v2-kmdf-driver/README.md` for v2 status and roadmap.

## Support

- **Questions:** riley@revivebusiness.ca
- **Bug reports:** GitHub Issues (include event logs)
- **Security issues:** See SECURITY.md
