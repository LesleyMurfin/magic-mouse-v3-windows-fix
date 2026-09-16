# Apple driver route — `applewirelessmouse.sys`

**STATUS: Production Ready**

This directory covers the **Apple driver** route: install Apple's own multi-touch filter driver and
bind it to the mouse. It is one of the two drivers in this repo; the other is the from-scratch KMDF
driver in [`../v2-kmdf-driver/`](../v2-kmdf-driver/). Install one, not both — they attach to the
same Bluetooth HID stack.

## Two variants — know which one you are installing

### Recommended: Apple's unmodified driver (no signing, no Test Mode)

Apple's `applewirelessmouse.sys` from Boot Camp Support Software, used **byte-for-byte as shipped**.
Apple's INF has no entry for this mouse's Bluetooth PID (`0323`), so the driver is registered
manually instead: copy the `.sys`, create the kernel service, add `applewirelessmouse` to the
device's `LowerFilters`, restart the Bluetooth HID device.

Because nothing in the binary changes, **Apple's signature and Microsoft's WHQL countersignature
stay valid**:

- **No Test Mode.** No `bcdedit /set testsigning on`, no desktop watermark.
- **Secure Boot and memory integrity can stay ON.**
- Nothing to build, no certificate to generate or trust.

Verified with `Get-AuthenticodeSignature`: status **Valid**, signer
`CN=Microsoft Windows Hardware Compatibility Publisher`, issuer
`CN=Microsoft Windows Third Party Component CA 2012` (78,424 bytes, v6.1.7700.0).

This is the route proven on Magic Mouse v1/v2 by
[`sbagirici/apple-magic-mouse-scroll-fix-windows`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows).

### Legacy: byte-patched + re-signed variant (requires Test Mode)

Earlier work here produced a **modified** `applewirelessmouse.sys` (66,288 bytes, SHA256
`370A5555…`) re-signed with this project's own certificate `CN=MagicMouseFix`, which the installer
imports into `LocalMachine\TrustedPublisher` (deliberately **not** `Root` — `Root` would let
anything signed with that key load).

Editing the file breaks Apple's Microsoft countersignature, and a self-signed certificate outside
`Root` cannot satisfy kernel code integrity on its own. So this variant **does** require
`bcdedit /set testsigning on`, with Secure Boot and memory integrity off —
`Install-MagicMousePatch.ps1` checks and refuses to continue otherwise.

Prefer the unmodified driver above unless you specifically need this variant's behaviour.

### How to install each variant

The installer **auto-detects** which binary you gave it, from the Authenticode signature, and
applies the Test Mode / certificate requirements only where they actually apply. A binary whose
signature does not verify — a patch that was never re-signed, or a corrupted download — is
**refused**.

```powershell
# Apple's driver already on this PC (Apple Software Update / Boot Camp installed it)
.\Install-MagicMousePatch.ps1 -FromDriverStore

# Apple's driver you extracted yourself from Boot Camp Support Software
.\Install-MagicMousePatch.ps1 -DriverPath D:\bootcamp\applewirelessmouse.sys

# Whatever applewirelessmouse.sys sits beside the installer; falls back to the
# DriverStore copy if there is none
.\Install-MagicMousePatch.ps1
```

To get Apple's driver if it is not already on the machine, see **Driver Source** below (Apple
Software Update, Brigadier, or extracting `AppleWirelessMouse64.exe` from Boot Camp Support
Software).

### What you get with this driver

| | This driver | The KMDF driver |
|---|---|---|
| Pointer | works | works |
| Two-finger scroll | Apple's own multi-touch translation, Mac-style direction | generated from the touch surface, **sensitivity tunable** |
| Battery % | via **Magic Tray**, which briefly flips **Mode A ⇄ B** to read it and flips back | via **Magic Tray**, direct read of HID Input `0x90` on COL02 |
| Test Mode | **not needed** | required (self-signed) |
| Secure Boot / memory integrity | can stay **ON** | must be off |

Battery percentage comes from [Magic Tray](https://magictray.app/) in both cases — Windows itself
has no battery UI for this mouse. Magic Tray detects which driver you are on and adjusts how it
reads the level.

> The hash-verification steps below refer to whichever `.sys` you are installing. Check it against
> `installer/SHA256SUMS.txt` for the variant you have, and confirm the Authenticode signer matches
> the variant you intend: Microsoft WHQL for Apple's unmodified driver, `CN=MagicMouseFix` for the
> patched one.

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
   (Get-FileHash "applewirelessmouse.sys" -Algorithm SHA256).Hash
   ```
   
   **Expected output:**
   ```
   370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03
   ```
   
   **If the hash does not match, stop. Do not install.** Your download may be corrupted.

3. **Verify certificate thumbprint** (optional but recommended):
   ```powershell
   $cert = Get-AuthenticodeSignature "applewirelessmouse.sys"
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
$cert = Get-AuthenticodeSignature "applewirelessmouse.sys"
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
├── applewirelessmouse.sys (patched driver binary, 66 KB)
├── MagicMouseFix.cer (code-signing certificate)
├── installer/
│   ├── Install-MagicMousePatch.ps1 (main installer)
│   ├── Uninstall-MagicMousePatch.ps1 (uninstaller)
│   └── applewirelessmouse.sys (copy for installer reference)
├── docs/
│   ├── bug-analysis.md (detailed problem explanation)
│   └── architecture.md (how the filter driver works)
```

## For v2 Users (Future)

v2.0.0 will be a from-scratch KMDF driver rewrite. Until then, v1.0.0 (this binary patch) is the current production release.

See `/v2-kmdf-driver/README.md` for v2 status and roadmap.

## Support

- **Questions:** riley@revivebusiness.ca
- **Bug reports:** GitHub Issues (include event logs)
- **Security issues:** See SECURITY.md
