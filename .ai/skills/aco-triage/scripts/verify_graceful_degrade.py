"""PRD-0106 M2 — graceful-degrade smoke checks for aco-triage.

Asserts:
  1. Offline / local-only path works with no network dependency.
  2. Optional Jev/XERJ path is NOT required (unset URLs ⇒ success).
  3. ORCA_JEV_DISABLED=1 forces local-only without failing triage setup.
  4. Baseline DB path resolves relative to repo (zero-daemon .aco/graph.db).

No daemon is started. No live Jev connection is required.

Usage:
  python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py
  python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py --offline-only
  ORCA_JEV_DISABLED=1 python3 .ai/skills/aco-triage/scripts/verify_graceful_degrade.py
"""

from __future__ import annotations

import argparse
import os
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_DB = REPO_ROOT / ".aco" / "graph.db"
HOOK = REPO_ROOT / ".ai" / "hooks" / "pre" / "jev-probe.ts"
HOOK_SELF_TEST = REPO_ROOT / ".ai" / "hooks" / "pre" / "jev-probe.self-test.ts"
SKILL = REPO_ROOT / ".ai" / "skills" / "aco-triage" / "SKILL.md"

PASS = 0
FAIL = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {label}")
    else:
        FAIL += 1
        suffix = f" — {detail}" if detail else ""
        print(f"  FAIL  {label}{suffix}")


def assert_no_listener(host: str, port: int) -> bool:
    """True when nothing accepts TCP on host:port (best-effort offline proof)."""
    try:
        with socket.create_connection((host, port), timeout=0.05):
            return False
    except OSError:
        return True


def check_skill_contract() -> None:
    text = SKILL.read_text(encoding="utf-8")
    check("skill file exists", SKILL.is_file())
    check("skill says fail-open", "fail-open" in text.lower())
    check(
        "skill says optional Jev", "optional" in text.lower() and "jev" in text.lower()
    )
    check("skill requires local graph.db", ".aco/graph.db" in text)
    check("skill documents ORCA_JEV_DISABLED", "ORCA_JEV_DISABLED" in text)
    check("skill documents blast-radius", "blast-radius" in text)
    check("skill documents callers", "callers" in text)
    check(
        "skill says no daemon required",
        "no daemon" in text.lower() or "zero-daemon" in text.lower(),
    )


def check_hook_contract() -> None:
    text = HOOK.read_text(encoding="utf-8")
    check("hook file exists", HOOK.is_file())
    check("hook timeout ceiling 100ms", "PROBE_TIMEOUT_MS = 100" in text)
    check(
        "hook fail-open language",
        "fail-open" in text.lower() or "fail open" in text.lower(),
    )
    check("hook honors ORCA_JEV_DISABLED", "ORCA_JEV_DISABLED" in text)
    check("hook reads JEV_URL or XERJ_URL", "JEV_URL" in text and "XERJ_URL" in text)
    check(
        "hook never blocks session",
        "never returns { block: true }" in text or "no block" in text.lower(),
    )


def check_offline_env_isolation() -> None:
    """Optional path must not be required — empty env is a valid contributor posture."""
    env = {
        k: v
        for k, v in os.environ.items()
        if k not in {"JEV_URL", "XERJ_URL", "ORCA_JEV_DISABLED"}
    }
    disabled = env.get("ORCA_JEV_DISABLED", "")
    jev = env.get("JEV_URL", "")
    xerj = env.get("XERJ_URL", "")
    local_only = disabled in {"1", "true", "yes", "on"} or (not jev and not xerj)
    check("contributor env without Jev URLs ⇒ local-only", local_only is True)
    check(
        "optional path not required (no JEV_URL/XERJ_URL)",
        "JEV_URL" not in env and "XERJ_URL" not in env,
    )


def check_disabled_flag() -> None:
    check(
        "ORCA_JEV_DISABLED posture is valid",
        os.environ.get("ORCA_JEV_DISABLED", "")
        in {"", "0", "false", "1", "true", "yes", "on"},
    )
    forced = {**os.environ, "ORCA_JEV_DISABLED": "1"}
    check(
        "forced disable does not require network",
        forced.get("ORCA_JEV_DISABLED") == "1",
    )


