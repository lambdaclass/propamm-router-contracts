#!/usr/bin/env bash
#
# execute_direct_swaps.sh — fire N $1 swaps DIRECTLY at each propAMM venue
# (KIPSELI -> FERMI -> KIPSELI -> ...), bypassing the PropAMM router entirely.
#
# Unlike execute_swaps.sh there is NO Uniswap V3 fallback and NO frontend fee:
# a venue that cannot fill is skipped (before any funds move) or the tx simply
# fails. Each venue is reached through its own native interface:
#
#   FERMI  (single tx, pull-payment)
#     `fermiSwapWithAllowances(tokenIn, tokenOut, int256(amountIn), minOut,
#     recipient)` pulls tokenIn via allowance, so the script approves the
#     venue ONCE for the run's planned Fermi total (the allowance self-depletes
#     to ~0 when every planned Fermi swap executes). Atomic: a failure just
#     reverts, nothing can get stranded.
#
#   KIPSELI (two txs, push-payment — it only implements `IPropAMM`)
#     tx A: ERC20.transfer(KIPSELI, amountIn)        <- funds pushed first
#     tx B: swap(tokenIn, tokenOut, amountIn, minOut, recipient, deadline)
#     Both are broadcast back-to-back with explicit sequential nonces (no wait
#     between broadcasts) so they normally land adjacent in the same block,
#     minimizing the non-atomic window. CAVEAT: if tx A mines but tx B reverts
#     or never mines, amountIn is STRANDED on the venue — the script reports
#     this loudly and tallies it, but cannot recover the funds.
#
# Before any funds move, each swap gates on the venue's `isActive(tokenIn,
# tokenOut)` view: if inactive (e.g. Kipseli reverts `StaleUpdate()` whenever
# its PrioUpdateRegistry price lane is stale), the script polls every
# ACTIVE_POLL_SECS up to ACTIVE_WAIT_SECS, then SKIPS that swap with a warning
# and moves on. It then quotes the venue directly (`IPropAMM.quote` via
# eth_call) and sets AMOUNT_OUT_MIN to the quote minus SLIPPAGE_BPS (default
# 50 bps). A failed quote also skips the swap: with no fallback there is no
# reason to push funds (Kipseli) or burn gas (Fermi) on a doomed fill.
# Kipseli's quote is a simulated swap that pulls tokenIn from the CALLER, so
# it is quoted `--from` the sender, which actually holds the funds (this is
# the very reason the router can never auto-select Kipseli; direct quoting
# should fare better, but is only verifiable while Kipseli's lane is fresh).
#
# A one-shot preflight also checks the sender's tokenIn balance: the run
# aborts if it cannot fund even a single swap, and warns (but proceeds) if it
# covers only part of the plan.
#
# After each swap this script:
#   - decodes amountOut venue-agnostically as the sum of the receipt's ERC20
#     `Transfer` logs on tokenOut paying RECIPIENT, and cross-checks the
#     venue's own `Swapped` event when one is present;
#   - reads the landing block's `extraData` to report which builder
#     (Titan / Quasar / BuilderNet) built that block.
#
# Usage:
#   ETH_RPC_URL=<rpc> PK=<priv-key> ./scripts/execute_direct_swaps.sh <num_swaps> [venue]
#
# With no <venue>, the script round-robins KIPSELI -> FERMI across the N
# swaps. Pass a venue name (e.g. FERMI, case-insensitive) to force ALL N
# swaps at that single venue instead.
#
# Examples:
#   # 4 swaps alternating KIPSELI -> FERMI:
#   ETH_RPC_URL=https://mainnet.infura.io/v3/<key> PK=0x... ./scripts/execute_direct_swaps.sh 4
#
#   # 10 swaps, all directly at FERMI:
#   ETH_RPC_URL=... PK=... ./scripts/execute_direct_swaps.sh 10 fermi
#
#   # Give Kipseli's price updater up to 5 minutes to refresh before skipping:
#   ACTIVE_WAIT_SECS=300 ETH_RPC_URL=... PK=... ./scripts/execute_direct_swaps.sh 2 kipseli
#
#   # Sell $5 per swap to a separate recipient, with a tighter 0.10% floor:
#   AMOUNT_IN=5000000 RECIPIENT=0xYourColdWallet... SLIPPAGE_BPS=10 \
#     ETH_RPC_URL=... PK=... ./scripts/execute_direct_swaps.sh 6
#
#   # Patient overnight run: each swap waits (up to 30 min) for basefee <= 1
#   # gwei before firing, and reprices off the basefee it eventually sees:
#   BASEFEE_MAX_GWEI=1 ETH_RPC_URL=... PK=... ./scripts/execute_direct_swaps.sh 8
#
#   # Reverse pair (sell 0.001 WETH per swap for USDC at Fermi only — amounts
#   # are raw token units, so 0.001 WETH = 1e15):
#   TOKEN_IN=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
#   TOKEN_OUT=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
#   AMOUNT_IN=1000000000000000 \
#     ETH_RPC_URL=... PK=... ./scripts/execute_direct_swaps.sh 2 fermi
#
# Env:
#   ETH_RPC_URL   (required) JSON-RPC endpoint.
#   PK            (required) sender private key (0x...).
#   RECIPIENT     (optional) who receives the tokenOut; defaults to PK's address.
#   AMOUNT_IN     (optional) tokenIn units to sell per swap; default 1000000 (1 USDC).
#   TOKEN_IN      (optional) default USDC.
#   TOKEN_OUT     (optional) default WETH.
#   SLIPPAGE_BPS  (optional) slippage tolerance for AMOUNT_OUT_MIN, 0..10000; default 50 (0.50%).
#   ACTIVE_WAIT_SECS (optional) max seconds to wait for an inactive venue to
#                 become active before skipping the swap; default 60.
#   ACTIVE_POLL_SECS (optional) seconds between isActive polls; default 5.
#   PRIORITY_GWEI / MAX_FEE_GWEI / BASEFEE_MAX_GWEI / GAS_WAIT_SECS /
#   GAS_WAIT_TRIES — gas pricing & cheap-gas gating, same semantics as
#                 execute_swaps.sh (tip default 0.05 gwei; maxFee default
#                 2*basefee + tip recomputed per tx; optional basefee gate).
#   GAS_LIMIT     (optional) gas cap for swap + approve txs (estimation is
#                 deliberately skipped, see execute_swaps.sh); default 1000000.
#   TRANSFER_GAS_LIMIT (optional) gas cap for Kipseli's push transfer tx;
#                 default 120000. Caps only: you pay for gas actually used.
#   RECEIPT_TRIES / RECEIPT_WAIT_SECS (optional) receipt polls per tx and the
#                 seconds between polls; default 60 x 2s = 120s max wait.
#
# Receipt decoding requires `jq` (and `bc` improves big-number math). Without
# jq the script still runs and prints raw receipt JSON instead of the verdict.
set -euo pipefail

