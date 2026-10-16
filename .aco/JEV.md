# Jev / Kev — optional fail-open enrichment (PRD-0106)

This file is installed only when you run:

```bash
python3 scripts/install_aco_kit.py --target /path/to/repo --with-jev
```

It is a **pointer + contract doc**, not a full Jev client monorepo dump.
AICostOptimizer `packages/jev` is **not** portable into arbitrary target repos.

## Fail-open posture

- Jev/Kev enrichment is **optional**.
- A live **daemon is not required** for ACO triage, install, or offline work.
- **Jev is enabled whenever `JEV_URL` is set.**
- Unset endpoints, empty `JEV_URL`, network errors, or timeouts must **fail-open**
  (local structural triage on `.aco/graph.db` / git / rg still succeeds).

## Env sample

Copy `.aco/jev.env.sample` into your shell/profile as needed:

| Variable | Meaning |
|----------|---------|
| `JEV_URL` | Optional remote endpoint. When set and reachable, Jev enrichment is used. Omit or leave empty when offline. |

See also: `.aco/README.md`, `.ai/hooks/pre/jev-probe.ts` (≤100ms fail-open probe).

## Non-goals

- No `packages/jev/**` monorepo client vendoring
- No required listener on `:9200` / `:8009`
- No live daemon probe during `install_aco_kit.py`