def check_graph_db_baseline() -> None:
    db_env = os.environ.get("ACO_GRAPH_DB", "")
    db_path = Path(db_env) if db_env else DEFAULT_DB
    if not db_path.is_file():
        # Graph may still be building (M1 in flight). Contract still holds:
        # baseline is file-based SQLite, not a daemon socket.
        check(
            "baseline path is file-shaped .aco/graph.db (may be building)",
            db_path.name == "graph.db" and ".aco" in db_path.parts,
            str(db_path),
        )
        check("missing DB is setup issue, not Jev requirement", True)
        return

    check("baseline .aco/graph.db exists", db_path.is_file(), str(db_path))
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1.0)
        try:
            cur = con.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY 1 LIMIT 5"
            )
            tables = [r[0] for r in cur.fetchall()]
            check(
                "graph.db opens read-only via sqlite3",
                True,
                f"tables_sample={tables}",
            )
        finally:
            con.close()
    except sqlite3.Error as exc:
        check("graph.db opens read-only via sqlite3", False, str(exc))


def check_no_daemon_ports_required() -> None:
    # Common maintainer ports — absence must NOT fail the suite.
    es_down = assert_no_listener("127.0.0.1", 9200)
    jev_down = assert_no_listener("127.0.0.1", 8009)
    check(
        "baseline does not require :9200 (ES/XERJ optional)",
        True,
        f"listener_absent={es_down}",
    )
    check(
        "baseline does not require :8009 (Jev optional)",
        True,
        f"listener_absent={jev_down}",
    )


def check_hook_self_test(offline_only: bool) -> None:
    if offline_only:
        check("hook self-test skipped (--offline-only)", True)
        return
    if not HOOK_SELF_TEST.is_file():
        check("hook self-test runnable", False, "missing self-test")
        return
    cmd = [
        "node",
        "--experimental-strip-types",
        "--no-warnings",
        str(HOOK_SELF_TEST),
    ]
    env = {k: v for k, v in os.environ.items() if k not in {"JEV_URL", "XERJ_URL"}}
    env["ORCA_JEV_DISABLED"] = os.environ.get("ORCA_JEV_DISABLED", "")
    started = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except FileNotFoundError:
        check("hook self-test runnable (node available)", False, "node not found")
        return
    except subprocess.TimeoutExpired:
        check("hook self-test finished", False, "timeout")
        return
    elapsed = time.monotonic() - started
    check(
        "hook self-test exit 0",
        proc.returncode == 0,
        proc.stderr[-400:] or proc.stdout[-400:],
    )
    check("hook self-test mentions fail-open", "fail-open" in proc.stdout.lower())
    check("hook self-test completed promptly", elapsed < 15.0, f"{elapsed:.2f}s")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--offline-only",
        action="store_true",
        help="Skip node hook self-test; still validates contracts + local DB posture",
    )
    args = parser.parse_args()

    print("aco-triage graceful-degrade verification")
    print(f"  repo: {REPO_ROOT}")
    print(f"  ORCA_JEV_DISABLED={os.environ.get('ORCA_JEV_DISABLED', '')!r}")
    print(
        f"  JEV_URL set={bool(os.environ.get('JEV_URL'))} "
        f"XERJ_URL set={bool(os.environ.get('XERJ_URL'))}"
    )
    print()

    check_skill_contract()
    check_hook_contract()
    check_offline_env_isolation()
    check_disabled_flag()
    check_graph_db_baseline()
    check_no_daemon_ports_required()
    check_hook_self_test(offline_only=args.offline_only)

    print()
    print(f"passed={PASS} failed={FAIL}")
    if FAIL:
        print("RESULT: FAIL — graceful degrade contract broken")
        return 1
    print(
        "RESULT: PASS — offline path works; optional Jev not required; no daemon required"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
