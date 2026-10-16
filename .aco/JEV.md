# Jev / Kev — optional fail-open enrichment (PRD-0106)

This file is installed only when you run:

```bash
python3 scripts/install_aco_kit.py --target /path/to/repo --with-jev
```

It is a **pointer + contract doc**, not a full Jev client monorepo dump.
AICostOptimizer `packages/jev` is **not** portable into arbitrary target repos.

## Fail-open posture

- Jev/Kev semantic routing is **enabled via AICostOptimizer whenever `JEV_URL` is set**.
- Live routing uses TypeSafe Jev commands through AICostOptimizer; failures and missing
  endpoints **automatically fail-open** to local SQLite graph (`.aco/graph.db`) and `git`/`rg`.
- A live **daemon is not required** for ACO triage, install, or offline work.
- Unset endpoints, empty `JEV_URL`, network errors, or timeouts must **fail-open**
  (local structural triage still succeeds).

## AICostOptimizer TypeSafe Jev commands (when JEV_URL is set)

```bash
# Risk classification
python3 -m aicostoptimizer jev choice --state '{"repo":"..."}' --question "..." --option A --option B
# Safety invariants (require p >= 0.95 before relying on the claim)
python3 -m aicostoptimizer jev noul --state '{"repo":"..."}' --statement "..."
# ADR compliance scoring
python3 -m aicostoptimizer jev score --state '{"repo":"..."}' --question "..." --rubric-name name --rubric-desc desc
```

## Env sample

Copy `.aco/jev.env.sample` into your shell/profile as needed:

| Variable | Meaning |
|----------|---------|
| `JEV_URL` | Remote endpoint — when set, Jev routing is active via AICostOptimizer |
| `JEV_DISABLED=1` | Optional override to force offline / local-only (default: active when URL set) |

See also: `.aco/README.md`, `.ai/hooks/pre/jev-probe.ts` (≤100ms fail-open probe).

## Non-goals

- No `packages/jev/**` monorepo client vendoring
- No required listener on `:9200` / `:8009`
- No live daemon probe during `install_aco_kit.py`
