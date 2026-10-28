---
name: aco-triage
description: >-
  ACO Maintainer Kit triage skill (PRD-0106 M2). Prefer the zero-daemon local
  `.aco/graph.db` via riley_kg for blast-radius and callers. Optional Jev/XERJ
  semantic enrichment is fail-open and NEVER required for contributors. Use when
  triaging PRs, checking blast radius, finding callers, or routing structural vs
  semantic queries via AICostOptimizer.
version: 0.2.0
---

# /aco-triage — ACO Maintainer Kit (Zero-Daemon Baseline)

## Contract (non-negotiable)

| Rule | Binding |
|------|---------|
| **Baseline** | Local SQLite `.aco/graph.db` via `riley_kg`. **No daemon required.** |
| **Jev/XERJ** | **OPTIONAL** and **fail-open**. Contributors MUST complete triage without it. |
| **Opt-in** | Enrichment only when `JEV_URL` is set AND the pre-probe reports reachable. |
| **Disable** | `JEV_DISABLED=1` (or unset URLs) forces pure local path. |
| **No hardpaths** | Resolve DB relative to repo root (`.aco/graph.db`). No `/home/...` without `# hardpath-ok`. |
| **Secrets** | Do NOT push active Jev endpoints or maintainer secrets to public remotes. |

## Purpose

Give maintainers and agents a single triage path that:

1. Always answers **structural** questions (blast radius, callers, symbols) from the local graph.
2. **May** enrich with **semantic** memory via AICostOptimizer Jev when `JEV_URL` is set and up.
3. **Never** blocks, times out, or fails a session because Jev is down, firewalled, or absent.

## Routing

```
                    ┌─────────────────────────────┐
  triage request ─► │ jev-probe (<100ms, fail-open)│
                    └─────────────┬───────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                       ▼
   structural query                          semantic query
   (always local)                            (optional only)
              │                                       │
              ▼                                       ▼
   riley_kg → .aco/graph.db              AICostOptimizer jev
                                         choice / noul / score
                                         only if JEV_URL set + reachable
                                         else → local-only + note
```

- **Structural** (blast-radius, callers, symbol extract): **always** `riley_kg` + `.aco/graph.db`.
- **Semantic** (risk class, safety invariants, ADR score): try Jev **only** when:
  - `JEV_DISABLED` is unset/false, **and**
  - `JEV_URL` or `XERJ_URL` is set (opt-in), **and**
  - `.ai/hooks/pre/jev-probe.ts` last probe reported `reachable: true`.
- If any of those fail → continue on local graph and emit a one-line note:
  `ACO: Jev enrichment skipped (fail-open); using .aco/graph.db only`.

## AICostOptimizer Jev commands (when JEV_URL is set)

```bash
python3 -m aicostoptimizer jev choice   # risk classification
python3 -m aicostoptimizer jev noul     # safety invariants (p ≥ 0.95)
python3 -m aicostoptimizer jev score    # ADR compliance scoring
```

## Environment

| Variable | Role | Default |
|----------|------|---------|
| `JEV_URL` | Optional Jev base URL — when set, routing is active | unset → no enrichment |
| `XERJ_URL` | Optional XERJ base URL (opt-in) | unset → no enrichment |
| `JEV_DISABLED` | Force offline / local-only | unset (fail-open) |
| `ACO_GRAPH_DB` | Override path to graph DB | `.aco/graph.db` |
| `RILEY_KG_PYTHONPATH` | Parent of the `riley_kg` package | unset → rely on env/`PYTHONPATH` |

Probe timeout is hard-capped at **100ms** (see hook). Unreachable = skip, never retry-loop.

## Prerequisites

1. Repo has `.aco/graph.db` (contributor may download a CI artifact; maintainer may run `riley_kg` init/sync).
2. `riley_kg` CLI importable, e.g.:

