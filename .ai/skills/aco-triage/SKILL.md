---
name: aco-triage
description: >-
  ACO Maintainer Kit triage skill (PRD-0106 M2). Prefer the zero-daemon local
  `.aco/graph.db` via riley-kg for blast-radius and callers. Optional Jev/XERJ
  semantic enrichment is fail-open and NEVER required for contributors. Use when
  triaging PRs, checking blast radius, finding callers, or routing structural vs
  semantic queries via AICostOptimizer.
version: 0.2.2
---

# /aco-triage — ACO Maintainer Kit (Zero-Daemon Baseline)

## Contract (non-negotiable)

| Rule | Binding |
|------|---------|
| **Baseline** | Local SQLite `.aco/graph.db` via `riley-kg` when the db and the CLI are both present. **No daemon required.** |
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
   riley-kg → .aco/graph.db              Jev HTTP at JEV_URL
                                         choice / noul / score
                                         only if JEV_URL set + reachable
                                         else → local-only + note
```

- **Structural** (blast-radius, callers, symbol extract): `riley-kg` + `.aco/graph.db` whenever both are present and the query returns; if the file, the CLI, or the query is missing, empty, or stalled, use `rg` + `git` and label callers `method: "rg"`. Never block on the graph.
- **Semantic** (risk class, safety invariants, ADR score): try Jev **only** when:
  - `JEV_DISABLED` is unset/false, **and**
  - `JEV_URL` or `XERJ_URL` is set (opt-in), **and**
  - `.ai/hooks/pre/jev-probe.ts` last probe reported `reachable: true`.
- If any of those fail → continue on local graph and emit a one-line note:
  `ACO: Jev enrichment skipped (fail-open); using .aco/graph.db only`.

## AICostOptimizer and Jev — what actually exists

`aicostoptimizer` ships exactly one subcommand:

```bash
aicostoptimizer status        # daily provider token usage, --json available
```

There is **no** `jev` subcommand. `aicostoptimizer jev choice`, `jev noul` and
`jev score` all exit 2 with `invalid choice: 'jev' (choose from 'status')`, and
`python3 -m aicostoptimizer` cannot execute at all — the package has no
`__main__.py`, so the console script is the only entrypoint. Verified against
`LesleyMurfin/agents@agents-sqlite-graph`, the branch that provides the CLI.

Jev is therefore HTTP-only: set `JEV_URL`, let `.ai/hooks/pre/jev-probe.ts`
report reachability, and skip enrichment when it is unset or unreachable.
Neither CLI is on `PATH` in this repo's environment. Absent CLI means
enrichment is skipped, never that triage fails.

## Environment

| Variable | Role | Default |
|----------|------|---------|
| `JEV_URL` | Optional Jev base URL — when set, routing is active | unset → no enrichment |
| `XERJ_URL` | Optional XERJ base URL (opt-in) | unset → no enrichment |
| `JEV_DISABLED` | Force offline / local-only | unset (fail-open) |
| `ACO_GRAPH_DB` | Override path to graph DB | `.aco/graph.db` |

Probe timeout is hard-capped at **100ms** (see hook). Unreachable = skip, never retry-loop.

## Prerequisites

None are required. Structural triage falls back to `rg` + `git`.

Optional, when a maintainer has them:

1. `.aco/graph.db` in the checkout. This repo does not publish one.
2. The `riley-kg` console script on `PATH`
   (from `LesleyMurfin/agents@agents-sqlite-graph`):

```bash
riley-kg --help
```

No Elasticsearch, no Java daemon, no process on `:9200` / `:8009` is required for baseline triage.

## SOP

### Step 0 — Help

If args are only `--help` / `help`, print this skill's Contract + Commands sections and **STOP**.

### Step 1 — Resolve graph DB (fail-open)

```bash
DB="${ACO_GRAPH_DB:-.aco/graph.db}"
if [ ! -f "$DB" ] || ! command -v riley-kg >/dev/null 2>&1; then
  echo "ACO: no usable graph at $DB — continuing with rg + git"
fi
```

A missing graph or CLI is **not** an error and **not** a reason to require Jev. Never block on the graph.

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

### Step 3 — Structural triage via riley-kg (optional accelerator)

Blast radius of a file (symbols + callers):

```bash
riley-kg blast-radius --db "${ACO_GRAPH_DB:-.aco/graph.db}" v2-kmdf-driver/GestureEngine.c
```

Inbound callers of a symbol:

```bash
riley-kg callers --db "${ACO_GRAPH_DB:-.aco/graph.db}" AccumulateSurfaceScroll
```

If either command is missing, empty, or stalled, use `rg` + `git` and label callers
`method: "rg"`. Acceptance target (M1): blast-radius for a hot path should return in
well under a few seconds once the DB exists; no network hop is involved.

### Step 4 — Optional semantic enrichment (never required)

Only when Step 2 reported reachable **and** the user/agent explicitly wants semantic routing:

Jev enrichment is an HTTP call against `JEV_URL`, driven by
`.ai/hooks/pre/jev-probe.ts`. There is no CLI for it — see
"AICostOptimizer and Jev — what actually exists" above.

Rules:

- Timeout ≤ 100ms connect; overall request should stay short.
- Any failure → drop enrichment, keep structural answer, note skip.
- **Never** treat empty/unreachable Jev as triage failure.
- **Never** require contributors to set `JEV_URL` / `XERJ_URL`.

### Step 5 — Emit result

Always include:

1. Structural answer from `.aco/graph.db`, or from the `rg` + `git` fallback.
2. Enrichment status: `local-only` | `jev-enriched` | `jev-skipped-fail-open`.
3. DB path used and whether `JEV_DISABLED` was set.

## Commands (cheat sheet)

```bash
# Offline baseline — always available, no graph, no daemon
rg -n 'AccumulateSurfaceScroll' v2-kmdf-driver
git log --oneline -- v2-kmdf-driver/GestureEngine.c

# Optional accelerator, only when .aco/graph.db and riley-kg are both present
riley-kg blast-radius --db .aco/graph.db v2-kmdf-driver/InputHandler.c
riley-kg callers --db .aco/graph.db SdpRewrite_Process

# Forced offline (acceptance: JEV_DISABLED=1 must still succeed)
JEV_DISABLED=1 python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py --offline-only

# Optional probe only (does not fail the process on unreachable). Needs Node 22.6+.
node --experimental-strip-types --no-warnings .ai/hooks/pre/jev-probe.self-test.ts
```

## Verification

```bash
python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py --offline-only
```

`--offline-only` skips the optional TypeScript probe self-test, which needs Node 22.6+;
drop the flag to exercise it.

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
