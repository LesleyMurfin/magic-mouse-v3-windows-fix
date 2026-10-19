<!-- State now. Outranks history.md and decisions.md; AGENTS.md and Lesley outrank it. Keep it short. No transcripts or secrets. -->

# Current

**Goal.** Keep two-finger scroll working for Apple Magic Mouse on Windows 10/11, and let Magic Tray
read battery. Two independent fixes: Driver 1 (registry-bound Apple `applewirelessmouse.sys`) and
Driver 2 (from-scratch KMDF, PID `0323` only). Install one, not both. `README.md`.

**State on main.** `df02e50` (2026-10-15), merge of PR #47. Driver 1 is v1.0.0 production ready:
unmodified Apple binary, `LowerFilters` registration, PIDs `030D` / `0269` / `0310` / `0323`. Test
Mode is expected unnecessary and is not yet verified with `testsigning` off
(`v1-binary-patch/README.md`). Driver 2 source is 2.0.4.6; the last build signed and run on hardware
is 2.0.4.3 (`v2-kmdf-driver/STATUS.md`). Site is `docs/`, published at drivers.magictray.app.

**Open.** PR #50 (`ai/agents-md-and-aco-kit`) is ready and adds a full AGENTS.md plus an ACO kit; it
is not merged, and it will conflict with this pointer-only AGENTS.md. Still open on the product:
Driver 1 with `testsigning` off; a Windows build and sign of 2.0.4.6; the community `pnputil`
swap-test (never run); EV attestation (funding). Battery on v1/v2 PIDs is not characterised
(`docs/llms.txt`).

**Next.** Build and sign 2.0.4.6 on a Windows host with the EWDK or WDK, then confirm battery,
pointer, and 2-finger scroll on hardware (`v2-kmdf-driver/STATUS.md`, `BUILDING.md`).