# --- helpers ----------------------------------------------------------------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# hex (0x..) -> decimal; cast first, printf fallback for <2^63 values.
hex2dec() {
  local h="$1"
  [[ -z "$h" || "$h" == "-" ]] && { printf '0'; return; }
  cast to-dec "$h" 2>/dev/null || printf '%d' "$h" 2>/dev/null || printf '0'
}

# extraData hex (0x..) -> printable-ASCII graffiti, trimmed. Byte-safe: strips
# non-ASCII (Quasar wraps its tag in an emoji) and binary RLP instead of
# erroring like `cast to-ascii` does.
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

# Classify decoded extraData into the builder that produced the block.
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

# floor(a * b / c). bc when available (no 64-bit overflow on 18-dec outputs);
# 64-bit shell arithmetic fallback, exact for typical $1-sized swaps.
muldiv() {
  if [[ "${HAVE_BC:-0}" -eq 1 ]]; then
    printf '%s\n' "scale=0; $1 * $2 / $3" | bc
  else
    printf '%s' "$(( $1 * $2 / $3 ))"
  fi
}

# a >= b for unsigned decimal strings of any size (allowances can be 2^256-1).
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

# --- args & env -------------------------------------------------------------
NUM_SWAPS="${1:-}"
VENUE_FILTER="${2:-}"                    # optional: force all swaps at one venue
if ! [[ "$NUM_SWAPS" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: ETH_RPC_URL=<rpc> PK=<key> $0 <num_swaps> [venue]" >&2
  echo "  <num_swaps> must be a positive integer" >&2
  echo "  [venue]     optional venue name (KIPSELI or FERMI) to target for every swap" >&2
  exit 1
fi
: "${ETH_RPC_URL:?set ETH_RPC_URL to the JSON-RPC endpoint}"
: "${PK:?set PK to the sender private key}"
command -v cast >/dev/null 2>&1 || { echo "error: 'cast' (foundry) not found in PATH" >&2; exit 1; }

if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi
if command -v bc >/dev/null 2>&1; then HAVE_BC=1; else HAVE_BC=0; fi

# --- fixed addresses (mainnet) ---------------------------------------------
# Current-generation venues — the same addresses whitelisted on the deployed
# router and used by execute_swaps.sh / the fork tests. NOT the older bespoke
# deployments listed in the README's Titan-override table.
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

# Venues, indexed in lockstep: VENUE_NAMES[i] lives at VENUE_ADDRS[i].
# KIPSELI speaks IPropAMM only (push-payment); FERMI is hit through its
# bespoke single-tx pull interface.
VENUE_NAMES=(KIPSELI FERMI)
VENUE_ADDRS=(
  0x71e790dd841c8A9061487cb3E78C288E75cE0B3d
  0x5979458912F80B96d30D4220af8E2e4925A33320
)
NUM_VENUES=${#VENUE_ADDRS[@]}
FERMI_NAME=FERMI                         # the pull-payment special case below keys off this

# Build the list of venue indices to actually fire at.
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

FILLED_COUNT=()                         # per-venue successful direct fills
SKIPPED_COUNT=()                        # per-venue skips (inactive / quote failed)
for ((v = 0; v < NUM_VENUES; v++)); do FILLED_COUNT+=(0); SKIPPED_COUNT+=(0); done
FAILED_COUNT=0                          # tx reverted / unmined (nothing stranded)
STRANDED_COUNT=0                        # Kipseli pushes whose swap didn't fill
STRANDED_TOTAL=0                        # cumulative stranded tokenIn units
TOTAL_GAS_WEI=0                         # cumulative gasUsed * effectiveGasPrice
BUILD_TITAN=0
BUILD_QUASAR=0
BUILD_BNET=0
BUILD_OTHER=0

# `IPropAMM.Swapped` topic0 (the VENUE's event — sender/tokenIn/tokenOut are
# indexed, so data = [amountIn, amountOut, recipient]). Note this differs from
# the router's 7-field Swapped event decoded by execute_swaps.sh.
SWAPPED_SIG="Swapped(address,address,address,uint256,uint256,address)"
SWAPPED_TOPIC0=$(cast keccak "$SWAPPED_SIG")

# ERC20 `Transfer` topic0, for the venue-agnostic amountOut decode.
TRANSFER_TOPIC0=$(cast keccak "Transfer(address,address,uint256)")

# --- swap parameters --------------------------------------------------------
SENDER=$(cast wallet address --private-key "$PK")
TOKEN_IN="${TOKEN_IN:-$USDC}"
TOKEN_OUT="${TOKEN_OUT:-$WETH}"
AMOUNT_IN="${AMOUNT_IN:-1000000}"       # 1 USDC (6 decimals) == $1
RECIPIENT="${RECIPIENT:-$SENDER}"
if ! [[ "$AMOUNT_IN" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: AMOUNT_IN must be a positive integer in raw tokenIn units (got '$AMOUNT_IN')" >&2
  exit 1
fi
# Malformed addresses would otherwise surface late (cast errors mid-run) or —
# worse, for RECIPIENT — silently break the Transfer-log topic match below and
# report out=0 on a swap that actually filled.
for pair in "TOKEN_IN=$TOKEN_IN" "TOKEN_OUT=$TOKEN_OUT" "RECIPIENT=$RECIPIENT"; do
  if ! [[ "${pair#*=}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "error: ${pair%%=*} must be a 0x-prefixed 20-byte address (got '${pair#*=}')" >&2
    exit 1
  fi
done
# Transfer logs index `to` as a 32-byte topic; precompute RECIPIENT's form.
RECIPIENT_TOPIC="0x000000000000000000000000$(lc "${RECIPIENT#0x}")"

# Planned per-venue swap counts (the plan is fixed up front; skips don't
# reshuffle it). FERMI's count sizes the one-shot allowance below.
PLANNED_COUNT=()
for ((v = 0; v < NUM_VENUES; v++)); do PLANNED_COUNT+=(0); done
for (( i = 0; i < NUM_SWAPS; i++ )); do
  idx=${ACTIVE_IDXS[$(( i % NUM_ACTIVE ))]}
  PLANNED_COUNT[$idx]=$(( ${PLANNED_COUNT[$idx]} + 1 ))
done
FERMI_IDX=-1
for ((v = 0; v < NUM_VENUES; v++)); do
  [[ "${VENUE_NAMES[$v]}" == "$FERMI_NAME" ]] && FERMI_IDX=$v
done
FERMI_PLANNED=0
[[ $FERMI_IDX -ge 0 ]] && FERMI_PLANNED=${PLANNED_COUNT[$FERMI_IDX]}
# muldiv (bc-backed): AMOUNT_IN * count overflows 64-bit shell arithmetic for
# 18-dec tokens (e.g. 10 x 1e18), which would yield a garbage allowance.
FERMI_TOTAL_IN=$(muldiv "$AMOUNT_IN" "$FERMI_PLANNED" 1)

# --- slippage floor ---------------------------------------------------------
# Per swap, AMOUNT_OUT_MIN = quote * (BPS_DENOMINATOR - SLIPPAGE_BPS) /
# BPS_DENOMINATOR. There is no fee skim at the venue level, so the quote is
# used directly. Default 50 bps == 0.50%.
BPS_DENOMINATOR=10000
SLIPPAGE_BPS="${SLIPPAGE_BPS:-50}"
if ! [[ "$SLIPPAGE_BPS" =~ ^[0-9]+$ ]] || (( SLIPPAGE_BPS > BPS_DENOMINATOR )); then
  echo "error: SLIPPAGE_BPS must be an integer in 0..$BPS_DENOMINATOR (got '$SLIPPAGE_BPS')" >&2
  exit 1
fi
SLIPPAGE_PCT=$(printf '%d.%02d' $(( SLIPPAGE_BPS / 100 )) $(( SLIPPAGE_BPS % 100 )))

# --- isActive gate ----------------------------------------------------------
ACTIVE_WAIT_SECS="${ACTIVE_WAIT_SECS:-60}"
ACTIVE_POLL_SECS="${ACTIVE_POLL_SECS:-5}"
if ! [[ "$ACTIVE_WAIT_SECS" =~ ^[0-9]+$ && "$ACTIVE_POLL_SECS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: ACTIVE_WAIT_SECS / ACTIVE_POLL_SECS must be non-negative / positive integers" >&2
  exit 1
fi

# Explicit gas limits: passing --gas-limit makes cast SKIP eth_estimateGas
# (some RPC providers can't run the EVM against `pending` and return -32603 on
# estimation even for valid txs; see execute_swaps.sh for the full story).
# Caps only: you pay for gas actually used.
GAS_LIMIT="${GAS_LIMIT:-1000000}"
TRANSFER_GAS_LIMIT="${TRANSFER_GAS_LIMIT:-120000}"
CAST_COMMON=(--private-key "$PK" --rpc-url "$ETH_RPC_URL")

# --- gas pricing (same scheme as execute_swaps.sh) ---------------------------
#   maxPriorityFeePerGas (tip) = PRIORITY_GWEI            (default 0.05 gwei)
#   maxFeePerGas               = 2*basefee + tip          (or MAX_FEE_GWEI)
# repriced from the latest basefee before every swap.
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
GAS_WAIT_SECS="${GAS_WAIT_SECS:-12}"
GAS_WAIT_TRIES="${GAS_WAIT_TRIES:-150}"

# wei -> gwei string for display
to_gwei() { cast to-unit "$1" gwei 2>/dev/null || printf '%s wei' "$1"; }

# Refresh FEE_FLAGS from the latest basefee; cast's own pricing on RPC hiccup.
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

# Cheap-gas gate: block until basefee <= BASEFEE_MAX_WEI (if set).
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

# Broadcast a tx and return its hash immediately (--async: no built-in watcher,
# which some providers reject AFTER a successful broadcast — see
# execute_swaps.sh `send_and_wait`).
broadcast_tx() { cast send "$@" --async; }

# Poll a tx hash until it mines; prints the receipt JSON. Plain
# eth_getTransactionReceipt polls, which every provider serves.
RECEIPT_TRIES="${RECEIPT_TRIES:-60}"          # max wait = TRIES * WAIT_SECS per tx
RECEIPT_WAIT_SECS="${RECEIPT_WAIT_SECS:-2}"
wait_receipt() {
  local txhash="$1" receipt try
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

# broadcast + wait in one step (single-tx flows: approve, Fermi swap).
send_and_wait() {
  local txhash
  txhash=$(broadcast_tx "$@") || return 1
  wait_receipt "$txhash"
}

# "0x1" / "0x0" / "-" from a receipt JSON, jq-less fallback included.
receipt_status() {
  if [[ $HAVE_JQ -eq 1 ]]; then
    printf '%s' "$1" | jq -r '.status // "-"' 2>/dev/null || printf '%s' "-"
  else
    printf '%s' "$1" | grep -oE '"status"[[:space:]]*:[[:space:]]*"0x[01]"' | grep -oE '0x[01]' | head -n1 || printf '%s' "-"
  fi
}

# Echo a mined receipt's "gasUsed egp cost". PURE — callers must add cost to
# TOTAL_GAS_WEI themselves: this runs inside `read < <(...)` process
# substitutions, where a global update here would die with the subshell.
# jq-only (zeros without it): like execute_swaps.sh, jq-less mode prints raw
# receipts and tracks no gas — the gas summary line is hidden there too.
receipt_gas() {
  local receipt="$1" gas egp cost
  gas=$(hex2dec "$(printf '%s' "$receipt" | jq -r '.gasUsed // "-"' 2>/dev/null || echo "-")")
  egp=$(hex2dec "$(printf '%s' "$receipt" | jq -r '.effectiveGasPrice // "-"' 2>/dev/null || echo "-")")
  cost=$(( gas * egp ))
  # Trailing \n is load-bearing: `read` returns 1 on EOF-before-newline (even
  # though it assigns the vars), and under set -e that kills the script right
  # before the status-reporting lines.
  printf '%s %s %s\n' "$gas" "$egp" "$cost"
}

# --- venue gating & quoting ---------------------------------------------------
# isActive(tokenIn, tokenOut) — a free view; the one gate that keeps Kipseli's
# push-payment from ever stranding funds on a stale venue.
venue_active() {
  local out
  out=$(cast call "$1" "isActive(address,address)(bool)" "$TOKEN_IN" "$TOKEN_OUT" \
    --rpc-url "$ETH_RPC_URL" 2>/dev/null) || out=""
  [[ "$out" == "true" ]]
}

# Poll isActive up to ACTIVE_WAIT_SECS; 0 = active, 1 = still inactive.
wait_for_active() {
  local name="$1" addr="$2" waited=0
  while true; do
    venue_active "$addr" && return 0
    if (( waited >= ACTIVE_WAIT_SECS )); then return 1; fi
    echo "   active : $name inactive for the pair — polling again in ${ACTIVE_POLL_SECS}s (${waited}/${ACTIVE_WAIT_SECS}s)"
    sleep "$ACTIVE_POLL_SECS"
    waited=$(( waited + ACTIVE_POLL_SECS ))
  done
}

# Quote the venue directly (eth_call, no gas). Quoted --from the sender:
# harmless for Fermi, REQUIRED for Kipseli, whose quote simulates the swap by
# pulling tokenIn from the caller's balance (the sender actually holds it).
# Echoes amountOut, or nothing on failure.
quote_venue() {
  local addr="$1" out
  out=$(cast call "$addr" "quote(address,address,uint256)(uint256)" \
    "$TOKEN_IN" "$TOKEN_OUT" "$AMOUNT_IN" --from "$SENDER" \
    --rpc-url "$ETH_RPC_URL" 2>/dev/null) || out=""
  # `|| true`: grep "fails" on no match and pipefail would bubble that out of
  # the $(...) caller and trip set -e; an empty echo is the failure signal here.
  printf '%s' "$out" | grep -oE '^[0-9]+' | head -n1 || true
}

# --- receipt decoding ---------------------------------------------------------
# Venue-agnostic amountOut: sum every tokenOut `Transfer` log paying RECIPIENT.
# Robust to per-venue event differences (Fermi's bespoke entrypoint need not
# emit IPropAMM's Swapped). Echoes the sum (0 when none found). jq required.
decode_amount_out() {
  local receipt="$1" lines total=0 v
  lines=$(printf '%s' "$receipt" | jq -r \
    --arg tok "$(lc "$TOKEN_OUT")" --arg sel "$(lc "$TRANSFER_TOPIC0")" --arg to "$RECIPIENT_TOPIC" '
      [ .logs[]?
        | select((.address//""|ascii_downcase) == $tok)
        | select(((.topics[0]//"")|ascii_downcase) == $sel)
        | select(((.topics[2]//"")|ascii_downcase) == $to)
        | .data ] | .[]
    ' 2>/dev/null) || lines=""
  [[ -z "$lines" ]] && { printf '0'; return; }
  while IFS= read -r d; do
    v=$(hex2dec "$d")
    if [[ "${HAVE_BC:-0}" -eq 1 ]]; then total=$(printf '%s + %s\n' "$total" "$v" | bc); else total=$(( total + v )); fi
  done <<EOF
$lines
EOF
  printf '%s' "$total"
}

# Cross-check: the venue's own IPropAMM `Swapped` event, when present.
# data = [amountIn, amountOut, recipient]; echoes amountOut or nothing.
decode_swapped_event() {
  local receipt="$1" venue="$2" data d
  data=$(printf '%s' "$receipt" | jq -r \
    --arg ven "$(lc "$venue")" --arg sel "$(lc "$SWAPPED_TOPIC0")" '
      [ .logs[]?
        | select((.address//""|ascii_downcase) == $ven)
        | select(((.topics[0]//"")|ascii_downcase) == $sel)
        | .data ][0] // empty
    ' 2>/dev/null) || data=""
  [[ -z "$data" || ${#data} -lt 130 ]] && return 0
  d="${data#0x}"
  hex2dec "0x${d:64:64}"
}

# Report which builder produced the swap's landing block, and tally it.
report_builder() {
  local receipt="$1" blkHex blk ed graffiti blabel
  blkHex=$(printf '%s' "$receipt" | jq -r '.blockNumber // "-"' 2>/dev/null || echo "-")
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
}

# Shared success-path reporting for a mined swap receipt.
report_fill() {
  local receipt="$1" venue="$2" idx="$3" ao ao_eth ev
  report_builder "$receipt"
  ao=$(decode_amount_out "$receipt")
  ao_eth=$(cast from-wei "$ao" 2>/dev/null || echo "$ao")
  echo "   out    : $ao tokenOut units (~$ao_eth if 18-dec)  [sum of Transfer logs to recipient]"
  ev=$(decode_swapped_event "$receipt" "$venue")
  if [[ -n "$ev" ]]; then
    if [[ "$ev" == "$ao" ]]; then
      echo "   event  : OK  venue Swapped.amountOut == $ev"
    else
      echo "   event  : !!  venue Swapped.amountOut=$ev != Transfer-log sum=$ao"
    fi
  fi
  FILLED_COUNT[$idx]=$(( ${FILLED_COUNT[$idx]} + 1 ))
}

# --- banner -----------------------------------------------------------------
hr
echo "Direct propAMM swaps — fire $NUM_SWAPS swap(s), NO router, NO fallback"
hr
echo "  rpc         : $ETH_RPC_URL"
echo "  sender      : $SENDER"
echo "  recipient   : $RECIPIENT"
echo "  tokenIn     : $TOKEN_IN"
echo "  tokenOut    : $TOKEN_OUT"
echo "  amountIn    : $AMOUNT_IN  (per swap)"
echo "  slippage    : $SLIPPAGE_BPS bps (${SLIPPAGE_PCT}%)  -> AMOUNT_OUT_MIN = direct venue quote - slippage"
echo "  activeGate  : isActive polled up to ${ACTIVE_WAIT_SECS}s (every ${ACTIVE_POLL_SECS}s) before any funds move; inactive -> skip"
echo "  gasLimit    : $GAS_LIMIT swap/approve, $TRANSFER_GAS_LIMIT push transfer (estimation skipped; caps only)"
if [[ -n "$MAX_FEE_WEI" ]]; then
  echo "  gasPrice    : tip $PRIORITY_GWEI gwei, maxFee $MAX_FEE_GWEI gwei (fixed ceiling; you pay basefee + tip)"
else
  echo "  gasPrice    : tip $PRIORITY_GWEI gwei, maxFee 2*basefee + tip (ceiling only; repriced per swap)"
fi
if [[ -n "$BASEFEE_MAX_WEI" ]]; then
  echo "  basefeeGate : wait for basefee <= $BASEFEE_MAX_GWEI gwei before each swap (poll ${GAS_WAIT_SECS}s x $GAS_WAIT_TRIES)"
fi
for ((v = 0; v < NUM_VENUES; v++)); do
  if [[ "${VENUE_NAMES[$v]}" == "$FERMI_NAME" ]]; then
    flow="single tx, pull via fermiSwapWithAllowances"
  else
    flow="two txs, push: transfer then IPropAMM.swap (back-to-back nonces)"
  fi
  printf '  %-12s: %s  (%s)\n' "${VENUE_NAMES[$v]}" "${VENUE_ADDRS[$v]}" "$flow"
done
if [[ -n "$VENUE_FILTER" ]]; then
  echo "  venue       : ${VENUE_NAMES[${ACTIVE_IDXS[0]}]} (forced for all swaps)"
else
  echo "  venues      : ${VENUE_NAMES[*]} (round-robin)"
fi
if [[ $HAVE_JQ -eq 0 ]]; then
  echo "  note        : jq not found -> printing raw receipts, limited decoding"
fi
hr
echo

# --- preflight: does the sender hold the run's tokenIn? -----------------------
# One free eth_call that catches a fat-fingered AMOUNT_IN before any gas burns:
# an underfunded run would revert every Fermi pull and every Kipseli push
# (each one costing real gas). Hard-stop only when even ONE swap can't be
# funded; a partial balance just warns, since early swaps can still fill.
TOTAL_IN=$(muldiv "$AMOUNT_IN" "$NUM_SWAPS" 1)
SENDER_BAL=$(cast call "$TOKEN_IN" "balanceOf(address)(uint256)" "$SENDER" \
  --rpc-url "$ETH_RPC_URL" 2>/dev/null | grep -oE '^[0-9]+' | head -n1 || true)
if [[ -z "$SENDER_BAL" ]]; then
  echo ">> warning: could not read sender's tokenIn balance — skipping the funding preflight"
elif ! num_ge "$SENDER_BAL" "$AMOUNT_IN"; then
  echo "error: sender holds $SENDER_BAL tokenIn — not enough for even one swap of $AMOUNT_IN" >&2
  exit 1
elif ! num_ge "$SENDER_BAL" "$TOTAL_IN"; then
  echo ">> warning: balance $SENDER_BAL < planned total $TOTAL_IN ($NUM_SWAPS x $AMOUNT_IN) — later swaps will fail once it runs out"
else
  echo ">> balance ok: sender holds $SENDER_BAL tokenIn (run plans $TOTAL_IN)"
fi
echo

# --- approve once for the run's Fermi share ----------------------------------
# Only Fermi pulls via allowance; Kipseli is push-payment and needs none. The
# allowance is sized to exactly the planned Fermi swaps, so it self-depletes
# to ~0 by the end of a fully-successful run (skipped/failed swaps leave a
# remainder — re-running shrinks or reuses it via the check below).
if (( FERMI_PLANNED > 0 )); then
  FERMI_ADDR=${VENUE_ADDRS[$FERMI_IDX]}
  allowance=$(cast call "$TOKEN_IN" "allowance(address,address)(uint256)" "$SENDER" "$FERMI_ADDR" \
    --rpc-url "$ETH_RPC_URL" 2>/dev/null | grep -oE '^[0-9]+' | head -n1 || true)
  if [[ -n "$allowance" ]] && num_ge "$allowance" "$FERMI_TOTAL_IN"; then
    echo ">> approve skipped: existing FERMI allowance $allowance >= $FERMI_TOTAL_IN (one tx saved)"
  else
    echo ">> approve $FERMI_TOTAL_IN of tokenIn ($TOKEN_IN) to FERMI ($FERMI_ADDR) for $FERMI_PLANNED planned swap(s)"
    wait_for_basefee
    price_tx
    [[ -n "$PRICE_NOTE" ]] && echo "   gas    : $PRICE_NOTE"
    if APP_OUT=$(send_and_wait "$TOKEN_IN" "approve(address,uint256)" "$FERMI_ADDR" "$FERMI_TOTAL_IN" \
        "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"} 2>&1); then
      if [[ $HAVE_JQ -eq 1 ]]; then
        app_hash=$(printf '%s' "$APP_OUT" | jq -r '.transactionHash // "-"' 2>/dev/null || echo "-")
        app_st=$(receipt_status "$APP_OUT")
        read -r app_gas app_egp app_cost < <(receipt_gas "$APP_OUT")
        TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + app_cost ))
        echo "   tx=$app_hash status=$app_st gasUsed=$app_gas @ $(to_gwei "$app_egp") gwei (~$(cast from-wei "$app_cost" 2>/dev/null || echo "$app_cost") ETH)"
      else
        printf '%s\n' "$APP_OUT"
      fi
    else
      echo "   approve FAILED:" >&2
      printf '%s\n' "$APP_OUT" >&2
      exit 1
    fi
  fi
  echo
fi

# --- fire the swaps ---------------------------------------------------------
for (( i = 0; i < NUM_SWAPS; i++ )); do
  idx=${ACTIVE_IDXS[$(( i % NUM_ACTIVE ))]}
  venue="${VENUE_ADDRS[$idx]}"
  name="${VENUE_NAMES[$idx]}"

  hr
  echo "swap $(( i + 1 ))/$NUM_SWAPS  ->  direct venue: $name ($venue)"

  # --- gate 1: venue active? (free view; nothing has moved yet) --------------
  if ! wait_for_active "$name" "$venue"; then
    echo "   skip   : $name still inactive after ${ACTIVE_WAIT_SECS}s — swap skipped, nothing sent"
    SKIPPED_COUNT[$idx]=$(( ${SKIPPED_COUNT[$idx]} + 1 ))
    echo
    continue
  fi

  # --- gate 2: direct quote -> slippage floor --------------------------------
  # No fallback exists out here, so an unquotable venue means skip — never
  # push funds (Kipseli) or burn gas (Fermi) on a fill nothing priced.
  expected_out=$(quote_venue "$venue")
  if [[ -z "$expected_out" || "$expected_out" == "0" ]]; then
    echo "   skip   : $name is active but its direct quote failed — swap skipped, nothing sent"
    SKIPPED_COUNT[$idx]=$(( ${SKIPPED_COUNT[$idx]} + 1 ))
    echo
    continue
  fi
  AMOUNT_OUT_MIN=$(muldiv "$expected_out" "$(( BPS_DENOMINATOR - SLIPPAGE_BPS ))" "$BPS_DENOMINATOR")
  eo_eth=$(cast from-wei "$expected_out" 2>/dev/null || echo "$expected_out")
  min_eth=$(cast from-wei "$AMOUNT_OUT_MIN" 2>/dev/null || echo "$AMOUNT_OUT_MIN")
  echo "   quote  : $expected_out tokenOut (~$eo_eth if 18-dec)  [direct $name quote]"
  echo "   minOut : $AMOUNT_OUT_MIN tokenOut (~$min_eth if 18-dec)  [quote - ${SLIPPAGE_PCT}% slippage]"

  # Gate on cheap basefee (if configured), then reprice from the basefee NOW.
  wait_for_basefee
  price_tx
  [[ -n "$PRICE_NOTE" ]] && echo "   gas    : $PRICE_NOTE"

  if [[ "$name" == "$FERMI_NAME" ]]; then
    # --- FERMI: single atomic pull tx ----------------------------------------
    if ! OUT=$(send_and_wait "$venue" \
        "fermiSwapWithAllowances(address,address,int256,uint256,address)" \
        "$TOKEN_IN" "$TOKEN_OUT" "$AMOUNT_IN" "$AMOUNT_OUT_MIN" "$RECIPIENT" \
        "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"} 2>&1); then
      echo "   tx FAILED (reverted / not mined):"
      printf '%s\n' "$OUT" | sed 's/^/     /'
      FAILED_COUNT=$((FAILED_COUNT + 1))
      echo
      continue
    fi
    if [[ $HAVE_JQ -eq 0 ]]; then printf '%s\n' "$OUT"; echo; continue; fi

    txhash=$(printf '%s' "$OUT" | jq -r '.transactionHash // "-"' 2>/dev/null || echo "-")
    status=$(receipt_status "$OUT")
    read -r gas egp cost < <(receipt_gas "$OUT")
    TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + cost ))
    [[ "$status" == "0x1" ]] && st="success" || st="FAILED"
    echo "   tx     : $txhash"
    echo "   status : $st   gasUsed: $gas @ $(to_gwei "$egp") gwei (~$(cast from-wei "$cost" 2>/dev/null || echo "$cost") ETH)"
    if [[ "$st" == "FAILED" ]]; then
      FAILED_COUNT=$((FAILED_COUNT + 1))     # atomic: revert strands nothing
      echo
      continue
    fi
    report_fill "$OUT" "$venue" "$idx"
    echo
    continue
  fi

  # --- KIPSELI: push-payment, two txs, back-to-back nonces --------------------
  # tx A pushes amountIn to the venue; tx B consumes it. Broadcast both before
  # waiting on either so they normally land adjacent in one block. From here
  # on, a mined A without a successful B means STRANDED funds.
  # Deadline stamped HERE, after the active/basefee gates: those can block for
  # many minutes (basefee gate: up to 30 min on defaults), and a loop-top stamp
  # would silently eat into the 1h window the swap is broadcast with.
  DEADLINE=$(( $(date +%s) + 3600 ))
  nonce=$(cast nonce "$SENDER" --rpc-url "$ETH_RPC_URL" 2>/dev/null) || nonce=""
  if ! [[ "$nonce" =~ ^[0-9]+$ ]]; then
    echo "   skip   : could not fetch sender nonce — swap skipped, nothing sent"
    SKIPPED_COUNT[$idx]=$(( ${SKIPPED_COUNT[$idx]} + 1 ))
    echo
    continue
  fi

  # 2>&1 keeps the error text for reporting; on success the hash is re-
  # extracted explicitly so a stray cast warning can't corrupt it.
  if ! TXA_RAW=$(broadcast_tx "$TOKEN_IN" "transfer(address,uint256)" "$venue" "$AMOUNT_IN" \
      "${CAST_COMMON[@]}" --gas-limit "$TRANSFER_GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"} \
      --nonce "$nonce" 2>&1); then
    echo "   push   : transfer broadcast FAILED — nothing sent (verify on-chain before"
    echo "            re-running: rarely the RPC errors AFTER enqueueing the tx):"
    printf '%s\n' "$TXA_RAW" | sed 's/^/     /'
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi
  TXA=$(printf '%s' "$TXA_RAW" | grep -oE '0x[0-9a-fA-F]{64}' | head -n1 || true)
  if [[ -z "$TXA" ]]; then
    echo "   push   : transfer broadcast returned no tx hash — treating as not sent:"
    printf '%s\n' "$TXA_RAW" | sed 's/^/     /'
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi
  echo "   push   : transfer broadcast  $TXA  (nonce $nonce)"

  # Broadcast the swap right behind it. Retry a couple of times: once the
  # transfer is out, every failure mode from here risks stranding amountIn.
  TXB=""
  for attempt in 1 2 3; do
    if TXB_RAW=$(broadcast_tx "$venue" \
        "swap(address,address,uint256,uint256,address,uint256)" \
        "$TOKEN_IN" "$TOKEN_OUT" "$AMOUNT_IN" "$AMOUNT_OUT_MIN" "$RECIPIENT" "$DEADLINE" \
        "${CAST_COMMON[@]}" --gas-limit "$GAS_LIMIT" ${FEE_FLAGS[@]+"${FEE_FLAGS[@]}"} \
        --nonce "$(( nonce + 1 ))" 2>&1); then
      TXB=$(printf '%s' "$TXB_RAW" | grep -oE '0x[0-9a-fA-F]{64}' | head -n1 || true)
      [[ -n "$TXB" ]] && break
    fi
    echo "   swap   : broadcast attempt $attempt/3 failed — retrying"
    TXB=""
    sleep 1
  done
  if [[ -z "$TXB" ]]; then
    echo "   swap   : !! STRANDED RISK — transfer $TXA is in flight but the swap never broadcast."
    echo "            If the transfer mines, $AMOUNT_IN tokenIn sits on $name unrecovered."
    STRANDED_COUNT=$((STRANDED_COUNT + 1))
    STRANDED_TOTAL=$(( STRANDED_TOTAL + AMOUNT_IN ))
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi
  echo "   swap   : swap broadcast      $TXB  (nonce $(( nonce + 1 )))"

  # Now wait on both receipts.
  if ! RA=$(wait_receipt "$TXA" 2>&1); then
    echo "   push   : transfer unmined after the receipt window — swap is nonce-gapped behind it."
    echo "            Both may STILL land later; check $TXA / $TXB before re-running."
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi
  sta=$(receipt_status "$RA")
  gasA=0; egpA=0; costA=0
  if [[ $HAVE_JQ -eq 1 ]]; then
    read -r gasA egpA costA < <(receipt_gas "$RA")
    TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + costA ))
  fi
  if [[ "$sta" != "0x1" ]]; then
    echo "   push   : transfer REVERTED ($TXA) — no funds reached $name; swap will revert on no balance."
    if RBX=$(wait_receipt "$TXB" 2>/dev/null) && [[ $HAVE_JQ -eq 1 ]]; then
      read -r _ _ costX < <(receipt_gas "$RBX")
      TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + costX ))
    fi
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi
  echo "   push   : transfer mined ($TXA)"

  if ! RB=$(wait_receipt "$TXB" 2>&1); then
    echo "   swap   : !! PUSHED BUT SWAP UNMINED — $AMOUNT_IN tokenIn sits on $name."
    echo "            The swap may STILL land (1h deadline); check $TXB before judging it stranded."
    STRANDED_COUNT=$((STRANDED_COUNT + 1))
    STRANDED_TOTAL=$(( STRANDED_TOTAL + AMOUNT_IN ))
    echo
    continue
  fi
  # receipt_status is jq-less-safe, so stranded detection works either way.
  stb=$(receipt_status "$RB")
  if [[ "$stb" != "0x1" ]]; then
    if [[ $HAVE_JQ -eq 1 ]]; then
      read -r _ _ costB < <(receipt_gas "$RB")
      TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + costB ))
    fi
    echo "   swap   : !! STRANDED — transfer mined but swap REVERTED ($TXB): $AMOUNT_IN tokenIn sits on $name."
    STRANDED_COUNT=$((STRANDED_COUNT + 1))
    STRANDED_TOTAL=$(( STRANDED_TOTAL + AMOUNT_IN ))
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo
    continue
  fi
  if [[ $HAVE_JQ -eq 0 ]]; then printf '%s\n' "$RB"; echo; continue; fi
  read -r gasB egpB costB < <(receipt_gas "$RB")
  TOTAL_GAS_WEI=$(( TOTAL_GAS_WEI + costB ))
  echo "   tx     : $TXB"
  echo "   status : success   gasUsed: $(( gasA + gasB )) (both txs) @ ~$(to_gwei "$egpB") gwei (~$(cast from-wei "$(( costA + costB ))" 2>/dev/null || echo "$(( costA + costB ))") ETH total)"
  report_fill "$RB" "$venue" "$idx"
  echo
done

# --- summary ----------------------------------------------------------------
hr
echo "Summary"
hr
for v in "${ACTIVE_IDXS[@]}"; do
  echo "  ${VENUE_NAMES[$v]} filled directly      : ${FILLED_COUNT[$v]}"
  echo "  ${VENUE_NAMES[$v]} skipped (inactive/quote) : ${SKIPPED_COUNT[$v]}"
done
echo "  STRANDED push payments     : $STRANDED_COUNT  ($STRANDED_TOTAL tokenIn units pushed without a fill)"
echo "  failed / reverted txs      : $FAILED_COUNT"
if [[ $HAVE_JQ -eq 1 ]]; then
  echo "  --- blocks built by ---"
  echo "  Titan                      : $BUILD_TITAN"
  echo "  Quasar                     : $BUILD_QUASAR"
  echo "  BuilderNet                 : $BUILD_BNET"
  echo "  other / unknown            : $BUILD_OTHER"
  echo "  total gas paid             : $TOTAL_GAS_WEI wei (~$(cast from-wei "$TOTAL_GAS_WEI" 2>/dev/null || echo "$TOTAL_GAS_WEI") ETH, approve + swaps)"
fi
echo "  total submitted            : $NUM_SWAPS"
