# Security Policy

## Vulnerability Disclosure

If you discover a security vulnerability in this driver patch, please report it to:

**Email:** riley@revivebusiness.ca

**Do not open a public GitHub issue** for security vulnerabilities. Public disclosure before a patch is available puts all users at risk.

## Disclosure Process

1. **Report:** Send a detailed description of the vulnerability to riley@revivebusiness.ca
   - Include affected versions (v1.0.0, v2.0.0, etc.)
   - Describe the security impact (data exposure, privilege escalation, etc.)
   - Provide proof of concept if possible (but do not include working exploit code that could be weaponized)

2. **Acknowledgment:** You will receive a response within 5 business days confirming receipt and initial triage

3. **Analysis:** We analyze the vulnerability and determine severity and affected components

4. **Patch development:** A fix is developed and tested

5. **Public disclosure:** After a patch is released, a CVE will be requested and published. You will be credited in the advisory unless you prefer anonymity

## Disclosure Timeline

- **90 days maximum** from vulnerability report to public patch release
- If 90 days is insufficient due to complexity, disclosure date will be renegotiated with reporter
- After 90 days, if no patch has been released, vulnerability may be disclosed publicly

## Scope

This security policy covers only this driver patch repository and its distributed binaries/scripts.

**In scope:**
- PATH-A `applewirelessmouse-patched-pathA-SHIPBLOCKER.sys` (installs as `applewirelessmouse.sys`) and KMDF `MagicMouseDriver-kmdf-2.0.4-scroll.sys` (installs as `MagicMouseDriver.sys`)
- PowerShell installer and uninstaller scripts
- Registry modifications made by installer/uninstaller
- Certificate installation process
- Documented installation/uninstall procedures

**Out of scope:**
- Security issues in Windows itself or BTHPORT
- Security issues in other software running on the system
- Security issues in Apple's original Magic Mouse firmware
- Social engineering or user misconfiguration

## Security Considerations for Users

### When Installing This Patch

1. **Verify binary integrity:** Always run the SHA256 hash check before installation
   ```powershell
   (Get-FileHash "applewirelessmouse-patched-pathA-SHIPBLOCKER.sys" -Algorithm SHA256).Hash
   # Expected: 370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03
   ```

2. **Certificate trust:** You will see a Windows Security prompt asking to trust the MagicMouseFix certificate
   - Verify the certificate name: **CN=MagicMouseFix**
   - Verify the thumbprint: **16940C0F937D569363560D5FEC5CD8FA6D6D9BCE**
   - Click **Install** only if these match

3. **Run installer as Administrator:** The installer requires full administrative privileges
   - Right-click PowerShell → Run as Administrator
   - Paste installer path and execute

4. **Create a system restore point (optional but recommended):**
   ```powershell
   Checkpoint-Computer -Description "Before MagicMousePatch v1.0.0"
   ```

### Windows Defender SmartScreen

On Windows 10/11, you may see a "Windows protected your PC" warning. This is normal for drivers signed with a new certificate. To proceed:

1. Click **More info**
2. Click **Run anyway**

This warning appears because the MagicMouseFix certificate is new and not yet widely distributed. As users install this patch, the certificate will gain reputation and this warning will disappear.

### Uninstalling

The uninstaller is just as important as the installer. To uninstall:

```powershell
.\Uninstall-MagicMousePatch.ps1
```

This removes:
- The driver binary
- The Windows service
- Registry entries
- Certificates
- Backup files

Restore only the original Windows-signed applewirelessmouse.sys driver (if one exists).

## Driver Signing

- **v1.0.0:** Signed with MagicMouseFix self-signed certificate (thumbprint: 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE)
- **v2.0.0 (future):** Will be signed with a commercial code-signing certificate for broader OS compatibility

## Known Security Boundaries

1. **Driver execution:** This driver runs in kernel mode with full system privileges
   - Malicious input from BT stack could theoretically cause DoS or memory corruption
   - Mitigated by: input validation before pointer dereference, bounds checking on collection data

2. **Registry modifications:** Installer writes to HKLM (system-wide registry)
   - Requires Administrator privilege; ordinary users cannot run installer
   - Uninstaller cleanly removes all entries

3. **Certificate trust:** By importing the certificate, you trust this driver until it's removed
   - Uninstaller removes certificate from both TrustedPublisher and Root stores
   - Certificate is code-signing only; it does not enable trust for other purposes

4. **File system:** Driver binary stored in C:\Windows\System32\drivers\ (protected directory)
   - Only SYSTEM and Administrator can write here
   - Backup stored in C:\ProgramData\MagicMousePatch\backup\ (moderate permissions)

## Reporting Other Security Issues

If you find a security issue in:
- The installer/uninstaller scripts (PowerShell security)
- The documentation or deployment instructions
- The GitHub Actions workflow security

Please report via the same process: riley@revivebusiness.ca

## Acknowledgments

Thank you to all researchers and users who report security issues responsibly. Your reports help keep all users safe.
