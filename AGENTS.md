# AGENTS.md — Magic Mouse v3 Windows Driver

Read [`.context/`](.context/) first — `current.md`, `map.md`, `decisions.md`, `history.md`.

## Repo identity

**Apple Magic Mouse Windows Driver** (`LesleyMurfin/magic-mouse-v3-windows-fix`) — free MIT-licensed drivers for the USB-C **Apple Magic Mouse 2024** (Bluetooth PID `0323`) on **Windows 10/11**, plus registry-bound Apple-driver support for v1/v2 PIDs.

Two independent fixes (install **one**, not both):

| Path | What it is | Build |
|------|------------|-------|
| `v1-binary-patch/` | Driver 1 — Apple's unmodified `applewirelessmouse.sys` bound via registry / LowerFilters | No compile |
| `v2-kmdf-driver/` | Driver 2 — KMDF C driver `MagicMouseDriver-kmdf-204-scroll.sys` | EWDK / WDK + `msbuild` on Windows |

Companion tray app: [`LesleyMurfin/magic-tray`](https://github.com/LesleyMurfin/magic-tray) · [drivers.magictray.app](https://drivers.magictray.app/).

| Path | Role |
|------|------|
| `docs/` | Install / scroll-fix / battery guides |
| `scripts/` | Repo-level helpers |
| `specs/` | Behaviour specs |
| `.aco/` | ACO maintainer kit (prompts, JEV sample; never commit `graph.db`) |
| `.ai/skills/aco-triage/` | Portable ACO triage skill + graceful-degrade verifier |

<!-- BEGIN CORE-RULES -->
## Required charter — CORE-RULES

**Every agent must follow** the revive_ai-dev agent charter: `.ai/CORE-RULES.md`
(SSOT: `/data/projects/revive_ai-dev/.ai/CORE-RULES.md`, vendored by `governance_sync.py`).

### RULE #13 — ADHD output (binding, always on)

**One issue at a time. Action over documents. No drafts. Open ready-for-review PR, then STOP — merge is Lesley-only (RULE #23 / 2026-09-12 freeze).**

1. Lead with the action — command, path, or diff on line one. Never context first.
2. Finish the current issue before naming a second; extra findings go in one line at the end.
3. Restate state each turn ("Step 3 of 5 done: … Next: …"); end with exactly one next step.
4. No PRDs/specs/ADRs/issues unless that document was asked for. Fix the thing.
5. Cap tasks shown to Lesley at 5; complete all tasks and improvements. Suggestions: 2 rounds of reiteration with experts max, cheap/fast first, skip if none — do not dump the rounds on her. No preamble, recap, or closers. Diagrams over prose.

Never introduce vocabulary the owner has not used. Honour standing approval — do not re-gate
work she already approved. Off only on `stop adhd mode` / `normal mode`.

Full rule: `rule://adhd-always` · `skill://i-have-adhd` · charter RULE #13.

### Never a draft. Never someone else's repo.

- **No draft PRs, ever.** If it needs approval, open it **ready-for-review**. A draft never gets reviewed.
- **Never open a PR into a repo outside this one without explicit owner permission.**
  Prepare the branch and the body, then ask.

| Decade | Rules (summary) |
|--------|------------------|
| Truth | #1–4 evidence, no guessing |
| Judgment | #10–13 assumptions, pushback, **ADHD output (see above)** |
| Change | #20–22 design, MOP, skills |
| Craft | #30–32 simple, surgical, deliberate infra |
| Docs | #40–43 pointers, chunk reads, **current state outranks history** |
<!-- END CORE-RULES -->

## Build & test (verification)

**Linux cannot produce a `.sys`.** KMDF builds need Windows 10/11 x64 with a mounted **Enterprise WDK (EWDK)** or Visual Studio + WDK. See [`v2-kmdf-driver/BUILDING.md`](v2-kmdf-driver/BUILDING.md).

### Verified on a Linux agent host

- Package check: `bash v2-kmdf-driver/tests/validate-package.sh`
- Tests: `python3 specs/gate_4.py && python3 v2-kmdf-driver/tests/test_bsod_regress.py && python3 v2-kmdf-driver/tests/test_hid_acl.py && python3 v2-kmdf-driver/tests/test_mt_enable.py && python3 v2-kmdf-driver/tests/test_scroll_threshold.py && python3 v2-kmdf-driver/tests/test_sdp_overlay.py && python3 v2-kmdf-driver/tests/test_two_finger_scroll.py && python3 v2-kmdf-driver/tests/test_hires_scroll.py && pwsh -NoProfile -File scripts/Test-SiteLink.ps1 && pwsh -NoProfile -File scripts/Test-ReleaseProvenance.ps1`
- Lint: `pwsh -NoProfile -Command "Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0; if (@(Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning,Error).Count -gt 0) { exit 1 }"`

### KMDF (Driver 2)

```bat
REM EWDK LaunchBuildEnv / SetupBuildEnv amd64 shell, in v2-kmdf-driver/:
msbuild MagicMouseDriver.vcxproj /t:Build /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:EnableInf2cat=false /p:StampInf=false
```

```powershell
powershell -NoProfile -File scripts\Freeze-KmdfArtifact.ps1 -SysPath x64\Release\MagicMouseDriver-kmdf-204-scroll.sys
# INF validation before freeze/sign:
InfVerif.exe /v MagicMouseDriver-kmdf-204-scroll.inf
# After sign (SIGN-AND-INSTALL.md) — elevated hardware smoke:
pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install
```

Driver Test / community hardware checklist: [`v2-kmdf-driver/COMMUNITY-TESTING.md`](v2-kmdf-driver/COMMUNITY-TESTING.md).

### Driver 1 (Apple registry-bound)

Validate install scripts under `v1-binary-patch/` only. **Do not** modify bytes of `applewirelessmouse.sys`.

### Agent-host notes

When EWDK / hardware is unavailable:

- Treat compile/`InfVerif`/`pnputil` as documented verification.
- Still run static checks (`rg`, `git`, script lint if present).
- Record skipped hardware steps in the ACO footer `residual_risks`.

## Hard product constraints

- Emit **`MagicMouseDriver-kmdf-204-scroll.sys`** only — never `MagicMouseDriver.sys`, never `applewirelessmouse*.sys` from the KMDF tree.
- Do not binary-patch Apple's `.sys` in Driver 1; registry / LowerFilters only.
- Do not install Driver 1 and Driver 2 together on the same device stack.
- Frozen versions are one-shot; bump version for new builds.
- HID / scroll contracts: `v2-kmdf-driver/HID-CONTRACT.md`.

## AICostOptimizer & Code Graph Triage (binding)

KMDF/driver context: structural triage prefers C callers under `v2-kmdf-driver/` and
registry/INF paths under `v1-binary-patch/`. Fail-open to `git`/`rg` when the graph is empty.

1. **Prompt:** Reference `.aco/ACO-TRIAGE-PROMPT.txt` for structural and semantic analysis.
2. **Semantic Routing (Jev/Kev):** Active when `JEV_URL` is set:
   - Risk classification: `python3 -m aicostoptimizer jev choice --state ... --question ...`
   - Safety invariants ($p \ge 0.95$): `python3 -m aicostoptimizer jev noul --state ... --statement ...`
   - ADR compliance scoring: `python3 -m aicostoptimizer jev score --state ... --question ...`
   - Fail-open if `JEV_URL` unset/unreachable → local `.aco/graph.db` + `git`/`rg` for C/INF. Optional: `JEV_DISABLED=1`.
3. **Structural Graph:** Uses local `.aco/graph.db` when present; fails open to `git`/`rg` for C/INF if Jev is unset/unreachable or the graph is empty.
4. **Output Contract:** Every PR review ends with ```json aco-triage-run```.
5. **Clean repo:** Never commit `.aco/graph.db`.

### Pre-flight

```bash
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py
```

Expect PASS on the offline path. Non-zero → fix the verifier/script first; still do not block review on a missing graph.

Cost gate: run `aicostoptimizer status` before long or expensive agent runs when it is installed; exit≠0 means quota fail-closed — stop and report.

### Blast-radius query (conditional, fail-open)

When **both** `.aco/graph.db` and the `riley_kg` CLI are present:

```bash
PYTHONPATH="${RILEY_KG_ROOT:-${ACO_RILEY_KG_ROOT:-}}" \
  python3 -m riley_kg.cli blast-radius --db .aco/graph.db <path-or-symbol>
```

Typical C/KMDF targets: `v2-kmdf-driver/` (`Driver.c`, `InputHandler.c`, `GestureEngine.c`, `HidDescriptor.c`, INF/RC).

If graph DB, CLI, or C extract is missing / times out / empty:

- **Fail-open immediately to `git` + `rg`** for C callers and INF/service references (label `method: "rg"` / heuristic).
- Set `graph.present=false` in the run footer.
- **Never** block a PR review on graph availability.

```bash
rg -n "ScrollStep|LowerFilters|MagicMouseDriver|InputHandler|GestureEngine" v2-kmdf-driver v1-binary-patch
git grep -n "PID_0323\|0x0323"
```

### Zero daemons

- No localhost graph/search daemons.
- **Never commit** `.aco/graph.db` (blocked by the ACO gitignore fragment).

### Output contract (every PR review)

Every ACO triage / PR review **MUST** end with exactly one full machine footer:

````markdown
```json aco-triage-run
{
  "schema_version": "aco-triage-run/v1",
  "run_id": "<slug-date>",
  "timestamp": "<ISO-Z>",
  "workspace_root": "<pwd>",
  "branch": "<branch>",
  "head_sha": "<sha>",
  "pr_ref": "LesleyMurfin/magic-mouse-v3-windows-fix#N",
  "graph": { "present": false, "db_path": null, "node_count": 0, "edge_count": 0, "scoped": true, "build_seconds": null },
  "tooling": { "riley_kg_ok": false, "jev_used": false, "pythonpath": null },
  "targets": [],
  "blast_radius": [],
  "findings": [],
  "verification": [{ "command": "InfVerif.exe /v MagicMouseDriver-kmdf-204-scroll.inf", "exit_code": null, "passed": false }],
  "diff_stats": null,
  "residual_risks": ["EWDK/hardware not on agent host → document-only driver validation"],
  "prompt_version": "1.4.0-quick",
  "pr_comment_status": "skipped|posted",
  "pr_comment_urls": []
}
```
````

Populate from the real run. Chat narrative alone is not enough for ingest. If a PR is in scope, post a `gh pr comment` checklist (P0/P1) and record URLs in the footer.

### Skill pointer

- `.ai/skills/aco-triage/SKILL.md`
- `.ai/skills/aco-triage/scripts/verify_graceful_degrade.py`
- `.aco/README.md` · optional `.aco/JEV.md` + `.aco/jev.env.sample`

## PR hygiene

- Branch off `main`; open **ready-for-review** PRs only (never draft).
- Merge is **Lesley-only**.
- Prefer smallest safe diff; evidence for every caller / blast claim.
- Do not push directly to `main`.
- Do not claim a `.sys` was built or signed unless the artifact and hash are produced in-session.
- DCO: every commit must include `Signed-off-by:`.
