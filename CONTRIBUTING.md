# Contributing

Thank you for helping improve the Magic Mouse v3 Windows scroll fix.

## Reporting Issues

### Before You Report

1. Verify you have the correct hardware: Apple Magic Mouse v3 (2024), PID 0x0323
   ```powershell
   # Device Manager → Human Interface Devices → Apple Magic Mouse
   # Right-click → Properties → Details → Hardware Ids
   # Look for PID&0323
   ```

2. Verify Windows version compatibility (build 14393+)
   ```powershell
   winver
   ```

3. Check that the installer completed successfully
   ```powershell
   sc query applewirelessmouse
   # Should show STATE : 4 RUNNING
   ```

### Required Information for Bug Reports

**All issues must include:**

- **Windows version and build number** (`winver` output)
- **Magic Mouse hardware version** (should be v3 / 2024 model)
- **PID from Device Manager** (should be 0x0323)
- **Steps to reproduce** (exact sequence to trigger the issue)
- **Event logs** (see below)

### Collecting Event Logs

Copy and paste this into PowerShell as Administrator:

```powershell
# Export Kernel PnP Configuration log
wevtutil epl "Microsoft-Windows-Kernel-PnP/Configuration" C:\pnp-config.evtx
Write-Host "Exported to C:\pnp-config.evtx"

# Export Device Setup Manager log
wevtutil epl "Microsoft-Windows-DeviceSetupManager/Admin" C:\dsm-admin.evtx
Write-Host "Exported to C:\dsm-admin.evtx"
```

Attach both .evtx files to your GitHub issue.

**Optional but helpful:**
```powershell
# Export full system event log
wevtutil epl "System" C:\system.evtx
```

## Testing Patches

### Environment Setup

1. **Backup your current driver state:**
   ```powershell
   # Before testing a PR, verify your current version works
   sc query applewirelessmouse
   Get-PnpDevice -Class Mouse | Where-Object {$_.Name -match "Apple"}
   ```

2. **Clone the repository:**
   ```powershell
   git clone https://github.com/ReviveBusiness/magic-mouse-v3-windows-fix.git
   cd magic-mouse-v3-windows-fix
   ```

3. **Check out the feature branch:**
   ```powershell
   git checkout <branch-name>
   ```

### Test Procedures

#### Test 1: Fresh Install
```powershell
# Run uninstaller first (if v1.0.0 currently installed)
.\v1-binary-patch\installer\Uninstall-MagicMousePatch.ps1
# Reboot
shutdown /r /t 60

# After reboot, run fresh install
.\v1-binary-patch\installer\Install-MagicMousePatch.ps1
# Reboot
shutdown /r /t 60

# After reboot, verify driver loaded
sc query applewirelessmouse
Get-PnpDevice -Class Mouse | Where-Object {$_.Name -match "Apple"}
```

#### Test 2: Scroll Functionality
1. Open Notepad or any application with scrollable content
2. Position cursor over scrollable area
3. Scroll using Magic Mouse wheel — verify smooth, responsive scrolling
4. Scroll in opposite direction — verify responsiveness
5. Document results in your test comment

#### Test 3: Idle Reconnect (69-minute test)
1. After install, start timer
2. Use Magic Mouse normally for 5 minutes
3. Turn off Magic Mouse (power switch)
4. Wait 60+ minutes (do not use mouse; let system idle)
5. Turn Magic Mouse back on
6. **Verify scroll still works** (this is the key test)
7. If scroll stops: this is a regression — report immediately
8. If scroll persists: patch is good — document time elapsed before testing

#### Test 4: Sleep/Wake
1. Open calculator or text editor
2. Windows + X → Shut Down → Sleep
3. Wait 5 minutes
4. Move Magic Mouse or press any key to wake
5. Verify scroll works on wake
6. Repeat 3 times

#### Test 5: Device Rescan
```powershell
# Run this after install
pnputil /restart-device "BTHENUM\{<DeviceID>}"
# (Replace with actual Device ID from Device Manager)

# Then test scroll functionality
```

### Document Your Test Results

Comment on the pull request with:

```markdown
## Test Results

**Hardware:** Apple Magic Mouse v3 (PID 0x0323)
**Windows:** [Windows 10 build 14393 / Windows 11 build 22H2 / etc.]

**Test 1 (Fresh Install):** PASS / FAIL
- Details: [any observations]

**Test 2 (Scroll Functionality):** PASS / FAIL
- Scroll response: [smooth / laggy / broken / etc.]
- Both directions: [yes / no / issue description]

**Test 3 (Idle Reconnect):** PASS / FAIL
- Time before testing: [X minutes]
- Scroll on wake: [works / does not work]
- Issue: [if any]

**Test 4 (Sleep/Wake):** PASS / FAIL
- Cycles tested: 3
- Issue after wake: [none / describe]

**Test 5 (Device Rescan):** PASS / FAIL
- Rescan result: [scroll persists / scroll stopped]

**Event logs attached:** [pnp-config.evtx, dsm-admin.evtx]
```

## Pull Requests

### Before Submitting

1. **Format PowerShell scripts:**
   ```powershell
   # Run PSScriptAnalyzer locally
   Invoke-ScriptAnalyzer -Path "v1-binary-patch/installer/*.ps1" -Recurse
   # Fix any warnings/errors
   ```

2. **Test on your hardware** (see Testing Procedures above)

3. **Create a feature branch:**
   ```powershell
   git checkout -b ai/fix-description
   ```

4. **Commit with clear messages:**
   ```powershell
   git add .
   git commit -m "fix: brief description of fix"
   ```

### PR Requirements

- **Title:** Start with `fix:` or `docs:` (conventional commits)
- **Description:** Include:
  - What problem this solves
  - How it solves the problem
  - Test results from your hardware
  - Any breaking changes (usually none)
- **Link to issue:** `Fixes #123`
- **Test evidence:** Attach event logs or screenshots if relevant
- **All scripts:** Must pass PSScriptAnalyzer checks (GitHub Actions will verify)

### PR Review Process

1. GitHub Actions runs PSScriptAnalyzer on all .ps1 files
2. Code owners review for:
   - Correctness of registry operations
   - Proper error handling in PowerShell
   - Safe cleanup in uninstaller
   - No hardcoded paths (use relative paths where possible)
3. At least one approval required before merge
4. All conversations must be resolved

## Code Style

### PowerShell Scripts

- Use verb-noun naming (Invoke-, Get-, Set-, Remove-, etc.)
- All public functions must have comment-based help:
  ```powershell
  <#
  .SYNOPSIS
  Brief description
  .DESCRIPTION
  Longer description
  .PARAMETER Name
  Parameter description
  .EXAMPLE
  Example usage
  #>
  ```
- Error handling: always check exit codes after external commands
  ```powershell
  if ($LASTEXITCODE -ne 0) {
      Write-Host "Error: ..." -ForegroundColor Red
      exit 1
  }
  ```
- Use `Write-Host` with colors for user feedback (yes) vs `Write-Output` (for return values)
- No external dependencies; use Windows APIs directly where possible

### Documentation

- Use Markdown with proper headings (h1, h2, h3)
- Include code examples with language tags
- Keep line length under 100 characters for readability
- Use BLUF style: bottom-line-up-front, details follow
- No AI-generated fluff ("I hope this helps", "In conclusion")

## Questions?

Contact: riley@revivebusiness.ca

Security issues: see SECURITY.md
