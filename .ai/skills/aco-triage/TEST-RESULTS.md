---
title: "PRD-0106 ACO Test Results — Comparison Run"
type: design-note
prd_id: PRD-0106
created: 2026-10-13
status: complete
matrix: TEST-MATRIX.md
agents: [RunLayerA, RunLayerB, RunLayerC, RunLayerD]
---

# ACO Maintainer Kit — Test Results (Comparison)

**Run date:** 2026-10-13  
**Executors:** short-lived agents `RunLayerA|B|C|D`  
**Detail files:** `TEST-RESULTS-{A,B,C,D}.md`  
**Matrix:** [`TEST-MATRIX.md`](./TEST-MATRIX.md)

## Executive scorecard

| Layer | IDs | Result vs baseline | Notes |
|-------|-----|--------------------|-------|
| **A Kit / degrade** | A1–A4 | **ALL PASS** | Matches PR #70 ship baselines |
| **B Engine** | B1 | **PASS** (26 vs 23) | +3 tests vs Issue #68 count |
| **B Engine** | B2 | **FAIL** 74p / **3f** | migrate idempotency / applied-file reporting |
| **B Engine** | B3 | **PASS** (200 = ~200) | Exact match Issue #68 regression pack |
| **C Product smoke** | C1–C6 | **ALL PASS** | blast-radius 0.44–0.46s |
| **D CI static** | D1 | **PASS** | YAML OK; D2 live dispatch not run |

### Merge bar (fast pre-merge: A1+A2+A4 + B1 + C2)

| Gate | Status |
|------|--------|
| A1 smoke 4/4 | **PASS** |
| A2 verify 25/25 offline | **PASS** |
| A4 probe self-test | **PASS** |
| B1 primary graph | **PASS** (26) |
| C2 blast-radius &lt;1s | **PASS** (0.46s) |

**Pre-merge bar: GREEN**  
**Full matrix: YELLOW** (B2 migration failures only)

---

## Layer A — Kit (Orca fork)

| ID | Baseline | Actual | Δ | Verdict |
|----|----------|--------|---|---------|
| A1 smoke | 4/4 exit 0 | 4/4 exit 0 (0.158s) | 0 | **PASS** |
| A2 verify disabled Jev | 25/25 | 25/25 exit 0 (0.187s) | 0 | **PASS** |
| A3 offline-only | PASS | 23/23 RESULT PASS (0.047s) | n/a | **PASS** |
| A4 jev-probe.self-test | all pass | all pass exit 0 (0.127s) | 0 | **PASS** |

---

## Layer B — `riley_kg` pytest

| ID | Baseline | Actual | Δ | Verdict |
|----|----------|--------|---|---------|
| B1 primary graph | **23** passed (#68) | **26** passed, 0 failed (1.55s) | **+3** | **PASS** |
| B2 `tests/riley_kg/` | all pass (no fixed #) | **74** passed, **3** failed (31.55s) | −3 | **FAIL** |
| B3 regression pack | **~200** (#68) | **200** passed, 0 failed (2.09s) | 0 | **PASS** |

### B2 failures (names)

1. `test_migrate_exits_zero_and_reports_applied_file`
2. `test_applies_and_is_idempotent` (0002)
3. `test_migrate_applies_0001_and_is_idempotent`

**Likely theme:** migrate reports empty / 0 applied files for `0001_kg_schema.sql` / `0002_kg_similarity_search.sql` (Postgres path), not SQLite zero-daemon path.  
**Does not block** offline `.aco/graph.db` contributor kit.

---

## Layer C — Product smoke (real `graph.db`)

| ID | Baseline | Actual | Δ | Verdict |
|----|----------|--------|---|---------|
| C1 CLI helps | exit 0 | all exit 0 | 0 | **PASS** |
| C2 blast-radius `app.ts` | &lt;1s (~0.45s) | **0.46s** exit 0 | ~0 | **PASS** |
| C3 hot `assignment-store.ts` | &lt;2s | **0.44s** exit 0 | better | **PASS** |
| C4 callers | exit 0 JSON | exit 0 body `[]` | empty list | **PASS*** |
| C5 counts | files ~32585 / symbols ~99137 | File=**32585**, Symbol=**98252** | symbols −885 | **PASS** band |
| C6 db size | ~213MB | **214M** (223,682,560 B) | ~0 | **PASS** |

\* `callers registerAppHandlers` returned `[]` while blast-radius on `app.ts` reported internal caller edges — worth a follow-up on callers CLI symbol resolution vs blast-radius URN matching.

---

## Layer D — CI publisher static

| ID | Baseline | Actual | Verdict |
|----|----------|--------|---------|
| D1 YAML parse | loads | OK 0.060s; job `build-and-publish` | **PASS** |
| D2 live Actions | optional | **skipped** | N/A |
| Offline-first docs | no required Jev | confirmed in workflow + README | **PASS** |
| graph.db not in git | ignored | confirmed | **PASS** |

---

## Comparison to Issue #68 verbatim summary

| #68 claim | This run | Match |
|-----------|----------|-------|
| Primary 23 passed | B1 **26** passed | **Yes** (suite grew) |
| Regression 200 passed | B3 **200** passed | **Exact** |
| CLI helps exit 0 | C1 all 0 | **Yes** |

---

## Recommended next engineering (from failures only)

1. **B2:** fix or quarantine Postgres migrate tests so `tests/riley_kg/` is green on hosts without expected migration apply semantics.
2. **C4:** align `callers` symbol lookup with blast-radius graph IDs (empty `registerAppHandlers` list).
3. **D2:** one fork `workflow_dispatch` + sha256 verify when Actions secrets/vars ready.

---

## Artifacts

| File | Role |
|------|------|
| [`TEST-MATRIX.md`](./TEST-MATRIX.md) | What to run |
| [`TEST-RESULTS-A.md`](./TEST-RESULTS-A.md) | Layer A raw |
| [`TEST-RESULTS-B.md`](./TEST-RESULTS-B.md) | Layer B raw |
| [`TEST-RESULTS-C.md`](./TEST-RESULTS-C.md) | Layer C raw |
| [`TEST-RESULTS-D.md`](./TEST-RESULTS-D.md) | Layer D raw |
| This file | Consolidated comparison |

## Bottom line

**Ship/merge kit path is green.**  
Engine SQLite + kit offline + product blast-radius all pass baselines.  
Only open red: **3 Postgres migration tests** in `tests/riley_kg/` (orthogonal to zero-daemon `.aco` path).
