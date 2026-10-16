---
title: "PRD-0106 ACO Maintainer Kit — Test Matrix"
type: design-note
prd_id: PRD-0106
version: 1.0.0
created: 2026-10-13
updated: 2026-10-13
status: active
---

# ACO Maintainer Kit — Test Matrix

Runnable gates for code development against the zero-daemon graph + optional Jev kit.
**Default posture:** offline-first. Live Jev/XERJ is never required to pass.

## Baselines (comparison targets)

| Suite | Baseline source | Expected |
|-------|-----------------|----------|
| Primary graph (23) | Issue #68 / prior green | 23 passed, exit 0 |
| Regression pack (~200) | Issue #68 | ~200 passed, exit 0 |
| Kit smoke | Orca PR #70 ship | 4/4 OK |
| Kit verify | Orca PR #70 ship | 25/25 PASS |
| jev-probe self-test | Orca PR #70 ship | all passed |
| blast-radius `app.ts` | M1 final | &lt; 1.0s (measured ~0.45–0.51s) |
| graph.db present | M1 final | ~213MB, queryable |
| Cold full index &lt;5min | PRD success criteria | **known FAIL** (~78min sync) — not a blocker for query path |

## Layer A — Kit / graceful-degrade (Orca fork)

**Workspace:** Orca fork `ai/orca-aco-graph-xerj-test-suite`  
**When:** any change under `.ai/skills/aco-triage/**` or `.ai/hooks/pre/jev-probe*`

```bash
cd <orca-fork-root>
python3 .ai/skills/aco-triage/tests/test_graceful_degrade_smoke.py
ORCA_JEV_DISABLED=1 python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py --offline-only
node --experimental-strip-types --no-warnings .ai/hooks/pre/jev-probe.self-test.ts
```

| ID | Command | Pass criteria |
|----|---------|---------------|
| A1 | smoke | 4 passed, exit 0 |
| A2 | verify + `ORCA_JEV_DISABLED=1` | passed=25 failed=0 |
| A3 | verify `--offline-only` | RESULT: PASS |
| A4 | jev-probe.self-test.ts | all assertions pass, exit 0 |

## Layer B — Structural engine (`riley_kg`)

**Workspace:** agents tree with `PYTHONPATH=.`  
**When:** any change under `riley_kg/`

```bash
cd <agents-root>
export PYTHONPATH=.
python3 -m pytest tests/test_init_sync_cli.py tests/test_sqlite_graph_engine.py tests/test_sqlite_store.py -q
python3 -m pytest tests/riley_kg/ -q
# optional broader pack
python3 -m pytest tests/test_aicostoptimizer_status.py tests/test_token_guard.py \
  tests/test_openrouter_benchmark_sync.py tests/test_lifecycle_reaper.py \
  tests/test_eve_eval.py tests/test_automations_e2e.py tests/test_fusion_harness.py -q
```

| ID | Suite | Pass criteria |
|----|-------|---------------|
| B1 | Primary graph 3 files | 23 passed (baseline #68) |
| B2 | `tests/riley_kg/` | all passed (record count) |
| B3 | Regression pack | ~200 passed (baseline #68) |

## Layer C — Product smoke on real `.aco/graph.db`

**When:** after engine/index format changes; release candidate

```bash
cd <orca-fork-root>
export PYTHONPATH=<agents-root>
python3 -m riley_kg.cli --help
python3 -m riley_kg.cli blast-radius --db .aco/graph.db src/main/ipc/app.ts
python3 -m riley_kg.cli blast-radius --db .aco/graph.db cloud/apps/relay/src/assignment-store.ts
python3 -m riley_kg.cli callers --db .aco/graph.db registerAppHandlers
sqlite3 .aco/graph.db "SELECT COUNT(*) FROM kg_nodes; SELECT COUNT(*) FROM kg_edges;"
du -h .aco/graph.db
```

| ID | Check | Pass criteria |
|----|-------|---------------|
| C1 | CLI `--help` / subcommand help | exit 0 |
| C2 | blast-radius `app.ts` | exit 0, wall &lt; 1.0s |
| C3 | blast-radius hot path | exit 0, wall &lt; 2.0s |
| C4 | callers | exit 0, JSON list |
| C5 | sqlite counts | nodes/edges &gt; 0; files ~32k symbols ~99k band |
| C6 | db size | present; ~200MB+ class (do not commit) |

## Layer D — CI publisher static

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/aco-index-publish.yml'))"
```

| ID | Check | Pass criteria |
|----|-------|---------------|
| D1 | workflow YAML parse | no exception |
| D2 | (optional) Actions dispatch | artifact + manifest sha256 match |

## Fast pre-merge gate (dev)

Run **A1+A2+A4 + B1 + C2**. That is the minimum merge bar for kit+engine PRs.

## Out of scope for this matrix

- Full Orca Electron / Playwright e2e
- Live Jev/XERJ as required dependency
- Committing `graph.db` into git

## Results log

Machine-written comparison runs append under:

- `orca/prd/106/TEST-RESULTS.md` (this PRD bundle)
- Optional copy on Orca fork: `.ai/skills/aco-triage/TEST-RESULTS.md`
