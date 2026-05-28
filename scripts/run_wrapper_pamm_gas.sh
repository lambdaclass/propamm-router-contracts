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

RPC_LATEST=$(cast block-number --rpc-url "$ETH_RPC_URL")
if [ "$TITAN_BLOCK" -gt "$RPC_LATEST" ]; then
  echo "RPC lags Titan ($RPC_LATEST < $TITAN_BLOCK) — capping fork block to RPC head"
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
flatten_balances() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" '
    [ .result[$p].stateOverride // {}
      | to_entries[] | select(.value.balance != null)
      | { account: .key, value: .value.balance } ]'
}
flatten_nonces() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" '
    [ .result[$p].stateOverride // {}
      | to_entries[] | select(.value.nonce != null)
      | { account: .key, value: .value.nonce } ]'
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

# Bebop freshness block (mapping_3[0] at slot keccak256(0,3)); the Bebop test
# vm.rolls to it because Bebop's swap check is strict-equality on block.number.
BEBOP_FRESH_BLOCK_HEX=$(echo "$TITAN_RESP" | jq -r '
  .result["0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"]
    .stateOverride["0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"]
    .stateDiff["0x3617319a054d772f909f7c479a2cebe5066e836a939412e32403c99029b92eff"] // empty')
if [ -n "$BEBOP_FRESH_BLOCK_HEX" ]; then
  BEBOP_FRESH_BLOCK=$(cast to-dec "$BEBOP_FRESH_BLOCK_HEX")
else
  BEBOP_FRESH_BLOCK=$TITAN_BLOCK
fi
echo "Bebop fresh block: $BEBOP_FRESH_BLOCK (delta from titan: $((TITAN_BLOCK - BEBOP_FRESH_BLOCK)))"

export ETH_RPC_URL TITAN_BLOCK BEBOP_FRESH_BLOCK
export TITAN_FERMI_STORAGE TITAN_FERMI_BALANCES TITAN_FERMI_NONCES
export TITAN_KIPSELI_STORAGE TITAN_KIPSELI_BALANCES TITAN_KIPSELI_NONCES
export TITAN_BEBOP_STORAGE TITAN_BEBOP_BALANCES TITAN_BEBOP_NONCES

cd "$(dirname "$0")/.."

# 1. Consolidated gas numbers across every pammgas test (direct vs wrapper).
forge test --match-contract PropAMMFeeWrapperPammForkGasTest -vv "$@"

# 2. Per-path flamegraphs. `--flamegraph` profiles exactly ONE matching test and
#    needs `inferno` on PATH (`cargo install inferno`). Foundry always writes
#    cache/flamegraph.svg, so rename between runs. Non-fatal (|| true) so a
#    missing inferno doesn't abort after the numbers above already printed.
forge test --match-contract PropAMMFeeWrapperPammForkGasTest \
  --match-test test_pammgas_kipseli_direct_only --flamegraph || true
mv -f cache/flamegraph.svg cache/flamegraph.kipseli_direct.svg 2>/dev/null || true

forge test --match-contract PropAMMFeeWrapperPammForkGasTest \
  --match-test test_pammgas_kipseli_wrapper_only --flamegraph || true
mv -f cache/flamegraph.svg cache/flamegraph.kipseli_wrapper.svg 2>/dev/null || true
