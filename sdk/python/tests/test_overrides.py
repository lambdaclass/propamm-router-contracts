"""Unit tests for pAMM state-override parsing and sources."""

from __future__ import annotations

import pytest
from eth_utils import to_checksum_address

from propamm.common.pamms import BEBOP
from propamm.error import OverridesError
from propamm.overrides import (
    BEBOP_DEFAULT_SLOT,
    OverridesSnapshot,
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


def _v2_venue(quote_address, contract, priced, slot_value, slot=10, block=20):
    return {
        "maker": "M",
        "quoteAddress": quote_address,
        "pricedAddresses": priced,
        "slot": slot,
        "blockNumber": block,
        "timestamp": 1792166394410832280,
        "stateOverride": {contract: {"stateDiff": {_word(1): _word(slot_value)}}},
    }


def test_parse_v2_venues_reads_entries_and_block_context():
    raw = {
        "venues": [
            _v2_venue("0x00000000000000000000000000000000000000aa", "0x" + "11" * 20, [], 7),
            _v2_venue(
                "0x00000000000000000000000000000000000000bb", "0x" + "22" * 20, [], 8, 11, 21
            ),
        ]
    }
    snapshot = parse_overrides_message(raw)
    assert set(snapshot.per_pamm) == {
        "0x00000000000000000000000000000000000000aa",
        "0x00000000000000000000000000000000000000bb",
    }
    assert snapshot.slot == 11 and snapshot.block_number == 21
    assert snapshot.timestamp_ns == 1792166394410832280


def test_to_state_override_selects_every_entry_a_router_venue_needs():
    from propamm.common.pamms import KIPSELI, METRIC

    metric_a, metric_b = (
        "0xe844701934d9c6085b292e428f41b911cc0b3872",
        "0x30a88bf894d1b806125a23ebf23d715496fd7102",
    )
    kipseli = "0xc9a956b5196dfe110debe8781857bc8b97d32091"
    raw = {
        "venues": [
            # Metric lists its router venue among the priced addresses.
            _v2_venue(metric_a, "0x" + "11" * 20, [metric_a, METRIC], 1),
            _v2_venue(metric_b, "0x" + "22" * 20, [metric_b, METRIC], 2),
            # Kipseli doesn't; its quote address is mapped to the venue instead.
            _v2_venue(kipseli, "0x" + "33" * 20, [kipseli], 3),
        ]
    }
    snapshot = parse_overrides_message(raw)

    def contracts(pamms):
        return sorted(to_state_override(snapshot, pamms=pamms, bebop_default=False))

    assert contracts([METRIC]) == sorted(
        [to_checksum_address("0x" + "11" * 20), to_checksum_address("0x" + "22" * 20)]
    )
    assert contracts([KIPSELI]) == [to_checksum_address("0x" + "33" * 20)]
