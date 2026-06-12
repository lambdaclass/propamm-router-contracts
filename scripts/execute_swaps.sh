#!/usr/bin/env bash
#
# execute_swaps.sh — fire N $1 swaps through the PropAMM router, rotating the
# venue (BEBOP -> FERMI -> KIPSELI -> BEBOP -> ...) across calls.
#
# Each swap sells 1 USDC ($1) for WETH. The swap function depends on MODE:
#   MODE=withfee (default) -> `swapViaVenueWithFeeV1`: routes to the named venue
#     (SILENTLY falling back to Uniswap V3 if that venue reverts) and then skims a
#     frontend fee, in basis points, off the tokenOut before paying the recipient.
#   MODE=nofee             -> `swapViaVenueV1`: same venue routing + Uniswap V3
#     fallback, but NO fee skim — the recipient receives the full output.
#
# Before each swap the script QUOTES the targeted venue on-chain (router
# `quoteVenueV1`, which itself falls back to the Uniswap V3 quote if the venue
# can't be priced) and sets AMOUNT_OUT_MIN to the expected output minus
# SLIPPAGE_BPS (default 50 bps = 0.50%). `quoteVenueV1` returns the GROSS output.
# In withfee mode the fee is shaved off first to get the net and the contract then
# re-grosses the net min internally; in nofee mode the gross quote is used directly
# (no fee, no re-grossing). CAVEAT: a venue that QUOTES but does not FILL (e.g.
# FERMI RFQ) can leave the min above the Uniswap fallback's actual fill and revert.
#
# After each tx this script:
#   - decodes the `Swapped` event's `marketMaker` field to report which venue
#     actually filled (vs. fell back), plus its `amountOut` (the post-fee NET in
#     withfee mode, or the full output in nofee mode, that the recipient received);
#   - (withfee mode only) decodes the `FrontendFeeCharged` event's `feeAmount`,
#     RECONSTRUCTS the gross output (net + fee) and recomputes
#     floor(gross * bps / 10_000) to CHECK the on-chain fee (OK / MISMATCH);
#   - reads the landing block's `extraData` to report which builder
#     (Titan / Quasar / BuilderNet) built that block.
#
# Usage:
#   ETH_RPC_URL=<rpc> PK=<priv-key> ./scripts/execute_swaps.sh <num_swaps> [venue]
#
# With no <venue>, the script round-robins BEBOP -> FERMI -> KIPSELI across the
# N swaps. Pass a venue name (e.g. FERMI, case-insensitive) to force ALL N swaps
# at that single venue instead.
#
# Examples:
#   # 3 swaps, default mode (withfee, 0.50% fee), venues round-robin BEBOP -> FERMI -> KIPSELI:
#   ETH_RPC_URL=https://mainnet.infura.io/v3/<key> PK=0x... ./scripts/execute_swaps.sh 3
#
#   # 10 swaps, all forced through FERMI (venue arg is case-insensitive):
#   ETH_RPC_URL=... PK=... ./scripts/execute_swaps.sh 10 fermi
#
#   # No frontend fee (swapViaVenueV1) — recipient receives the full output:
#   MODE=nofee ETH_RPC_URL=... PK=... ./scripts/execute_swaps.sh 5
#
#   # 25 bps fee paid to a dedicated fee wallet, tighter 10 bps slippage, all via BEBOP:
#   FEE_BPS=25 FEE_RECIPIENT=0x... SLIPPAGE_BPS=10 ETH_RPC_URL=... PK=... ./scripts/execute_swaps.sh 6 bebop
#
#   # Only send when gas is cheap: hold each tx until basefee <= 1 gwei (polls 12s x 150, ~30 min max):
#   BASEFEE_MAX_GWEI=1 ETH_RPC_URL=... PK=... ./scripts/execute_swaps.sh 3
#
#   # Different pair/size: sell 0.001 WETH per swap for USDC. AMOUNT_IN is in tokenIn BASE
#   # UNITS — always re-size it when overriding TOKEN_IN (the 1000000 default is 6-dec USDC):
#   TOKEN_IN=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
#   TOKEN_OUT=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
#   AMOUNT_IN=1000000000000000 ETH_RPC_URL=... PK=... ./scripts/execute_swaps.sh 2
#
#   # Swaps broadcasting but timing out unmined? raise the tip and/or extend the receipt wait:
#   PRIORITY_GWEI=0.5 RECEIPT_TRIES=300 ETH_RPC_URL=... PK=... ./scripts/execute_swaps.sh 3
#
# Env:
#   ETH_RPC_URL   (required) JSON-RPC endpoint.
#   PK            (required) sender private key (0x...).
#   MODE          (optional) withfee (default, swapViaVenueWithFeeV1) | nofee (swapViaVenueV1, no fee skim).
#   RECIPIENT     (optional) who receives the tokenOut; defaults to PK's address.
#   AMOUNT_IN     (optional) tokenIn units to sell per swap; default 1000000 (1 USDC).
#   TOKEN_IN      (optional) default USDC.
#   TOKEN_OUT     (optional) default WETH.
#   FEE_BPS       (optional) frontend fee in basis points, 0..100; default 50 (0.50%). Ignored when MODE=nofee.
#   FEE_RECIPIENT (optional) address that receives the fee; defaults to PK's address. Ignored when MODE=nofee.
#   SLIPPAGE_BPS  (optional) slippage tolerance for AMOUNT_OUT_MIN, 0..10000; default 50 (0.50%).
#   PRIORITY_GWEI (optional) maxPriorityFeePerGas (the tip) in gwei; default 0.05.
#                 This is the only per-gas component you choose — you pay
#                 basefee + tip, never maxFee. RPC fee suggestions are often
#                 1-2 gwei, 20-40x more than non-urgent txs need. If swaps
#                 start timing out unmined, raise this (or RECEIPT_TRIES).
#   MAX_FEE_GWEI  (optional) absolute maxFeePerGas in gwei. Default: 2*basefee
#                 + tip, recomputed right before each tx (headroom for basefee
#                 spikes while pending — it does NOT raise what you pay). Set
#                 it to hard-cap a tx's price; if basefee exceeds it the tx
#                 sits in the mempool until basefee drops.
#   BASEFEE_MAX_GWEI (optional) cheap-gas gate: before each tx, wait until the
#                 basefee is at or below this many gwei (poll every
#                 GAS_WAIT_SECS=12s, up to GAS_WAIT_TRIES=150 ~= 30 min, then
#                 send anyway with a warning). Unset = no gating.
#   GAS_LIMIT     (optional) explicit gas cap passed to every tx (estimation is
#                 deliberately skipped — see below); default 1000000. Cap only:
#                 you pay for gas actually used.
#   RECEIPT_TRIES / RECEIPT_WAIT_SECS (optional) receipt polls per tx and the
#                 seconds between polls; default 60 x 2s = 120s max wait. A tx
#                 unmined after that is reported FAILED but may STILL land later
#                 (the deadline allows 1h) — check the printed tx hash before
#                 re-running.
#   GAS_WAIT_SECS / GAS_WAIT_TRIES (optional) basefee-gate poll interval and max
#                 polls; default 12s x 150 (~30 min). Used only when
#                 BASEFEE_MAX_GWEI is set.
#
# The ERC20 approve is skipped entirely when the router's current allowance
# already covers the batch, saving one tx per run.
#
# Receipt decoding requires `jq` (and `bc` for the fee-math check). The slippage
# min uses `bc` when present and falls back to 64-bit shell arithmetic otherwise.
# Without jq the script still runs and prints the raw receipt JSON instead of
# the verdict.
set -euo pipefail

