"""Regression test: the vendored router ABI must match the compiled contract.

Shells out to ``forge inspect`` from the repo root; skipped when forge or the
contract artifact is unavailable (e.g. an isolated package checkout).
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from propamm.router import abi

# sdk/python/tests -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


def test_vendored_abi_matches_forge_inspect():
    if shutil.which("forge") is None or not (REPO_ROOT / "foundry.toml").exists():
        pytest.skip("forge / contract artifacts not available")
    result = subprocess.run(
        ["forge", "inspect", "PropAMMRouter", "abi", "--json"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.skip(f"forge inspect failed: {result.stderr.strip()}")
    assert abi.ROUTER_ABI == json.loads(result.stdout), (
        "vendored propamm_router_abi.json is stale — regenerate with "
        "`forge inspect PropAMMRouter abi --json`"
    )
