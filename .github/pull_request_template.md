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

- [ ] Title uses Conventional Commits: a type prefix plus optional scope, then a colon
      (`fix`, `docs`, `feat`, `chore`, `ci`, `refactor`, `test`; e.g. `feat(ci):`).
      Dependabot's generated `chore(ci):` titles are exempt from this check.
- [ ] Tested on real Magic Mouse v3 hardware, not assumed
- [ ] Event logs or screenshots attached where relevant, redacted per CONTRIBUTING.md
      ("Collecting Event Logs") - attach the converted .txt, never the raw .evtx
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1` is clean locally
- [ ] Docs updated (README/CHANGELOG/SECURITY) if the driver SHA256, size, or cert thumbprint changed
- [ ] All conversations resolved before requesting merge

The three driver constants (SHA256, byte size, certificate thumbprint) are duplicated
across nine files. `Install-MagicMousePatch.ps1` is the source of truth and CI gates
consistency; a partial update will fail the build.