# --- helpers ----------------------------------------------------------------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# hex (0x..) -> decimal; cast first, printf fallback for <2^63 values.
hex2dec() {
  local h="$1"
  [[ -z "$h" || "$h" == "-" ]] && { printf '0'; return; }
  cast to-dec "$h" 2>/dev/null || printf '%d' "$h" 2>/dev/null || printf '0'
}

# extraData hex (0x..) -> printable-ASCII graffiti, trimmed. Byte-safe: it strips
# non-ASCII (Quasar wraps its tag in a ✨ emoji) and binary RLP (vanilla geth
# blocks) instead of erroring like `cast to-ascii` does.
decode_extra() {
  local h="${1#0x}"
  [[ -z "$h" || "$h" == "-" ]] && return
  local raw
  if command -v xxd >/dev/null 2>&1; then
    raw=$(printf '%s' "$h" | xxd -r -p 2>/dev/null | LC_ALL=C tr -cd '\40-\176' 2>/dev/null)
  else
    raw=$(cast to-ascii "0x$h" 2>/dev/null | LC_ALL=C tr -cd '\40-\176' 2>/dev/null)
  fi
  printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Classify decoded extraData into the builder that produced the block. Known
# builders self-identify (Titan/Quasar/BuilderNet); anything else is "other"
# (graffiti is shown raw by the caller) and empty extraData is "unknown".
classify_builder() {
  case "$(lc "$1")" in
    *titan*)      printf 'Titan' ;;
    *quasar*)     printf 'Quasar' ;;
    *buildernet*) printf 'BuilderNet' ;;
    "")           printf 'unknown' ;;
    *)            printf 'other' ;;
  esac
}

# rule a divider line
hr() { printf '%s\n' "------------------------------------------------------------"; }

# floor(a * b / c). Uses bc (arbitrary precision) when available so large
# 18-decimal outputs can't overflow; falls back to 64-bit shell arithmetic,
# which is exact for typical $1-sized swaps. Relies on $HAVE_BC (set below).
muldiv() {
  if [[ "${HAVE_BC:-0}" -eq 1 ]]; then
    printf '%s\n' "scale=0; $1 * $2 / $3" | bc
  else
    printf '%s' "$(( $1 * $2 / $3 ))"
  fi
}

# --- args & env -------------------------------------------------------------
NUM_SWAPS="${1:-}"
VENUE_FILTER="${2:-}"                    # optional: force all swaps at one venue
if ! [[ "$NUM_SWAPS" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: ETH_RPC_URL=<rpc> PK=<key> $0 <num_swaps> [venue]" >&2
  echo "  <num_swaps> must be a positive integer" >&2
  echo "  [venue]     optional venue name to target for every swap" >&2
  exit 1
fi
: "${ETH_RPC_URL:?set ETH_RPC_URL to the JSON-RPC endpoint}"
: "${PK:?set PK to the sender private key}"
command -v cast >/dev/null 2>&1 || { echo "error: 'cast' (foundry) not found in PATH" >&2; exit 1; }

if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi
if command -v bc >/dev/null 2>&1; then HAVE_BC=1; else HAVE_BC=0; fi

# --- swap mode --------------------------------------------------------------
# withfee (default): swapViaVenueWithFeeV1 — skims a frontend fee off tokenOut.
# nofee            : swapViaVenueV1        — no fee; recipient gets the full out.
# FEE_MODE is the single boolean every fee-specific branch below keys off of.
MODE=$(lc "${MODE:-withfee}")
case "$MODE" in
  withfee) FEE_MODE=1 ;;
  nofee)   FEE_MODE=0 ;;
  *) echo "error: MODE must be 'withfee' or 'nofee' (got '$MODE')" >&2; exit 1 ;;
