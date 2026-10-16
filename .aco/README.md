# `.aco/` — ACO Maintainer Kit index (zero-daemon)

This directory holds the **local structural graph** used by the ACO Maintainer Kit
(PRD-0106). Contributors do **not** run Elasticsearch, Jev, XERJ, or any other
daemon to triage PRs.

| File | Tracked? | Purpose |
|------|----------|---------|
| `README.md` | yes | This file |
| `ACO-TRIAGE-PROMPT.txt` | yes | Opening prompt for structural triage |
| `JEV.md` | yes (optional) | Jev fail-open contract |
| `jev.env.sample` | yes (optional) | Sample `JEV_URL` env |
| `graph.db` | **no** | SQLite AST / symbol graph (`riley_kg`) |
| `graph.db-wal` / `graph.db-shm` | **no** | SQLite runtime sidecars during sync |
| `graph.json` | **no** | Optional export / debug dump |
| `manifest.json` | **no** (published via CI) | sha256, source SHA, sizes |

## Baseline contract

1. **Structural triage** (blast radius, callers, symbols) always reads
   `.aco/graph.db` via `riley_kg`. No network hop.
2. **Jev / XERJ** enrichment is **optional** and **fail-open**.
   **Jev is enabled whenever `JEV_URL` is set.** Unset / empty / unreachable
   `JEV_URL` → local-only success (`.aco/graph.db`, then git/rg).
3. **Do not commit** `graph.db` (≈200MB+) to `main`. GitHub’s blob limit is
   100MB; the CI workflow publishes Release assets instead.

## Obtain a graph without building

Preferred (after the fork workflow has run at least once):

1. Open the latest **GitHub Release** tagged `aco-index` (or `aco-index-<sha>`).
2. Download `graph.db` (and optionally `manifest.json`).
3. Place `graph.db` here: `.aco/graph.db`.
4. Verify checksum against `manifest.json` when present.

Alternate discovery: fetch the orphan branch that carries only the manifest:

```bash
git fetch origin aco-index
git show origin/aco-index:.aco/manifest.json
```

Then download the Release asset named in the manifest.

Workflow source: `.github/workflows/aco-index-publish.yml` (workflow_dispatch;
push-to-main trigger stays commented so a fork merge cannot surprise-bill CI).

## Build locally (maintainers)

Requires `riley_kg` on `PYTHONPATH` (or installed):

```bash
export PYTHONPATH="${RILEY_KG_PYTHONPATH:-${RILEY_KG_ROOT:-}}${PYTHONPATH:+:$PYTHONPATH}"

python3 -m riley_kg.cli init --path . --repo owner/name --out-dir .aco
python3 -m riley_kg.cli sync --path . --db .aco/graph.db
```

Full-repo init/sync can take tens of minutes and produce ~200MB+ under `.aco/`.
Prefer the CI artifact for day-to-day contributor work.

## Smoke commands

```bash
# Offline graceful-degrade gate (M2) — no JEV_URL required
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py
python3 .ai/skills/aco-triage/tests/test_graceful_degrade_smoke.py

# Structural query once graph.db exists
python3 -m riley_kg.cli blast-radius --db .aco/graph.db <path-or-symbol>
```

Related skill: `.ai/skills/aco-triage/`. Optional probe hook:
`.ai/hooks/pre/jev-probe.ts` (≤100ms, fail-open).
