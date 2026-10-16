"""Minimal unit/smoke tests for ACO triage graceful degradation (PRD-0106 M2).

Run:
  python3 .ai/skills/aco-triage/tests/test_graceful_degrade_smoke.py
  python3 -m unittest .ai/skills/aco-triage/tests/test_graceful_degrade_smoke.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
VERIFY = (
    ROOT / ".ai" / "skills" / "aco-triage" / "scripts" / "verify_graceful_degrade.py"
)
SKILL = ROOT / ".ai" / "skills" / "aco-triage" / "SKILL.md"
HOOK = ROOT / ".ai" / "hooks" / "pre" / "jev-probe.ts"


class GracefulDegradeSmoke(unittest.TestCase):
    def test_files_exist(self) -> None:
        self.assertTrue(SKILL.is_file(), f"missing skill: {SKILL}")
        self.assertTrue(HOOK.is_file(), f"missing hook: {HOOK}")
        self.assertTrue(VERIFY.is_file(), f"missing verifier: {VERIFY}")

    def test_offline_path_without_network_env(self) -> None:
        """Unset Jev URLs + explicit disable must still pass verification."""
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in {"JEV_URL", "XERJ_URL", "JEV_DISABLED"}
        }
        env["JEV_DISABLED"] = "1"
        # Drop proxy vars so nothing accidental reaches the network.
        for k in list(env):
            if k.lower().endswith("_proxy"):
                env.pop(k, None)
        proc = subprocess.run(
            [sys.executable, str(VERIFY), "--offline-only"],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        self.assertIn("optional Jev not required", proc.stdout)

    def test_optional_path_not_required_when_urls_unset(self) -> None:
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in {"JEV_URL", "XERJ_URL", "JEV_DISABLED"}
        }
        proc = subprocess.run(
            [sys.executable, str(VERIFY), "--offline-only"],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)
        self.assertIn("PASS", proc.stdout)

    def test_skill_explicit_fail_open_language(self) -> None:
        text = SKILL.read_text(encoding="utf-8").lower()
        self.assertIn("fail-open", text)
        self.assertIn("optional", text)
        self.assertIn("no daemon", text.replace("zero-daemon", "no daemon"))
        self.assertIn("aicostoptimizer", text)
        self.assertIn("jev_disabled", text)


if __name__ == "__main__":
    unittest.main()
