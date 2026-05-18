---
name: Bug Report
about: Report an issue with the Magic Mouse patch
title: "[BUG] "
labels: bug
assignees: ''

---

## Description

Brief description of the issue you're experiencing.

## Steps to Reproduce

1. Step 1...
2. Step 2...
3. Step 3...

## Expected Behavior

What should have happened?

## Actual Behavior

What actually happened?

## System Information

**Required:**

- **Windows Version:** [e.g., Windows 10]
- **Build Number:** [Run `winver` and copy the version/build info. Example: "Build 19045"]
- **Magic Mouse Model:** [Apple Magic Mouse v3 (2024) only]
- **Patch Version:** [v1.0.0 or other]

### Verify Hardware

Open Device Manager and locate your Magic Mouse:

1. **Windows Key + X** → Device Manager
2. Expand **Human Interface Devices**
3. Find **Apple Magic Mouse**
4. Right-click → **Properties** → **Details** tab
5. In dropdown, select **Hardware Ids**

**Paste the Hardware ID here:**
```
[Hardware ID - should contain VID&0001004C_PID&0323]
```

## Event Logs

**Required for all bug reports:**

### Kernel PnP Configuration Log

Open PowerShell as Administrator and run:

```powershell
wevtutil epl "Microsoft-Windows-Kernel-PnP/Configuration" C:\pnp-config.evtx
Write-Host "Exported to C:\pnp-config.evtx"
```

**Attach the file `C:\pnp-config.evtx` to this issue.**

### Device Setup Manager Log

Open PowerShell as Administrator and run:

```powershell
wevtutil epl "Microsoft-Windows-DeviceSetupManager/Admin" C:\dsm-admin.evtx
Write-Host "Exported to C:\dsm-admin.evtx"
```

**Attach the file `C:\dsm-admin.evtx` to this issue.**

### System Event Log (Optional but Helpful)

Open PowerShell as Administrator and run:

```powershell
wevtutil epl "System" C:\system.evtx
Write-Host "Exported to C:\system.evtx"
```

**Attach the file `C:\system.evtx` to this issue if available.**

## Service Status

Open PowerShell (no admin needed) and run:

```powershell
sc query applewirelessmouse
```

**Paste the output here:**
```
[Output of sc query applewirelessmouse]
```

## Installation Verification

Open PowerShell (no admin needed) and run:

```powershell
Get-Service applewirelessmouse -ErrorAction SilentlyContinue | Format-List Name, Status, DisplayName
```

**Paste the output here:**
```
[Output of Get-Service]
```

## Screenshots

If applicable, attach screenshots showing:
- Device Manager window (showing Magic Mouse with no warning icons)
- Error messages from Event Viewer
- Scroll behavior in a test application

## Additional Context

Any other information that might help us diagnose the issue:
- When did the problem start?
- Is it reproducible or intermittent?
- Have you made any system changes recently?
- Are you using any other input devices that might interfere?

---

## Checklist

Before submitting, verify:

- [ ] I have Windows 10 build 14393 or later, or Windows 11
- [ ] I have Apple Magic Mouse v3 (PID 0x0323), not earlier models
- [ ] I have installed the patch from the official repository
- [ ] I have provided the Windows build number (from `winver`)
- [ ] I have attached the Kernel PnP Configuration event log (pnp-config.evtx)
- [ ] I have attached the Device Setup Manager event log (dsm-admin.evtx)
- [ ] I have verified the service is running (`sc query applewirelessmouse`)
- [ ] I have provided clear steps to reproduce the issue
