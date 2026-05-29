#!/usr/bin/env bash
# Wrapper-overhead gas runner on the genuine proprietary-AMM path.
#
# Queries Titan for the latest per-PMM stateOverride blob, flattens it into
# storage/balance/nonce arrays per venue, and runs PropAMMFeeWrapperPammForkGasTest
# against a Foundry fork pinned to Titan's published block — so FermiSwap /
# Kipseli / Bebop actually FILL instead of falling back to Uniswap V3.
#
# Adapted from PR #39's scripts/run_fork_tests.sh.
#
# Prereqs: $ETH_RPC_URL (mainnet RPC), and `cast`, `jq`, `forge` on PATH.
#
#   ETH_RPC_URL=<mainnet> ./scripts/run_wrapper_pamm_gas.sh

set -euo pipefail

: "${ETH_RPC_URL:?must be set — mainnet RPC for the fork}"
TITAN_URL="${TITAN_URL:-https://us.rpc.titanbuilder.xyz}"

FERMI=0xb1076fe3ab5e28005c7c323bac5ac06a680d452e
KIPSELI=0x5cdbe59400cc2efdcc2b54acca4a99fe00dd588c
BEBOP=0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea

echo "Fetching Titan stateOverrides from $TITAN_URL …"
TITAN_RESP=$(curl -s -X POST "$TITAN_URL" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"titan_getPammStateOverrides","params":[]}')

TITAN_BLOCK=$(echo "$TITAN_RESP" | jq -r '.result.blockNumber' | xargs cast to-dec)

# If the RPC trails Titan, capping the fork block to RPC head silently lands us
# on a block where Titan's quotes aren't valid yet — Fermi's `getState` reverts
# on the validAfter check and we fall back to Uniswap V3 instead of profiling
# the propAMM path. Poll briefly for the RPC to catch up; only cap if it stays
# behind past TITAN_WAIT_SECS (default 60s).
RPC_LATEST=$(cast block-number --rpc-url "$ETH_RPC_URL")
WAIT_LIMIT=${TITAN_WAIT_SECS:-60}
elapsed=0
while [ "$RPC_LATEST" -lt "$TITAN_BLOCK" ] && [ "$elapsed" -lt "$WAIT_LIMIT" ]; do
  echo "RPC at $RPC_LATEST, waiting for $TITAN_BLOCK (elapsed ${elapsed}s)…"
  sleep 3
  elapsed=$((elapsed + 3))
  RPC_LATEST=$(cast block-number --rpc-url "$ETH_RPC_URL")
done
if [ "$TITAN_BLOCK" -gt "$RPC_LATEST" ]; then
  echo "RPC still lags Titan after ${WAIT_LIMIT}s ($RPC_LATEST < $TITAN_BLOCK) — capping fork block to RPC head"
  TITAN_BLOCK=$RPC_LATEST
fi
echo "Titan block: $TITAN_BLOCK"

flatten_storage() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" '
    [ .result[$p].stateOverride // {}
      | to_entries[] as $a
      | ($a.value.stateDiff // {}) | to_entries[]
      | { account: $a.key, slot: .key, value: .value } ]'
}
# Titan returns balances/nonces as minimum-length hex ("0x1", "0xdc339fac0de8e0").
# parseJson encodes those as dynamic `bytes`, but AccountValue.value is `bytes32`
# (pammgas.t.sol:50-53), so abi.decode reverts on the type mismatch. Pad to 32
# bytes here so parseJson encodes as a single fixed-size word.
flatten_balances() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" '
    def pad32: ltrimstr("0x") as $h
      | "0x" + (("0000000000000000000000000000000000000000000000000000000000000000" + $h)[-64:]);
    [ .result[$p].stateOverride // {}
      | to_entries[] | select(.value.balance != null)
      | { account: .key, value: (.value.balance | pad32) } ]'
}
flatten_nonces() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" '
    def pad32: ltrimstr("0x") as $h
      | "0x" + (("0000000000000000000000000000000000000000000000000000000000000000" + $h)[-64:]);
    [ .result[$p].stateOverride // {}
      | to_entries[] | select(.value.nonce != null)
      | { account: .key, value: (.value.nonce | pad32) } ]'
}