esac

# --- fixed addresses (mainnet) ---------------------------------------------
ROUTER=0x4ddf368080cd7946db5b459ad591c350158175e1
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

# Venues, indexed in lockstep: VENUE_NAMES[i] lives at VENUE_ADDRS[i].
VENUE_NAMES=(BEBOP FERMI KIPSELI)
VENUE_ADDRS=(
  0xdb13ad0fcd134e9c48f2fdaea8f6751a0f5349ca
  0x5979458912F80B96d30D4220af8E2e4925A33320
  0x71e790dd841c8A9061487cb3E78C288E75cE0B3d
)
NUM_VENUES=${#VENUE_ADDRS[@]}

# Build the list of venue indices to actually fire at. With no $2 we use every
# venue (round-robin); with a $2 we restrict to that single matching venue.
ACTIVE_IDXS=()
if [[ -n "$VENUE_FILTER" ]]; then
  want=$(printf '%s' "$VENUE_FILTER" | tr '[:lower:]' '[:upper:]')
  for ((v = 0; v < NUM_VENUES; v++)); do
    if [[ "$want" == "${VENUE_NAMES[$v]}" ]]; then ACTIVE_IDXS=("$v"); break; fi
  done
  if [[ ${#ACTIVE_IDXS[@]} -eq 0 ]]; then
    echo "error: unknown venue '$VENUE_FILTER'; valid: ${VENUE_NAMES[*]}" >&2
    exit 1
  fi
else
  for ((v = 0; v < NUM_VENUES; v++)); do ACTIVE_IDXS+=("$v"); done
fi
NUM_ACTIVE=${#ACTIVE_IDXS[@]}

FILLED_COUNT=()                         # per-venue "filled as targeted" tally
for ((v = 0; v < NUM_VENUES; v++)); do FILLED_COUNT+=(0); done
FALLBACK_COUNT=0                        # filled by something other than target
FAILED_COUNT=0                          # tx reverted entirely
TOTAL_GAS_WEI=0                         # cumulative gasUsed * effectiveGasPrice (approve + swaps)
FEE_OK_COUNT=0                          # swaps whose on-chain fee matched expected
FEE_MISMATCH_COUNT=0                    # swaps whose fee did NOT match expected
FEE_TOTAL=0                             # cumulative fee skimmed (tokenOut units)
BUILD_TITAN=0                           # blocks built by each builder
BUILD_QUASAR=0
BUILD_BNET=0
BUILD_OTHER=0                           # other / unknown builder

# `Swapped` event topic0, used to find the right log in each receipt.
SWAPPED_SIG="Swapped(address,address,address,uint256,uint256,address,address)"
SWAPPED_TOPIC0=$(cast keccak "$SWAPPED_SIG")

# `FrontendFeeCharged` event topic0, used to read the skimmed fee from receipts.
# Only `feeAmount` is non-indexed, so the log's `data` is exactly that one word.
FEE_CHARGED_SIG="FrontendFeeCharged(address,address,uint256,address)"
FEE_CHARGED_TOPIC0=$(cast keccak "$FEE_CHARGED_SIG")

# Resolve a filler address to a friendly name (or the fallback label).
venue_name() {
  local addr; addr=$(lc "$1")
  local i
  for ((i = 0; i < NUM_VENUES; i++)); do
    if [[ "$addr" == "$(lc "${VENUE_ADDRS[$i]}")" ]]; then
      printf '%s' "${VENUE_NAMES[$i]}"; return
    fi
  done
  printf 'Uniswap V3 fallback'
}

# --- swap parameters --------------------------------------------------------
SENDER=$(cast wallet address --private-key "$PK")
TOKEN_IN="${TOKEN_IN:-$USDC}"
TOKEN_OUT="${TOKEN_OUT:-$WETH}"
AMOUNT_IN="${AMOUNT_IN:-1000000}"       # 1 USDC (6 decimals) == $1
# AMOUNT_OUT_MIN is no longer fixed: it is quoted + computed per swap (see loop).
RECIPIENT="${RECIPIENT:-$SENDER}"
# DEADLINE is recomputed per swap (now + 1h) — the cheap-gas gate can hold a
# swap back long enough that a single run-start deadline would expire.
TOTAL_IN=$(( AMOUNT_IN * NUM_SWAPS ))

# --- frontend fee -----------------------------------------------------------
# BPS_DENOMINATOR is shared by the slippage math in BOTH modes. The fee knobs
# below are parsed only in withfee mode; nofee mode (swapViaVenueV1) charges no
# fee, so FEE_BPS / FEE_RECIPIENT are ignored.
BPS_DENOMINATOR=10000
if [[ $FEE_MODE -eq 1 ]]; then
  # The router skims floor(grossOut * FEE_BPS / BPS_DENOMINATOR) of tokenOut to
  # FEE_RECIPIENT and pays the remainder (net) to RECIPIENT. MAX_FEE_BPS mirrors
  # PropAMMRouter (=100 => 1.00% cap).
  MAX_FEE_BPS=100
  FEE_BPS="${FEE_BPS:-50}"                # 50 bps == 0.50%
  if ! [[ "$FEE_BPS" =~ ^[0-9]+$ ]] || (( FEE_BPS > MAX_FEE_BPS )); then
    echo "error: FEE_BPS must be an integer in 0..$MAX_FEE_BPS (got '$FEE_BPS')" >&2
    exit 1
  fi
  FEE_RECIPIENT="${FEE_RECIPIENT:-$SENDER}"
  FEE_PCT=$(printf '%d.%02d' $(( FEE_BPS / 100 )) $(( FEE_BPS % 100 )))  # e.g. 50 -> 0.50
fi

# --- slippage floor ---------------------------------------------------------
# Per swap, AMOUNT_OUT_MIN = expected_out * (BPS_DENOMINATOR - SLIPPAGE_BPS) /
# BPS_DENOMINATOR. expected_out is the targeted-venue quote (gross); in withfee
# mode the FEE_BPS skim is removed first (the contract re-grosses internally), in
# nofee mode the gross quote is used directly. Default 50 bps == 0.50%.
SLIPPAGE_BPS="${SLIPPAGE_BPS:-50}"
if ! [[ "$SLIPPAGE_BPS" =~ ^[0-9]+$ ]] || (( SLIPPAGE_BPS > BPS_DENOMINATOR )); then
  echo "error: SLIPPAGE_BPS must be an integer in 0..$BPS_DENOMINATOR (got '$SLIPPAGE_BPS')" >&2
  exit 1
fi
SLIPPAGE_PCT=$(printf '%d.%02d' $(( SLIPPAGE_BPS / 100 )) $(( SLIPPAGE_BPS % 100 )))  # 50 -> 0.50

# Explicit gas limit. Passing --gas-limit makes cast SKIP eth_estimateGas, for
# two reasons: (1) a swap whose targeted venue would revert (and only then fall
# back to Uniswap V3) still broadcasts instead of failing estimation; (2) cast's
# `send` path estimates against the `pending` block, and some RPC providers can't
# run the EVM against pending — eth_estimateGas/eth_call there return
# "-32603 Internal error" even though the tx is valid against `latest`. Both the
# swaps AND the approve get --gas-limit so neither depends on pending-state
# estimation. It's a cap, not a charge: you pay only for gas actually used.
# Default 1000000.
GAS_LIMIT="${GAS_LIMIT:-1000000}"
CAST_COMMON=(--private-key "$PK" --rpc-url "$ETH_RPC_URL")

# --- gas pricing -------------------------------------------------------------
# Without explicit flags cast asks the RPC for a fee suggestion, and providers
# routinely suggest 1-2 gwei priority fees when far less gets a tx included
# within a few blocks. Price explicitly instead:
#   maxPriorityFeePerGas (tip) = PRIORITY_GWEI            (default 0.05 gwei)
#   maxFeePerGas               = 2*basefee + tip          (or MAX_FEE_GWEI)
# Under EIP-1559 the tx pays basefee + tip; maxFee is only a ceiling, so the
# 2x headroom protects against basefee spikes while pending without costing
# anything. Prices are recomputed from the latest basefee before every tx.
# As a bonus, explicit flags mean cast never calls the provider's fee-
# suggestion endpoints (the same family of calls that misbehave on `pending`).
PRIORITY_GWEI="${PRIORITY_GWEI:-0.05}"
if ! [[ "$PRIORITY_GWEI" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "error: PRIORITY_GWEI must be a decimal gwei amount (got '$PRIORITY_GWEI')" >&2
  exit 1
fi
TIP_WEI=$(cast to-wei "$PRIORITY_GWEI" gwei)

MAX_FEE_WEI=""                          # empty -> per-tx 2*basefee + tip
if [[ -n "${MAX_FEE_GWEI:-}" ]]; then
  if ! [[ "$MAX_FEE_GWEI" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "error: MAX_FEE_GWEI must be a decimal gwei amount (got '$MAX_FEE_GWEI')" >&2
    exit 1
  fi
  MAX_FEE_WEI=$(cast to-wei "$MAX_FEE_GWEI" gwei)
  if (( MAX_FEE_WEI < TIP_WEI )); then
    echo "error: MAX_FEE_GWEI ($MAX_FEE_GWEI) is below PRIORITY_GWEI ($PRIORITY_GWEI)" >&2
    exit 1
  fi
fi

BASEFEE_MAX_WEI=""                      # empty -> no cheap-gas gating
if [[ -n "${BASEFEE_MAX_GWEI:-}" ]]; then
  if ! [[ "$BASEFEE_MAX_GWEI" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "error: BASEFEE_MAX_GWEI must be a decimal gwei amount (got '$BASEFEE_MAX_GWEI')" >&2
    exit 1
  fi
  BASEFEE_MAX_WEI=$(cast to-wei "$BASEFEE_MAX_GWEI" gwei)
fi
GAS_WAIT_SECS="${GAS_WAIT_SECS:-12}"    # ~1 mainnet block per poll
GAS_WAIT_TRIES="${GAS_WAIT_TRIES:-150}" # ~30 min, then send anyway

# wei -> gwei string for display, e.g. 50000000 -> 0.05
to_gwei() { cast to-unit "$1" gwei 2>/dev/null || printf '%s wei' "$1"; }

# Refresh FEE_FLAGS from the latest basefee. On an RPC hiccup falls back to
# empty flags (cast's own pricing) rather than failing the tx. Sets PRICE_NOTE
# for the per-swap report. Expand with ${FEE_FLAGS[@]+...} (bash 3.2 + set -u).
FEE_FLAGS=()
PRICE_NOTE=""
price_tx() {
  local basefee maxfee
  basefee=$(cast basefee --rpc-url "$ETH_RPC_URL" 2>/dev/null) || basefee=""
  if ! [[ "$basefee" =~ ^[0-9]+$ ]]; then
    FEE_FLAGS=()
    PRICE_NOTE="basefee fetch failed -> cast default pricing"
    return
  fi
  if [[ -n "$MAX_FEE_WEI" ]]; then
    maxfee=$MAX_FEE_WEI
  else
    maxfee=$(( basefee * 2 + TIP_WEI ))
  fi
  FEE_FLAGS=(--gas-price "$maxfee" --priority-gas-price "$TIP_WEI")
  PRICE_NOTE="basefee $(to_gwei "$basefee") gwei | tip $PRIORITY_GWEI gwei | maxFee $(to_gwei "$maxfee") gwei (ceiling)"
}

# Cheap-gas gate: block until basefee <= BASEFEE_MAX_WEI (if set). After
# GAS_WAIT_TRIES polls give up and send anyway so the run can't hang forever.
wait_for_basefee() {
  [[ -z "$BASEFEE_MAX_WEI" ]] && return 0
  local try basefee
  for (( try = 0; try < GAS_WAIT_TRIES; try++ )); do
    basefee=$(cast basefee --rpc-url "$ETH_RPC_URL" 2>/dev/null) || basefee=""
    if [[ "$basefee" =~ ^[0-9]+$ ]] && (( basefee <= BASEFEE_MAX_WEI )); then
      return 0
    fi
    echo "   gas    : basefee $(to_gwei "${basefee:-0}") gwei > cap $BASEFEE_MAX_GWEI gwei — waiting ${GAS_WAIT_SECS}s ($(( try + 1 ))/$GAS_WAIT_TRIES)"
    sleep "$GAS_WAIT_SECS"
  done
  echo "   gas    : !! basefee still above cap after $(( GAS_WAIT_TRIES * GAS_WAIT_SECS ))s — sending anyway"
}

# a >= b for unsigned decimal strings of any size (allowances can be 2^256-1,
# which overflows 64-bit shell arithmetic). bc when present, else compare by
# length then lexicographically.
num_ge() {
  local a="$1" b="$2"
  if [[ "${HAVE_BC:-0}" -eq 1 ]]; then
    [[ "$(printf '%s >= %s\n' "$a" "$b" | bc)" == "1" ]]
  else
    while [[ ${#a} -gt 1 && "$a" == 0* ]]; do a="${a#0}"; done
    while [[ ${#b} -gt 1 && "$b" == 0* ]]; do b="${b#0}"; done
    if (( ${#a} != ${#b} )); then (( ${#a} > ${#b} )); else [[ "$a" == "$b" || "$a" > "$b" ]]; fi
  fi
}

# Broadcast a tx and wait for its receipt WITHOUT cast's built-in watcher.
# Some RPC providers (Infura) reject the watcher's polling call with
# "-32603 precondition failure" AFTER eth_sendRawTransaction already
# succeeded, so a landed tx looks failed (and a retry would double-send).
# Instead: `cast send --async` returns the hash as soon as the broadcast is
# accepted, then we poll single-shot `cast receipt --async` (a plain
# eth_getTransactionReceipt, which those providers do serve) until the tx
# mines. Prints the receipt JSON on success; same shape `cast send --json`
# would have printed.
RECEIPT_TRIES="${RECEIPT_TRIES:-60}"          # max wait = TRIES * WAIT_SECS per tx
RECEIPT_WAIT_SECS="${RECEIPT_WAIT_SECS:-2}"
send_and_wait() {
  local txhash receipt try
  txhash=$(cast send "$@" --async) || return 1
  for (( try = 0; try < RECEIPT_TRIES; try++ )); do
    receipt=$(cast receipt "$txhash" --async --json --rpc-url "$ETH_RPC_URL" 2>/dev/null) || receipt=""
    if [[ -n "$receipt" && "$receipt" != "null" ]]; then
      printf '%s\n' "$receipt"
      return 0
    fi
    sleep "$RECEIPT_WAIT_SECS"
  done
  echo "error: tx $txhash broadcast but no receipt after $(( RECEIPT_TRIES * RECEIPT_WAIT_SECS ))s" >&2
  return 1
}

# --- banner -----------------------------------------------------------------
hr
echo "PropAMM router — fire $NUM_SWAPS swap(s)"
hr
echo "  router      : $ROUTER"
echo "  rpc         : $ETH_RPC_URL"
echo "  sender      : $SENDER"
echo "  recipient   : $RECIPIENT"
echo "  tokenIn     : $TOKEN_IN"
echo "  tokenOut    : $TOKEN_OUT"
echo "  amountIn    : $AMOUNT_IN  (per swap)"
echo "  totalIn     : $TOTAL_IN  (approved once for the batch)"
echo "  deadline    : now + 3600s, set per swap"
echo "  gasLimit    : $GAS_LIMIT  (approve + swaps, estimation skipped; cap only, you pay gas used)"
if [[ -n "$MAX_FEE_WEI" ]]; then
  echo "  gasPrice    : tip $PRIORITY_GWEI gwei, maxFee $MAX_FEE_GWEI gwei (fixed ceiling; you pay basefee + tip)"
else
  echo "  gasPrice    : tip $PRIORITY_GWEI gwei, maxFee 2*basefee + tip (ceiling only; you pay basefee + tip, repriced per tx)"
fi
if [[ -n "$BASEFEE_MAX_WEI" ]]; then
  echo "  basefeeGate : wait for basefee <= $BASEFEE_MAX_GWEI gwei before each tx (poll ${GAS_WAIT_SECS}s x $GAS_WAIT_TRIES)"
fi
if [[ $FEE_MODE -eq 1 ]]; then
  echo "  mode        : $MODE  (swapViaVenueWithFeeV1)"
  echo "  slippage    : $SLIPPAGE_BPS bps (${SLIPPAGE_PCT}%)  -> AMOUNT_OUT_MIN = expected net out - slippage, quoted per swap @ targeted venue"
  echo "  feeBps      : $FEE_BPS  (${FEE_PCT}% of gross tokenOut, skimmed to feeRecipient)"
  echo "  feeRecipient: $FEE_RECIPIENT"
else
  echo "  mode        : $MODE  (swapViaVenueV1, no fee skim — recipient gets full output)"
  echo "  slippage    : $SLIPPAGE_BPS bps (${SLIPPAGE_PCT}%)  -> AMOUNT_OUT_MIN = expected out - slippage, quoted per swap @ targeted venue"
fi
if [[ -n "$VENUE_FILTER" ]]; then
  echo "  venue       : ${VENUE_NAMES[${ACTIVE_IDXS[0]}]} (forced for all swaps)"
else
  echo "  venues      : ${VENUE_NAMES[*]} (round-robin)"
fi
if [[ $HAVE_JQ -eq 0 ]]; then
  echo "  note        : jq not found -> printing raw receipts, no venue/builder report"
fi
if [[ $FEE_MODE -eq 1 && $HAVE_JQ -eq 1 && $HAVE_BC -eq 0 ]]; then
  echo "  note        : bc not found -> fee shown but not verified against expected"
fi
hr
echo

# --- approve once for the whole batch --------------------------------------
# ERC20 allowance is absolute (not additive), so one approval of totalIn
# covers every swap in this run — and if a previous run left an allowance that
# already covers it, the approve tx is skipped entirely (one tx saved).
# --gas-limit skips estimation (see GAS_LIMIT above) so the approve doesn't
# depend on the RPC estimating against pending.
allowance=$(cast call "$TOKEN_IN" "allowance(address,address)(uint256)" "$SENDER" "$ROUTER" \
  --rpc-url "$ETH_RPC_URL" 2>/dev/null | grep -oE '^[0-9]+' | head -n1 || true)
if [[ -n "$allowance" ]] && num_ge "$allowance" "$TOTAL_IN"; then
  echo ">> approve skipped: existing allowance $allowance >= $TOTAL_IN (one tx saved)"
else
  echo ">> approve $TOTAL_IN of tokenIn ($TOKEN_IN) to router"
  wait_for_basefee
  price_tx
  [[ -n "$PRICE_NOTE" ]] && echo "   gas    : $PRICE_NOTE"
  if [[ $HAVE_JQ -eq 1 ]]; then
    if APP_OUT=$(send_and_wait "$TOKEN_IN" "approve(address,uint256)" "$ROUTER" "$TOTAL_IN" \
        "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"} 2>&1); then
      app_hash=$(printf '%s' "$APP_OUT" | jq -r '.transactionHash // "-"' 2>/dev/null || echo "-")
      app_st=$(printf '%s' "$APP_OUT" | jq -r '.status // "-"' 2>/dev/null || echo "-")
      app_gas=$(hex2dec "$(printf '%s' "$APP_OUT" | jq -r '.gasUsed // "-"' 2>/dev/null || echo "-")")
      app_egp=$(hex2dec "$(printf '%s' "$APP_OUT" | jq -r '.effectiveGasPrice // "-"' 2>/dev/null || echo "-")")
      app_cost=$(( app_gas * app_egp ))
      TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + app_cost ))
      echo "   tx=$app_hash status=$app_st gasUsed=$app_gas @ $(to_gwei "$app_egp") gwei (~$(cast from-wei "$app_cost" 2>/dev/null || echo "$app_cost") ETH)"
    else
      echo "   approve FAILED:" >&2
      printf '%s\n' "$APP_OUT" >&2
      exit 1
    fi
  else
    send_and_wait "$TOKEN_IN" "approve(address,uint256)" "$ROUTER" "$TOTAL_IN" \
      "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"}
  fi
fi
echo

# --- fire the swaps ---------------------------------------------------------
for (( i = 0; i < NUM_SWAPS; i++ )); do
  idx=${ACTIVE_IDXS[$(( i % NUM_ACTIVE ))]}
  venue="${VENUE_ADDRS[$idx]}"
  name="${VENUE_NAMES[$idx]}"

  hr
  echo "swap $(( i + 1 ))/$NUM_SWAPS  ->  target venue: $name ($venue)"
  DEADLINE=$(( $(date +%s) + 3600 ))    # per-swap: gating can delay broadcasts

  # --- per-swap slippage floor ---------------------------------------------
  # Quote the TARGETED venue on-chain (eth_call, no gas). quoteVenueV1 returns
  # the GROSS output and gracefully reprices via Uniswap V3 if the venue can't
  # be priced. In withfee mode we shave FEE_BPS off to get the expected NET, then
  # subtract SLIPPAGE_BPS -> AMOUNT_OUT_MIN (a NET min; the router re-grosses it).
  # In nofee mode there is no fee: subtract SLIPPAGE_BPS off the gross quote
  # directly (swapViaVenueV1 compares the floor against the raw delivered output).
  AMOUNT_OUT_MIN=0
  q_raw=$( { cast call "$ROUTER" \
      "quoteVenueV1(address,address,address,uint256)(uint256,address)" \
      "$venue" "$TOKEN_IN" "$TOKEN_OUT" "$AMOUNT_IN" --rpc-url "$ETH_RPC_URL" 2>/dev/null || true; } )
  { read -r q_line1; read -r q_line2; } < <(printf '%s\n' "$q_raw") || true
  expected_gross=$(printf '%s' "${q_line1:-}" | grep -oE '^[0-9]+' || true)
  quoted_addr=$(printf '%s' "${q_line2:-}" | grep -oiE '0x[0-9a-f]{40}' || true)

  if [[ -n "$expected_gross" && "$expected_gross" != "0" ]]; then
    if [[ $FEE_MODE -eq 1 ]]; then
      expected_out=$(muldiv "$expected_gross" "$(( BPS_DENOMINATOR - FEE_BPS ))" "$BPS_DENOMINATOR")
    else
      expected_out="$expected_gross"
    fi
    AMOUNT_OUT_MIN=$(muldiv "$expected_out" "$(( BPS_DENOMINATOR - SLIPPAGE_BPS ))" "$BPS_DENOMINATOR")
    eg_eth=$(cast from-wei "$expected_gross" 2>/dev/null || echo "$expected_gross")
    min_eth=$(cast from-wei "$AMOUNT_OUT_MIN" 2>/dev/null || echo "$AMOUNT_OUT_MIN")
    echo "   quote  : $expected_gross gross tokenOut (~$eg_eth if 18-dec)  [quoteVenueV1 -> $(venue_name "${quoted_addr:-}")]"
    if [[ $FEE_MODE -eq 1 ]]; then
      echo "   minOut : $AMOUNT_OUT_MIN net tokenOut (~$min_eth if 18-dec)  [expected net - ${SLIPPAGE_PCT}% slippage]"
    else
      echo "   minOut : $AMOUNT_OUT_MIN tokenOut (~$min_eth if 18-dec)  [expected out - ${SLIPPAGE_PCT}% slippage]"
    fi
  else
    echo "   minOut : !!  quote failed -> AMOUNT_OUT_MIN=0 (NO slippage protection on this swap)"
  fi

  # Gate on cheap basefee (if configured), then reprice from the basefee NOW —
  # quoting above may have taken a while and basefee moves up to 12.5%/block.
  wait_for_basefee
  price_tx
  [[ -n "$PRICE_NOTE" ]] && echo "   gas    : $PRICE_NOTE"

  # Build the swap call for the selected MODE. withfee appends the frontend-fee
  # tuple (uint16 bps, address recipient); nofee uses the plain swapViaVenueV1.
  if [[ $FEE_MODE -eq 1 ]]; then
    SWAP_ARGS=(
      "$ROUTER"
      "swapViaVenueWithFeeV1(address,address,address,uint256,uint256,address,uint256,(uint16,address))"
      "$venue" "$TOKEN_IN" "$TOKEN_OUT" "$AMOUNT_IN" "$AMOUNT_OUT_MIN" "$RECIPIENT" "$DEADLINE"
      "($FEE_BPS,$FEE_RECIPIENT)"
      "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"}
    )
  else
    SWAP_ARGS=(
      "$ROUTER"
      "swapViaVenueV1(address,address,address,uint256,uint256,address,uint256)"
      "$venue" "$TOKEN_IN" "$TOKEN_OUT" "$AMOUNT_IN" "$AMOUNT_OUT_MIN" "$RECIPIENT" "$DEADLINE"
      "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"}
    )
  fi

  if [[ $HAVE_JQ -eq 0 ]]; then
    # No jq: just run it and print the raw receipt JSON.
    send_and_wait "${SWAP_ARGS[@]}" || { echo "   tx FAILED"; FAILED_COUNT=$((FAILED_COUNT + 1)); }
    echo
    continue
  fi

  # With jq: capture the JSON receipt and decode it.
  if ! OUT=$(send_and_wait "${SWAP_ARGS[@]}" 2>&1); then
    echo "   tx FAILED (reverted / not mined):"
    printf '%s\n' "$OUT" | sed 's/^/     /'
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi

  # Pull tx hash, status, gas, effective gas price, block number, and the
  # Swapped log's data in one jq pass.
  txhash="-"; status="-"; gasHex="-"; egpHex="-"; blkHex="-"; data="-"; feedata="-"
  read -r txhash status gasHex egpHex blkHex data feedata < <(
    printf '%s' "$OUT" | jq -r \
      --arg sel "$SWAPPED_TOPIC0" --arg feeSel "$FEE_CHARGED_TOPIC0" --arg router "$ROUTER" '
      ([ .logs[]?
         | select((.address//""|ascii_downcase) == ($router|ascii_downcase))
         | select(((.topics[0]//"")|ascii_downcase) == ($sel|ascii_downcase))
         | .data ][0] // "-") as $d
      | ([ .logs[]?
         | select((.address//""|ascii_downcase) == ($router|ascii_downcase))
         | select(((.topics[0]//"")|ascii_downcase) == ($feeSel|ascii_downcase))
         | .data ][0] // "-") as $f
      | [(.transactionHash//"-"), (.status//"-"), (.gasUsed//"-"), (.effectiveGasPrice//"-"), (.blockNumber//"-"), $d, $f] | @tsv
    ' 2>/dev/null
  ) || true

  gas=$(hex2dec "$gasHex")
  egp=$(hex2dec "$egpHex")               # what the tx actually paid per gas
  cost=$(( gas * egp ))
  TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + cost ))
  [[ "$status" == "0x1" ]] && st="success" || st="FAILED"

  echo "   tx     : $txhash"
  echo "   status : $st   gasUsed: $gas @ $(to_gwei "$egp") gwei (~$(cast from-wei "$cost" 2>/dev/null || echo "$cost") ETH)"

  if [[ "$st" == "FAILED" ]]; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi

  # Which builder built the block this swap landed in? Builders self-identify in
  # the block header's extraData; fetch it and classify (Titan/Quasar/BuilderNet).
  blk=$(hex2dec "$blkHex")
  ed=$(cast block "$blk" --json --rpc-url "$ETH_RPC_URL" 2>/dev/null | jq -r '.extraData // "-"' 2>/dev/null || echo "-")
  graffiti=$(decode_extra "$ed")
  blabel=$(classify_builder "$graffiti")
  case "$blabel" in
    Titan)      BUILD_TITAN=$((BUILD_TITAN + 1)) ;;
    Quasar)     BUILD_QUASAR=$((BUILD_QUASAR + 1)) ;;
    BuilderNet) BUILD_BNET=$((BUILD_BNET + 1)) ;;
    *)          BUILD_OTHER=$((BUILD_OTHER + 1)) ;;
  esac
  echo "   block  : $blk"
  echo "   builder: $blabel   [${graffiti:-<no extraData tag>}]"

  if [[ "$data" == "-" || ${#data} -lt 42 ]]; then
    echo "   warn   : no Swapped event found in receipt; cannot verify venue"
    echo
    continue
  fi

  d="${data#0x}"
  mm="0x${d: -40}"                       # marketMaker = last word, low 20 bytes
  ao=$(hex2dec "0x${d:64:64}")           # amountOut = 2nd word; NET (post-fee) in withfee, full out in nofee
  ao_eth=$(cast from-wei "$ao" 2>/dev/null || echo "$ao")
  filler=$(venue_name "$mm")

  if [[ "$(lc "$mm")" == "$(lc "$venue")" ]]; then
    echo "   filled : OK  via $name  ($mm)"
    FILLED_COUNT[$idx]=$(( ${FILLED_COUNT[$idx]} + 1 ))
  else
    echo "   filled : !!  target $name did NOT fill -> $filler ($mm)"
    FALLBACK_COUNT=$((FALLBACK_COUNT + 1))
  fi
  # nofee mode (swapViaVenueV1) emits no FrontendFeeCharged: amountOut is the full
  # output the recipient received, so report it and skip the fee reconstruction.
  if [[ $FEE_MODE -eq 0 ]]; then
    echo "   out    : $ao tokenOut units (~$ao_eth if 18-dec)  [recipient receives this — no fee]"
    echo
    continue
  fi
  echo "   net    : $ao tokenOut units (~$ao_eth if 18-dec)  [recipient receives this]"

  # --- fee check: reconstruct gross = net + fee, recompute the expected skim
  # floor(gross * FEE_BPS / BPS_DENOMINATOR), and compare it to the on-chain fee.
  if [[ "$feedata" == "-" || ${#feedata} -lt 2 ]]; then
    if (( FEE_BPS == 0 )); then
      echo "   fee    : none (FEE_BPS=0, no FrontendFeeCharged expected)"
    else
      echo "   fee    : !!  expected ${FEE_PCT}% skim but no FrontendFeeCharged event found"
      FEE_MISMATCH_COUNT=$((FEE_MISMATCH_COUNT + 1))
    fi
    echo
    continue
  fi

  fee=$(hex2dec "$feedata")              # actual feeAmount skimmed on-chain
  fee_eth=$(cast from-wei "$fee" 2>/dev/null || echo "$fee")
  if [[ $HAVE_BC -eq 0 ]]; then
    echo "   fee    : $fee tokenOut units (~$fee_eth if 18-dec)  [install bc to verify the math]"
    echo
    continue
  fi

  gross=$(echo "$ao + $fee" | bc)                                       # delivered, pre-skim
  expected=$(echo "scale=0; $gross * $FEE_BPS / $BPS_DENOMINATOR" | bc) # floor; mirrors _feeAmount
  FEE_TOTAL=$(echo "$FEE_TOTAL + $fee" | bc)
  echo "   gross  : $gross tokenOut units (net + fee, reconstructed)"
  if [[ "$fee" == "$expected" ]]; then
    echo "   fee    : OK  $fee == floor($gross * $FEE_BPS / $BPS_DENOMINATOR)  (~$fee_eth if 18-dec)"
    FEE_OK_COUNT=$((FEE_OK_COUNT + 1))
  else
    echo "   fee    : MISMATCH  on-chain=$fee  expected=$expected  (gross=$gross bps=$FEE_BPS)"
    FEE_MISMATCH_COUNT=$((FEE_MISMATCH_COUNT + 1))
  fi
  echo
done

# --- summary ----------------------------------------------------------------
hr
echo "Summary"
hr
if [[ $HAVE_JQ -eq 1 ]]; then
  for v in "${ACTIVE_IDXS[@]}"; do
    echo "  ${VENUE_NAMES[$v]} filled as targeted : ${FILLED_COUNT[$v]}"
  done
  echo "  fell back to other venue   : $FALLBACK_COUNT"
  if [[ $FEE_MODE -eq 1 ]]; then
    echo "  --- frontend fee (${FEE_PCT}%) ---"
    echo "  fee matched expected       : $FEE_OK_COUNT"
    echo "  fee MISMATCH               : $FEE_MISMATCH_COUNT"
    fee_total_eth=$(cast from-wei "$FEE_TOTAL" 2>/dev/null || echo "$FEE_TOTAL")
    echo "  total fee skimmed          : $FEE_TOTAL tokenOut units (~$fee_total_eth if 18-dec)"
  fi
  echo "  --- blocks built by ---"
  echo "  Titan                      : $BUILD_TITAN"
  echo "  Quasar                     : $BUILD_QUASAR"
  echo "  BuilderNet                 : $BUILD_BNET"
  echo "  other / unknown            : $BUILD_OTHER"
fi
if [[ $HAVE_JQ -eq 1 ]]; then
  echo "  total gas paid             : $TOTAL_GAS_WEI wei (~$(cast from-wei "$TOTAL_GAS_WEI" 2>/dev/null || echo "$TOTAL_GAS_WEI") ETH, approve + swaps)"
fi
echo "  failed / reverted txs      : $FAILED_COUNT"
echo "  total submitted            : $NUM_SWAPS"
