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
- applewirelessmouse.sys kernel driver
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

1. **Verify binary integrity:** always run the SHA256 check before installation
   ```powershell
   (Get-FileHash ".\apple-driver\applewirelessmouse.sys" -Algorithm SHA256).Hash
   # Expected: 08F33D7E3ECE2C73950A9706F1C4C9057894EAEAF1C4FB355F261F3C2333378F   (78,424 bytes)
   ```
   `installer\SHA256SUMS.txt` publishes the same checksum in `sha256sum -c` format.

2. **Verify the signature rather than trusting a certificate.** The shipped driver is Apple's
   own binary, unmodified, so Windows already trusts it and nothing is added to a trust store:
   ```powershell
   $sig = Get-AuthenticodeSignature ".\apple-driver\applewirelessmouse.sys"
   $sig.Status                              # Valid
   $sig.SignerCertificate.Subject           # CN=Microsoft Windows Hardware Compatibility Publisher, ...
   ```
   If `Status` is anything other than `Valid`, stop: the file has been altered. The installer
   makes the same check and refuses to continue.

3. **Run the installer as Administrator:** `Install.cmd` requests elevation itself. If you run
   the PowerShell script directly, start an elevated PowerShell first.

4. **Create a system restore point (optional but recommended):**
   ```powershell
   Checkpoint-Computer -Description "Before MagicMousePatch"
   ```

### Windows Defender SmartScreen

SmartScreen may warn on a freshly downloaded archive, as it does for any new download. The
driver itself is Apple's, countersigned by Microsoft, so there is no self-signed certificate
needing to build reputation on the shipped route.

### Legacy patched variant

A previous release shipped a byte-patched copy of the driver re-signed as `CN=MagicMouseFix`
(SHA256 `370A5555…`, 66,288 bytes, thumbprint `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`).
Patching breaks Apple's Microsoft countersignature, so that variant required Windows Test Mode
with Secure Boot and memory integrity off, and imported its certificate into
`LocalMachine\TrustedPublisher` — never the Root store. **It is no longer shipped.** The values
are recorded so an existing installation can be identified; the installer labels it as legacy.

### Uninstalling

The uninstaller is just as important as the installer. To uninstall:

```powershell
.\Uninstall-MagicMousePatch.ps1
```

This removes:
- The driver binary
- The Windows service
- Registry entries
- Certificates, if the legacy variant installed one
- Backup files

Restore only the original Windows-signed applewirelessmouse.sys driver (if one exists).

## Driver Signing

- **Shipped Apple-driver route:** no project signing. Apple's `applewirelessmouse.sys` is
  redistributed unmodified and is already signed by Apple and countersigned by Microsoft
  (`CN=Microsoft Windows Hardware Compatibility Publisher`).
- **Legacy patched variant:** signed with the MagicMouseFix self-signed certificate
  (thumbprint `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`). No longer shipped.
- **v2 KMDF driver (future):** will need a commercial code-signing certificate.

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
