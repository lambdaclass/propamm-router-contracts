"""Regression tests: the SDKs must match the contracts they wrap.

Covers the vendored router ABI (via ``forge inspect``) and the hand-maintained
address constants (parsed from ``src/``, since file-level Solidity constants are
compile-time inlined and appear in no artifact). Each test skips when the thing
it compares against is unavailable, e.g. in an isolated package checkout.
"""

from __future__ import annotations

import json
import re
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


# `address constant NAME = 0x…;` — file-level Solidity constants.
_SOL_ADDRESS_CONSTANT = re.compile(
    r"^address\s+constant\s+(\w+)\s*=\s*(0x[0-9a-fA-F]{40})\s*;", re.MULTILINE
)
# `export const NAME: Address = "0x…";` — TypeScript SDK constants.
_TS_ADDRESS_CONSTANT = re.compile(
    r'^export\s+const\s+(\w+)\s*:\s*Address\s*=\s*"(0x[0-9a-fA-F]{40})"\s*;', re.MULTILINE
)

# Solidity constant name -> the SDK constant that must mirror it. `BEBOP_ROUTER`
# is load-bearing: the router dispatches `venue == BEBOP_ROUTER` down a bespoke
# `IBebopRouter` path rather than the generic `IPropAMM` one, so a stale SDK copy
# points callers at the wrong calling convention.
MIRRORED_CONSTANTS = {
    "BEBOP_ROUTER": "BEBOP",
    "USDC": "USDC",
    "USDT": "USDT",
    "WETH": "WETH",
    "ETH_SENTINEL": "ETH_SENTINEL",
}


def _solidity_address_constants() -> dict[str, str]:
    """Every file-level ``address constant`` in ``src/``, name -> lowercase address.

    These are compile-time inlined, so they appear in no forge artifact (no ABI
    entry, no storage slot, no getter) — the Solidity source is the only place
    to read them.
    """
    sources = sorted((REPO_ROOT / "src").rglob("*.sol"))
    if not sources:
        pytest.skip("contract sources not available")
    found: dict[str, str] = {}
    for path in sources:
        for name, address in _SOL_ADDRESS_CONSTANT.findall(path.read_text()):
            previous = found.setdefault(name, address.lower())
            assert previous == address.lower(), (
                f"conflicting `address constant {name}` declarations in src/"
            )
    return found


def test_address_constants_match_contract():
    from propamm.common import pamms, tokens

    solidity = _solidity_address_constants()
    for sol_name, sdk_name in MIRRORED_CONSTANTS.items():
        assert sol_name in solidity, f"`address constant {sol_name}` not found in src/"
        module = pamms if sdk_name == "BEBOP" else tokens
        actual = getattr(module, sdk_name).lower()
        assert actual == solidity[sol_name], (
            f"{sol_name} drifted: contracts say {solidity[sol_name]}, SDK says {actual}"
        )


def test_no_unmirrored_address_constant_in_contracts():
    """A new hardcoded `address constant` is a new dispatch target to mirror.

    The other venues have no Solidity counterpart — the router reaches them
    through the runtime `addVenue` whitelist and the generic `IPropAMM`
    interface, so only Bebop is hardcoded. If this fails, add the constant to
    `MIRRORED_CONSTANTS` and to each SDK (and to `PAMMS` if it is a venue).
    """
    unmirrored = sorted(set(_solidity_address_constants()) - set(MIRRORED_CONSTANTS))
    assert not unmirrored, (
        f"unmirrored `address constant`s in src/: {unmirrored} — mirror them in the SDKs"
    )


def test_typescript_address_constants_match_contract():
    """Guard the TypeScript SDK's constants from here.

    That SDK has no test runner of its own (its gate is
    `typecheck && lint && format:check`), so this repo-level check is what keeps
    its hand-maintained addresses honest.
    """
    solidity = _solidity_address_constants()
    ts_common = REPO_ROOT / "sdk" / "typescript" / "src" / "common"
    if not ts_common.is_dir():
        pytest.skip("TypeScript SDK sources not available")

    declared: dict[str, str] = {}
    for path in sorted(ts_common.glob("*.ts")):
        for name, address in _TS_ADDRESS_CONSTANT.findall(path.read_text()):
            declared[name] = address.lower()

    for sol_name, sdk_name in MIRRORED_CONSTANTS.items():
        assert sdk_name in declared, f"TypeScript SDK does not export {sdk_name}"
        assert declared[sdk_name] == solidity[sol_name], (
            f"{sol_name} drifted in the TypeScript SDK: contracts say "
            f"{solidity[sol_name]}, SDK says {declared[sdk_name]}"
        )
