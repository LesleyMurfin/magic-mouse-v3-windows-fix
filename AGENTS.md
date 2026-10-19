# Magic Mouse v3 Windows Fix

Read .context/ first.

Rules live in the shared store AGENTS.md.

- Code graph (optional, fail-open): if `.aco/graph.db` exists, `riley-kg blast-radius --db .aco/graph.db <file>` / `riley-kg callers --db .aco/graph.db <symbol>` (from LesleyMurfin/agents@agents-sqlite-graph); otherwise use `rg`/`git`. Never block on the graph.
- Cost: run `aicostoptimizer status` before long or expensive agent runs when it is installed; exit≠0 means quota fail-closed, so stop and report.
- Build: `bash v2-kmdf-driver/tests/validate-package.sh`
- Test: `python3 specs/gate_4.py && python3 v2-kmdf-driver/tests/test_bsod_regress.py && python3 v2-kmdf-driver/tests/test_hid_acl.py && python3 v2-kmdf-driver/tests/test_mt_enable.py && python3 v2-kmdf-driver/tests/test_scroll_threshold.py && python3 v2-kmdf-driver/tests/test_sdp_overlay.py && python3 v2-kmdf-driver/tests/test_two_finger_scroll.py && pwsh -NoProfile -File scripts/Test-SiteLink.ps1 && pwsh -NoProfile -File scripts/Test-ReleaseProvenance.ps1`
- Lint: `pwsh -NoProfile -Command "Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0; if (@(Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning,Error).Count -gt 0) { exit 1 }"`
