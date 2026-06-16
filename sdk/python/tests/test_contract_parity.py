"""Regression test: every signature the SDK binds must match the compiled contract.

Shells out to ``forge inspect`` from the repo root; skipped when forge or the
contract artifact is unavailable (e.g. an isolated package checkout). Mirrors
the Rust SDK's contract-parity test.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from propamm_sdk.router import abi

# sdk/python/tests -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


def _forge_inspect(field: str) -> dict[str, str]:
    if shutil.which("forge") is None or not (REPO_ROOT / "foundry.toml").exists():
        pytest.skip("forge / contract artifacts not available")
    result = subprocess.run(
        ["forge", "inspect", "PropAMMRouter", field, "--json"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.skip(f"forge inspect {field} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def test_bound_functions_exist_on_the_contract():
    identifiers = _forge_inspect("methodIdentifiers")
    missing = [sig for sig in abi.FUNCTIONS if sig not in identifiers]
    assert not missing, f"signatures absent from the contract: {missing}"
    # And our computed selectors agree with forge's.
    for sig in abi.FUNCTIONS:
        assert abi.selector(sig).hex() == identifiers[sig]


def test_bound_events_exist_on_the_contract():
    topics = _forge_inspect("events")
    missing = [sig for sig in abi.EVENTS if sig not in topics]
    assert not missing, f"events absent from the contract: {missing}"
    for sig in abi.EVENTS:
        assert "0x" + abi.event_topic(sig).hex() == topics[sig]


def test_bound_errors_exist_on_the_contract():
    identifiers = _forge_inspect("errors")
    # EnforcedPause comes from OpenZeppelin's Pausable, not the router's own
    # Errors.sol, but is still in the compiled ABI.
    missing = [sig for sig in abi.ERROR_SIGNATURES if sig not in identifiers]
    assert not missing, f"errors absent from the contract: {missing}"
    for sig in abi.ERROR_SIGNATURES:
        assert abi.selector(sig).hex() == identifiers[sig]