```bash
# hardpath-ok — maintainer lab path only; contributors use their own checkout/PYTHONPATH
export PYTHONPATH="${RILEY_KG_PYTHONPATH:-/data/projects/agents}${PYTHONPATH:+:$PYTHONPATH}"  # hardpath-ok
python3 -m riley_kg.cli --help
```

No Elasticsearch, no Java daemon, no process on `:9200` / `:8009` is required for baseline triage.

## SOP

### Step 0 — Help

If args are only `--help` / `help`, print this skill's Contract + Commands sections and **STOP**.

### Step 1 — Resolve graph DB (mandatory)

```bash
DB="${ACO_GRAPH_DB:-.aco/graph.db}"
test -f "$DB" || { echo "ACO: missing $DB — baseline graph required; no daemon fallback exists"; exit 1; }
```

Missing graph is a **setup** error (fetch artifact or run init/sync). It is **not** a reason to require Jev.

### Step 2 — Honor disable / probe (fail-open)

```bash
# Forced local-only
if [ "${JEV_DISABLED:-}" = "1" ]; then
  echo "ACO: JEV_DISABLED=1 — local .aco/graph.db only"
fi

# Optional pre-flight (never blocks). Prefer the TS hook in-session;
# for shell smoke, use the skill verifier:
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py --offline-only
```

In an OMP session the auto-discovered hook `.ai/hooks/pre/jev-probe.ts` runs at `session_start`, probes in **&lt;100ms**, and leaves `pi.acoJev` state. On any error it **fails open** (`reachable: false`).

### Step 3 — Structural triage via riley_kg (baseline)

Blast radius of a file (symbols + callers):

```bash
python3 -m riley_kg.cli blast-radius --db "${ACO_GRAPH_DB:-.aco/graph.db}" path/to/file.ts
```

Inbound callers of a symbol:

```bash
python3 -m riley_kg.cli callers --db "${ACO_GRAPH_DB:-.aco/graph.db}" SymbolName
```

Acceptance target (M1): blast-radius for a hot path should return in well under a few seconds once the DB exists; no network hop is involved.

### Step 4 — Optional semantic enrichment (never required)

Only when Step 2 reported reachable **and** the user/agent explicitly wants semantic routing:

```bash
python3 -m aicostoptimizer jev choice
python3 -m aicostoptimizer jev noul
python3 -m aicostoptimizer jev score
```

Rules:

- Timeout ≤ 100ms connect; overall request should stay short.
- Any failure → drop enrichment, keep structural answer, note skip.
- **Never** treat empty/unreachable Jev as triage failure.
- **Never** require contributors to set `JEV_URL` / `XERJ_URL`.

### Step 5 — Emit result

Always include:

1. Structural answer from `.aco/graph.db` (or explicit missing-DB error).
2. Enrichment status: `local-only` | `jev-enriched` | `jev-skipped-fail-open`.
3. DB path used and whether `JEV_DISABLED` was set.

## Commands (cheat sheet)

```bash
# Baseline — zero daemon
python3 -m riley_kg.cli blast-radius --db .aco/graph.db src/main/ipc/app.ts
python3 -m riley_kg.cli callers --db .aco/graph.db MySymbol

# Forced offline (acceptance: JEV_DISABLED=1 must still succeed)
JEV_DISABLED=1 python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py

# Optional probe only (does not fail the process on unreachable)
node --experimental-strip-types --no-warnings .ai/hooks/pre/jev-probe.self-test.ts
```

## Verification

```bash
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py
```

The verifier asserts:

- Offline path works with no network and with `JEV_DISABLED=1`.
- Optional Jev path is not required (unset URLs ⇒ local-only success).
- Probe helper is fail-open under absurd URLs / tiny timeouts.

## Non-goals

- Replacing `eve_smoke` or other memory indices.
- Shipping production XERJ endpoints in public remotes.
- Requiring full-repo AST rebuild on every contributor clone (CI artifact is preferred).

## Feedback

Bump `version` in frontmatter when changing routing or env contracts. Keep language explicit: **optional**, **fail-open**, **no daemon required**.
