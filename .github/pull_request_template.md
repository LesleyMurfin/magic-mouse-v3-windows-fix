## Summary

What problem this solves and how. Note any breaking changes (usually none).

## Linked Issue

Fixes #

## Test Hardware

- **Windows Version and Build:** [`winver` output, e.g., Windows 11 build 22631]
- **Magic Mouse PID:** [0x0323 — this repo is v3-only]

## Test Results

Procedures are in CONTRIBUTING.md ("Test Procedures"). Mark PASS / FAIL / N/A.

- [ ] Test 1 (Fresh Install): PASS / FAIL / N/A
- [ ] Test 2 (Scroll Functionality): PASS / FAIL / N/A
- [ ] Test 3 (Idle Reconnect, 69-minute): PASS / FAIL / N/A
- [ ] Test 4 (Sleep/Wake): PASS / FAIL / N/A
- [ ] Test 5 (Device Rescan): PASS / FAIL / N/A

Details for any FAIL or N/A:

## Checklist

- [ ] Title starts with a conventional-commit prefix (`fix:` or `docs:`)
- [ ] Tested on real Magic Mouse v3 hardware, not assumed
- [ ] Event logs or screenshots attached where relevant (pnp-config.evtx, dsm-admin.evtx)
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1` is clean locally
- [ ] Docs updated (README/CHANGELOG/SECURITY) if the driver SHA256, size, or cert thumbprint changed
- [ ] All conversations resolved before requesting merge

The three driver constants (SHA256, byte size, certificate thumbprint) are duplicated
across nine files. `Install-MagicMousePatch.ps1` is the source of truth and CI gates
consistency; a partial update will fail the build.
