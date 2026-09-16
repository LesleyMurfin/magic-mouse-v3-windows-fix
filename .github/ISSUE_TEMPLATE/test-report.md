---
name: Test Report
about: Report results from running the Test 1-5 procedures on real hardware
title: "[TEST] "
labels: test-report
assignees: ''

---

Run the procedures in CONTRIBUTING.md ("Test Procedures") first, then fill this in.

## Test Results

**Hardware:** Apple Magic Mouse v3 (PID 0x0323)
**Windows:** [Windows 10 build 14393 / Windows 11 build 22H2 / etc.]
**Patch Version:** [v1.0.0 or commit SHA]

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

**Event logs:** issue attachments are public and permanently visible. Raw .evtx files
embed your Bluetooth MAC address, device instance ID, hostname, and user name. .evtx is
binary, so convert it to text and redact there before attaching:

```powershell
(wevtutil qe "Microsoft-Windows-Kernel-PnP/Configuration" /f:text) -replace '(?<=&0&)[0-9A-Fa-f]{12}', 'REDACTEDMAC' -replace '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}', 'XX:XX:XX:XX:XX:XX' | Set-Content C:\pnp-config.txt
```

Repeat with "Microsoft-Windows-DeviceSetupManager/Admin" for dsm-admin.txt, then replace
any remaining hostname or user name by hand. Attach the redacted .txt files, not the raw
.evtx. If a log cannot be safely redacted, email it to riley@revivebusiness.ca instead.

**Event logs attached:** [pnp-config.txt, dsm-admin.txt - redacted]
