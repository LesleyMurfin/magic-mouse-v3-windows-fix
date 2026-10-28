# `.aco/` — ACO Maintainer Kit index (zero-daemon)

This directory holds the ACO Maintainer Kit triage prompt and notes (PRD-0106).
Structural triage runs from the local checkout: no Elasticsearch, no search daemon,
no network hop. This repo does not publish `.aco/graph.db`, so `rg` + `git` is the
normal path and the graph is a bonus when a maintainer has one.

| File | Tracked? | Purpose |
|------|----------|---------|
| `README.md` | yes | This file |
| `ACO-TRIAGE-PROMPT.txt` | yes | Binding triage prompt |
| `jev.env.sample` | yes | Sample variables for the optional fail-open probe hook |
| `graph.db` | **no** | Optional SQLite symbol graph for `riley-kg` |
| `graph.db-wal` / `graph.db-shm` | **no** | SQLite sidecars if a graph file is opened |
| `graph.json` | **no** | Optional export / debug dump |
| `manifest.json` | **no** | Not published by this repo |

## Baseline contract

1. **Structural triage** reads `.aco/graph.db` through `riley-kg`:
   `riley-kg blast-radius --db .aco/graph.db <file>` and
   `riley-kg callers --db .aco/graph.db <symbol>`.
   If the file, the CLI, or the query is missing, empty, or stalled, use `rg` and
   `git`, and label callers `method: "rg"`. Never block on the graph.
2. **Do not commit** `graph.db`.

## Smoke commands

Always:

```bash
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py --offline-only
python3 .ai/skills/aco-triage/tests/test_graceful_degrade_smoke.py
```

`--offline-only` skips the optional TypeScript probe self-test, which needs Node 22.6+;
drop the flag to exercise it.

Only when the tool is installed — and `riley-kg` also needs `.aco/graph.db`, which this
repo does not ship:

```bash
riley-kg blast-radius --db .aco/graph.db v2-kmdf-driver/GestureEngine.c
riley-kg callers --db .aco/graph.db AccumulateSurfaceScroll
```

Related skill: `.ai/skills/aco-triage/`. Binding prompt: `.aco/ACO-TRIAGE-PROMPT.txt`.
The optional URL probe `.ai/hooks/pre/jev-probe.ts` is fail-open, and is not the graph
query; sample variables for it are in `.aco/jev.env.sample`. Never
commit live secrets.
