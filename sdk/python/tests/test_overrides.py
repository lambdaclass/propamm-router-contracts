"""Unit tests for pAMM state-override parsing and sources."""

from __future__ import annotations

import pytest
from eth_utils import to_checksum_address

from propamm_sdk.common.pamms import BEBOP
from propamm_sdk.error import OverridesError
from propamm_sdk.overrides import (
    BEBOP_DEFAULT_SLOT,
    OverridesSnapshot,
    _LEGACY_BEBOP_LOWER,
    _parse_rpc_response,
    parse_overrides_message,
    to_state_override,
)


def _word(n: int) -> str:
    return "0x" + format(n, "064x")


def _snapshot_with(pamm, contract, slot, value, block_number=None):
    return OverridesSnapshot(
        block_number=block_number,
        timestamp_ns=None,
        per_pamm={pamm.lower(): {contract.lower(): {slot: value}}},
    )


def test_rpc_response_treats_null_error_as_success():
    body = {"jsonrpc": "2.0", "id": 1, "error": None, "result": {"blockNumber": 100}}
    snapshot = _parse_rpc_response(body)
    assert snapshot.block_number == 100


def test_rpc_response_parses_result_when_error_key_absent():
    body = {"result": {"blockNumber": 5}}
    snapshot = _parse_rpc_response(body)
    assert snapshot.block_number == 5
    assert snapshot.per_pamm == {}


def test_rpc_response_surfaces_a_real_error_object():
    body = {"error": {"code": -32000, "message": "boom"}}
    with pytest.raises(OverridesError):
        _parse_rpc_response(body)


def test_rpc_response_errors_clearly_without_result_or_error():
    body = {"jsonrpc": "2.0", "id": 1}
    with pytest.raises(OverridesError, match="neither a result nor an error"):
        _parse_rpc_response(body)


def test_parse_overrides_message_extracts_diffs_and_skips_metadata():
    pamm = "0x0000000000000000000000000000000000000abc"
    contract = "0x0000000000000000000000000000000000000011"
    raw = {
        "blockNumber": 24_285_034,
        "timestamp": 1_700_000_000_000_000_000,
        "slot": "meta-key-ignored",
        pamm: {"stateOverride": {contract: {"stateDiff": {"0x1": "0x2a"}}}},
    }
    snapshot = parse_overrides_message(raw)
    assert snapshot.block_number == 24_285_034
    assert snapshot.timestamp_ns == 1_700_000_000_000_000_000
    assert len(snapshot.per_pamm) == 1
    assert snapshot.per_pamm[pamm.lower()][contract.lower()][1] == 42


def test_parse_overrides_message_drops_empty_and_invalid_entries():
    raw = {
        "not-an-address": {"stateOverride": {}},
        "0x00000000000000000000000000000000000000ff": {
            "stateOverride": {"0x0000000000000000000000000000000000000011": {"stateDiff": {}}}
        },
    }
    assert parse_overrides_message(raw).per_pamm == {}


def test_to_state_override_zeroes_the_bebop_default_slot_when_absent():
    pamm = "0x0000000000000000000000000000000000000abc"
    contract = to_checksum_address("0x0000000000000000000000000000000000000011")
    snapshot = _snapshot_with(pamm, contract, 7, 99, block_number=1)

    state = to_state_override(snapshot)
    # The real diff survives...
    assert state[contract]["stateDiff"][_word(7)] == _word(99)
    # ...and the Bebop registry slot is zeroed because no Bebop entry exists.
    assert state[BEBOP]["stateDiff"][_word(int(BEBOP_DEFAULT_SLOT, 16))] == _word(0)


def test_to_state_override_can_skip_the_bebop_default():
    pamm = "0x0000000000000000000000000000000000000abc"
    contract = to_checksum_address("0x0000000000000000000000000000000000000011")
    snapshot = _snapshot_with(pamm, contract, 7, 99)

    state = to_state_override(snapshot, bebop_default=False)
    assert BEBOP not in state


def test_to_state_override_keeps_real_bebop_diffs_without_injecting_default():
    contract = to_checksum_address("0x0000000000000000000000000000000000000011")
    # pAMM IS Bebop, so Bebop's own default-slot injection is skipped.
    snapshot = _snapshot_with(BEBOP, contract, 7, 99)

    state = to_state_override(snapshot)
    assert state[contract]["stateDiff"][_word(7)] == _word(99)
    assert BEBOP not in state
    # ...but the legacy Bebop venue, which never has a fresh override, is still
    # neutralized.
    legacy = to_checksum_address(_LEGACY_BEBOP_LOWER)
    assert state[legacy]["stateDiff"][_word(int(BEBOP_DEFAULT_SLOT, 16))] == _word(0)


def test_parse_word_accepts_padded_and_unpadded_hex():
    raw = {
        "0x0000000000000000000000000000000000000abc": {
            "stateOverride": {
                "0x0000000000000000000000000000000000000011": {
                    "stateDiff": {"0x1": "0x2a", "0x2": "0x1"}
                }
            }
        }
    }
    snapshot = parse_overrides_message(raw)
    contract = "0x0000000000000000000000000000000000000011"
    slots = snapshot.per_pamm["0x0000000000000000000000000000000000000abc"][contract]
    assert slots[1] == 42
    assert slots[2] == 1
