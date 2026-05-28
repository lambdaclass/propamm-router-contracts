#!/usr/bin/env bash
# Fork-test runner for `SwapForkTest`.
#
# Queries Titan for the latest per-PMM stateOverride blob, flattens it
# into three [{account, slot, value}, …] arrays (one per venue), and runs
# the Solidity tests against a Foundry fork pinned to Titan's published
# block.
#
# Prereqs:
#   - `$ETH_RPC_URL` must point at a mainnet RPC (Alchemy / Infura / your
#     own archive node — anywhere with `eth_getBlockByNumber` for the
#     fork block).
#   - `cast`, `jq`, `forge` on PATH.

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

# Titan returns blockNumber as hex; vm.envUint wants decimal.
TITAN_BLOCK=$(echo "$TITAN_RESP" \
  | jq -r '.result.blockNumber' \
  | xargs cast to-dec)

# The RPC node often lags Titan by 1-2 blocks. `vm.createSelectFork`
# refuses to fork at a future-to-the-RPC block, so cap to whatever the
# RPC currently advertises. The 1-2 block delta has no effect on the
# state Titan's override targets — Titan's stateDiff values reference
# blocks well in the past (mapping_3 freshness etc., extracted below).
RPC_LATEST=$(cast block-number --rpc-url "$ETH_RPC_URL")
if [ "$TITAN_BLOCK" -gt "$RPC_LATEST" ]; then
  echo "RPC lags Titan ($RPC_LATEST < $TITAN_BLOCK) — capping fork block to RPC head"
  TITAN_BLOCK=$RPC_LATEST
fi

echo "Titan block: $TITAN_BLOCK"

# Per venue we emit three flat arrays — storage / balance / nonce — so
# Foundry's parseJson decodes each into its matching struct array. The
# *code* override kind is intentionally skipped: Titan typically doesn't
# include code overrides for these PMMs (and if it ever does, the bash
# below would warn-and-skip; extend with `anvil_setCode`-equivalent if so).
# Fields are alphabetical so parseJson's struct-field ordering matches.

flatten_storage() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" '
    [ .result[$p].stateOverride // {}
      | to_entries[] as $a
      | ($a.value.stateDiff // {}) | to_entries[]
      | { account: $a.key, slot: .key, value: .value }
    ]'
}

# Titan emits `balance` and `nonce` as RLP-style un-padded hex
# (e.g. "0xc1ef398af17e3f", "0x2c7", "0x0"), while Foundry's `parseJson`
# decoding into a `bytes32` struct field requires a full 32-byte hex
# string. Left-pad to 64 hex chars before exporting so the Solidity-side
# `abi.decode(_, (AccountValue[]))` doesn't revert.
JQ_LPAD64='def lpad64(h):
  (h | sub("^0x"; "")) as $hex
  | ($hex | length) as $len
  | if $len >= 64 then "0x" + $hex
    else "0x" + ("0000000000000000000000000000000000000000000000000000000000000000" | .[0:(64-$len)]) + $hex
    end;'

flatten_balances() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" "$JQ_LPAD64"'
    [ .result[$p].stateOverride // {}
      | to_entries[]
      | select(.value.balance != null)
      | { account: .key, value: lpad64(.value.balance) }
    ]'
}

flatten_nonces() {
  echo "$TITAN_RESP" | jq -c --arg p "$1" "$JQ_LPAD64"'
    [ .result[$p].stateOverride // {}
      | to_entries[]
      | select(.value.nonce != null)
      | { account: .key, value: lpad64(.value.nonce) }
    ]'
}

TITAN_FERMI_STORAGE=$(flatten_storage   "$FERMI")
TITAN_FERMI_BALANCES=$(flatten_balances "$FERMI")
TITAN_FERMI_NONCES=$(flatten_nonces     "$FERMI")

TITAN_KIPSELI_STORAGE=$(flatten_storage   "$KIPSELI")
TITAN_KIPSELI_BALANCES=$(flatten_balances "$KIPSELI")
TITAN_KIPSELI_NONCES=$(flatten_nonces     "$KIPSELI")

TITAN_BEBOP_STORAGE=$(flatten_storage   "$BEBOP")
TITAN_BEBOP_BALANCES=$(flatten_balances "$BEBOP")
TITAN_BEBOP_NONCES=$(flatten_nonces     "$BEBOP")

# Bebop's maker doesn't push a price every block — at any moment Titan's
# `result.blockNumber` can lead the block stored in Bebop's freshness
# mapping (`mapping_3[0]` at slot keccak256(0,3) = 0x3617319a…) by
# hundreds of blocks. The decompiled swap-side check is
# `block.number != mapping_3[idx]` (strict equality), so Titan's Bebop
# override is only internally consistent at whatever block value
# `mapping_3[0]` stores. Extract it; the Bebop test will `vm.roll` to it.
BEBOP_FRESH_BLOCK_HEX=$(echo "$TITAN_RESP" | jq -r '
  .result["0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"]
    .stateOverride["0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"]
    .stateDiff["0x3617319a054d772f909f7c479a2cebe5066e836a939412e32403c99029b92eff"]
  // empty')
if [ -n "$BEBOP_FRESH_BLOCK_HEX" ]; then
  BEBOP_FRESH_BLOCK=$(cast to-dec "$BEBOP_FRESH_BLOCK_HEX")
else
  BEBOP_FRESH_BLOCK=$TITAN_BLOCK
fi
echo "Bebop fresh block:  $BEBOP_FRESH_BLOCK (titan block: $TITAN_BLOCK, delta: $((TITAN_BLOCK - BEBOP_FRESH_BLOCK)))"

export ETH_RPC_URL
export TITAN_BLOCK
export BEBOP_FRESH_BLOCK
export TITAN_FERMI_STORAGE TITAN_FERMI_BALANCES TITAN_FERMI_NONCES
export TITAN_KIPSELI_STORAGE TITAN_KIPSELI_BALANCES TITAN_KIPSELI_NONCES
export TITAN_BEBOP_STORAGE TITAN_BEBOP_BALANCES TITAN_BEBOP_NONCES

cd "$(dirname "$0")/.."

forge test \
  --match-contract SwapForkTest \
  --gas-report \
  -vvvv \
  "$@"