TITAN_FERMI_STORAGE=$(flatten_storage "$FERMI")
TITAN_FERMI_BALANCES=$(flatten_balances "$FERMI")
TITAN_FERMI_NONCES=$(flatten_nonces "$FERMI")
TITAN_KIPSELI_STORAGE=$(flatten_storage "$KIPSELI")
TITAN_KIPSELI_BALANCES=$(flatten_balances "$KIPSELI")
TITAN_KIPSELI_NONCES=$(flatten_nonces "$KIPSELI")
TITAN_BEBOP_STORAGE=$(flatten_storage "$BEBOP")
TITAN_BEBOP_BALANCES=$(flatten_balances "$BEBOP")
TITAN_BEBOP_NONCES=$(flatten_nonces "$BEBOP")

# Surface per-venue override coverage. A venue with 0 storage entries means
# Titan didn't include it in this response — the venue won't fill, and the
# downstream `[venue] filled via propAMM: 0` is upstream-driven, not a bug.
echo "Per-venue override entries (storage / balances / nonces):"
for v in FERMI KIPSELI BEBOP; do
  st_var="TITAN_${v}_STORAGE"
  ba_var="TITAN_${v}_BALANCES"
  no_var="TITAN_${v}_NONCES"
  printf "  %-8s %3d / %3d / %3d\n" \
    "$v" \
    "$(jq length <<< "${!st_var}")" \
    "$(jq length <<< "${!ba_var}")" \
    "$(jq length <<< "${!no_var}")"
done

# Bebop freshness block (mapping_3[0] at slot keccak256(0,3)); the Bebop test
# vm.rolls to it because Bebop's swap check is strict-equality on block.number.
BEBOP_FRESH_BLOCK_HEX=$(echo "$TITAN_RESP" | jq -r '
  .result["0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"]
    .stateOverride["0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"]
    .stateDiff["0x3617319a054d772f909f7c479a2cebe5066e836a939412e32403c99029b92eff"] // empty')
if [ -n "$BEBOP_FRESH_BLOCK_HEX" ]; then
  BEBOP_FRESH_BLOCK=$(cast to-dec "$BEBOP_FRESH_BLOCK_HEX")
  echo "Bebop fresh block: $BEBOP_FRESH_BLOCK (delta from titan: $((TITAN_BLOCK - BEBOP_FRESH_BLOCK)))"
else
  # Slot absent from Titan response — the Bebop tests self-skip on
  # `bebopStorage.length == 0`, so this fallback is only kept to leave the
  # BEBOP_FRESH_BLOCK env var defined for the test that reads it.
  BEBOP_FRESH_BLOCK=$TITAN_BLOCK
  echo "Bebop fresh block: absent from Titan response (tests will self-skip)"
fi

export ETH_RPC_URL TITAN_BLOCK BEBOP_FRESH_BLOCK
export TITAN_FERMI_STORAGE TITAN_FERMI_BALANCES TITAN_FERMI_NONCES
export TITAN_KIPSELI_STORAGE TITAN_KIPSELI_BALANCES TITAN_KIPSELI_NONCES
export TITAN_BEBOP_STORAGE TITAN_BEBOP_BALANCES TITAN_BEBOP_NONCES

cd "$(dirname "$0")/.."

# 1. Consolidated gas numbers across every pammgas test (direct vs wrapper).
forge test --match-contract PropAMMFeeWrapperPammForkGasTest -vv "$@"

# 2. Per-path flamegraphs. `--flamegraph` profiles exactly ONE matching test.
#    Foundry 1.5+ bundles its own SVG renderer (no `inferno` needed) and writes
#    cache/flamegraph_<contract>_<test>.svg — already disambiguated by test
#    name, so no rename step. Non-fatal (|| true) so a single failed venue
#    doesn't abort the remaining flamegraphs after the gas table printed.
for t in \
  test_pammgas_fermi_direct_only test_pammgas_fermi_wrapper_only \
  test_pammgas_kipseli_direct_only test_pammgas_kipseli_wrapper_only \
  test_pammgas_bebop_direct_only test_pammgas_bebop_wrapper_only
do
  # Skip flamegraph passes for venues with zero overrides — they'd just profile
  # the Uniswap V3 fallback (the test self-skips, but skipping here too avoids
  # wasted forge invocations and stale leftover SVGs).
  v=$(echo "$t" | sed -E 's/test_pammgas_([^_]+)_.*/\1/' | tr 'a-z' 'A-Z')
  st_var="TITAN_${v}_STORAGE"
  if [ "$(jq length <<< "${!st_var}")" -eq 0 ]; then
    echo "Skipping flamegraph $t (no Titan overrides for $v)"
    continue
  fi
  forge test --match-contract PropAMMFeeWrapperPammForkGasTest \
    --match-test "$t" --flamegraph || true
done
