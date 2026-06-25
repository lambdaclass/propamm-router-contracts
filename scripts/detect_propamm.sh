#!/usr/bin/env bash
#
# detect_propamm.sh — check whether a deployed address implements the IPropAMM
# interface (and the optional IPropAMMExactOut extension), function by function
# and for the `Swapped` event.
#
# There is no on-chain reflection: a contract's bytecode doesn't enumerate its
# functions. So this script triangulates the answer from three INDEPENDENT
# signals, each with different blind spots, and reports them all:
#
#   1. STATIC bytecode scan. Solidity's dispatcher embeds every function's
#      4-byte selector as a `PUSH4 <selector>` constant, and emits each event's
#      topic0 (keccak of its canonical signature) as a `PUSH32 <topic0>` before
#      the LOG opcode. So `cast code` will literally contain those bytes if the
#      function/event exists. Fast, needs no live call — but a PROXY's own
#      bytecode holds none of them (they live in the implementation), so this
#      step resolves EIP-1967 logic/beacon proxies and scans the impl too.
#
#   2. ERC-165 `supportsInterface`. IPropAMM does NOT mandate ERC-165, but a
#      conforming IPropAMMExactOut venue MUST return true for the IERC165,
#      IPropAMM and IPropAMMExactOut interface IDs. When the contract answers
#      `supportsInterface`, this is the AUTHORITATIVE signal.
#
#   3. LIVE view-call probe. `eth_call`s the two no-side-effect-revert view
#      functions (`getPairs()`, `isActive()`). A well-shaped return is strong
#      positive evidence; a revert that matches the address's generic
#      fallback-revert means the selector isn't there.
#
# The interface IDs and selectors below are derived from, and validated against,
# the live mainnet Fermi venue 0x5979458912F80B96d30D4220af8E2e4925A33320.
#
# Usage:
#   ./scripts/detect_propamm.sh <address> [rpc_url]
#
# RPC resolution order: the [rpc_url] arg, else $ETH_RPC_URL, else $RPC_URL,
# else the public mainnet node. isActive() is probed with mainnet WETH/USDC by
# default; override with PROBE_TOKEN_IN / PROBE_TOKEN_OUT for other chains.
#
# Examples:
#   ./scripts/detect_propamm.sh 0x5979458912F80B96d30D4220af8E2e4925A33320
#   ETH_RPC_URL=https://my-node ./scripts/detect_propamm.sh 0x28d9CCEDf1B7ac9B3F090f4F0292837dE87c1D39
#
# Requires: cast (Foundry). No network downloads, no pip/npm.

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Args & config
# ──────────────────────────────────────────────────────────────────────────
ADDR="${1:-}"
if [[ -z "$ADDR" ]]; then
  echo "usage: $0 <address> [rpc_url]" >&2
  exit 2
fi
RPC="${2:-${ETH_RPC_URL:-${RPC_URL:-https://ethereum-rpc.publicnode.com}}}"

# Default isActive() probe pair: mainnet WETH -> USDC. Override per chain.
PROBE_TOKEN_IN="${PROBE_TOKEN_IN:-0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2}"
PROBE_TOKEN_OUT="${PROBE_TOKEN_OUT:-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48}"

command -v cast >/dev/null 2>&1 || { echo "error: 'cast' (Foundry) not found in PATH" >&2; exit 2; }

# ──────────────────────────────────────────────────────────────────────────
# Interface definition — selectors, event topic0, and ERC-165 interface IDs.
# IDs are computed from the selectors (XOR), exactly as Solidity's
# type(I).interfaceId does, so editing the selector list keeps them in sync.
# ──────────────────────────────────────────────────────────────────────────
# Core IPropAMM functions:
SEL_isActive="ae131deb"   # isActive(address,address)
SEL_getPairs="767eb5ef"   # getPairs()
SEL_quote="b6466384"      # quote(address,address,uint256)
SEL_swap="9908fc8b"       # swap(address,address,uint256,uint256,address,uint256)
# Optional IPropAMMExactOut extension functions:
SEL_quoteExactOut="7020df95"  # quoteExactOut(address,address,uint256)
SEL_swapExactOut="2822bb06"   # swapExactOut(address,address,uint256,uint256,address,address,uint256)
# ERC-165:
SEL_supportsInterface="01ffc9a7"  # supportsInterface(bytes4)
# IPropAMM `Swapped` event topic0:
TOPIC_Swapped="1eeaa4acf3c225a4033105c2647625dbb298dec93b14e16253c4231e26c02b1d"

# ERC-165 interface IDs (XOR of the selectors each interface DECLARES; Solidity
# excludes inherited selectors, so ExactOut's id covers only its 2 own fns).
ID_IERC165="0x${SEL_supportsInterface}"
ID_IPROPAMM=$(printf '0x%08x' "$(( 0x$SEL_isActive ^ 0x$SEL_getPairs ^ 0x$SEL_quote ^ 0x$SEL_swap ))")
ID_EXACTOUT=$(printf '0x%08x' "$(( 0x$SEL_quoteExactOut ^ 0x$SEL_swapExactOut ))")

# ──────────────────────────────────────────────────────────────────────────
# Output helpers
# ──────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then BOLD=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
else BOLD=""; GRN=""; RED=""; YEL=""; DIM=""; RST=""; fi
yes()  { printf "${GRN}✓${RST}"; }
no()   { printf "${RED}✗${RST}"; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────"; }

echo "${BOLD}IPropAMM interface detector${RST}"
echo "  address : $ADDR"
echo "  rpc     : $RPC"
echo "  IDs     : IERC165=$ID_IERC165  IPropAMM=$ID_IPROPAMM  IPropAMMExactOut=$ID_EXACTOUT"
hr

# ──────────────────────────────────────────────────────────────────────────
# 1. Fetch bytecode, resolving EIP-1967 proxies to scan the implementation.
# ──────────────────────────────────────────────────────────────────────────
CODE=$(cast code "$ADDR" --rpc-url "$RPC" 2>/dev/null)
if [[ -z "$CODE" || "$CODE" == "0x" ]]; then
  echo "${RED}No bytecode at this address${RST} — it is an EOA (or empty/self-destructed)."
  echo
  echo "${BOLD}VERDICT: does NOT implement IPropAMM${RST} (no code)."
  exit 1
fi

# EIP-1967 logic slot and beacon slot.
SLOT_IMPL="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
SLOT_BEACON="0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"
raw_impl=$(cast storage "$ADDR" "$SLOT_IMPL"   --rpc-url "$RPC" 2>/dev/null)
raw_beac=$(cast storage "$ADDR" "$SLOT_BEACON" --rpc-url "$RPC" 2>/dev/null)
addr_from_slot() { # last 20 bytes of a 32-byte slot -> 0x address, or empty if zero
  local s="${1#0x}"; local a="${s: -40}"
  [[ -n "$a" && "$a" != "0000000000000000000000000000000000000000" ]] && echo "0x$a"
}
IMPL=$(addr_from_slot "${raw_impl:-0x}")
if [[ -z "$IMPL" && -n "$(addr_from_slot "${raw_beac:-0x}")" ]]; then
  BEACON=$(addr_from_slot "$raw_beac")
  IMPL=$(cast call "$BEACON" "implementation()(address)" --rpc-url "$RPC" 2>/dev/null)
  [[ -n "$IMPL" ]] && echo "${DIM}EIP-1967 beacon proxy -> beacon $BEACON -> impl $IMPL${RST}"
elif [[ -n "$IMPL" ]]; then
  echo "${DIM}EIP-1967 proxy -> implementation $IMPL${RST}"
fi
# Scan the union of proxy bytecode + (if any) implementation bytecode.
if [[ -n "$IMPL" ]]; then
  IMPL_CODE=$(cast code "$IMPL" --rpc-url "$RPC" 2>/dev/null)
  CODE="${CODE}${IMPL_CODE}"
fi
echo "${DIM}scanned bytecode: ~$(( ${#CODE} / 2 )) bytes${RST}"
hr

# in_code <hex-needle> : true if present in the scanned bytecode. -F: the
# needle is a literal hex string, never a regex.
in_code() { grep -Fqi -- "$1" <<<"$CODE"; }

# ──────────────────────────────────────────────────────────────────────────
# 2. ERC-165 dynamic query (authoritative ONLY when the contract is genuinely
# ERC-165 compliant — see the compliance gate below).
# ──────────────────────────────────────────────────────────────────────────
# Returns: "true", "false", or "revert"
supports() {
  local out
  out=$(cast call "$ADDR" "supportsInterface(bytes4)(bool)" "$1" --rpc-url "$RPC" 2>/dev/null)
  case "$out" in
    true)  echo true ;;
    false) echo false ;;
    *)     echo revert ;;
  esac
}
S165=$(supports "$ID_IERC165")
SFF=$(supports 0xffffffff)   # EIP-165 mandates this be false for a real implementer
SPROP=$(supports "$ID_IPROPAMM")
SEXO=$(supports "$ID_EXACTOUT")
# Compliance gate: a contract that isn't really ERC-165 may answer
# `supportsInterface` from a permissive fallback and return a bogus `true`. Only
# trust the IPropAMM/ExactOut answers when the spec's invariant holds
# (true for IERC165, false for 0xffffffff). Otherwise they don't count toward
# the verdict and the bytecode + live-call signals carry it.
if [[ "$S165" == true && "$SFF" == false ]]; then ERC165_OK=true; else ERC165_OK=false; fi
if $ERC165_OK; then TRUST_PROP="$SPROP"; TRUST_EXO="$SEXO"; else TRUST_PROP="n/a"; TRUST_EXO="n/a"; fi

# ──────────────────────────────────────────────────────────────────────────
# 3. Live view-call probe (no-arg getPairs is chain-agnostic; isActive needs a pair).
# ──────────────────────────────────────────────────────────────────────────
# Echoes "ok" if the call returns data, else "revert:<data>".
livecall() {
  local out rc
  out=$(cast call "$ADDR" "$@" --rpc-url "$RPC" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then echo "ok"; else
    # surface the revert payload. Prefer the hex after cast's `data:` field
    # (the actual return/custom-error data); fall back to the last long hex.
    local data
    data=$(grep -oiE 'data:?[[:space:]]*"?0x[0-9a-f]*' <<<"$out" | grep -oiE '0x[0-9a-f]+' | tail -1)
    [[ -z "$data" ]] && data=$(grep -oiE '0x[0-9a-f]{8,}' <<<"$out" | tail -1)
    echo "revert:${data:-?}"
  fi
}
LV_getPairs=$(livecall "getPairs()((address,address)[])")
LV_isActive=$(livecall "isActive(address,address)(bool)" "$PROBE_TOKEN_IN" "$PROBE_TOKEN_OUT")

# ──────────────────────────────────────────────────────────────────────────
# Per-member report
# ──────────────────────────────────────────────────────────────────────────
# row <label> <selector> <live-result-or-empty>
row() {
  local label="$1" sel="$2" live="${3:-}"
  printf "  "
  if in_code "$sel"; then yes; else no; fi
  printf " %-14s ${DIM}0x%s${RST}  bytecode" "$label" "$sel"
  if [[ -n "$live" ]]; then
    if [[ "$live" == ok ]]; then printf "   ${GRN}live:ok${RST}"; else printf "   ${YEL}live:%s${RST}" "$live"; fi
  fi
  printf "\n"
}

echo "${BOLD}IPropAMM core${RST}"
row "isActive"   "$SEL_isActive" "$LV_isActive"
row "getPairs"   "$SEL_getPairs" "$LV_getPairs"
row "quote"      "$SEL_quote"
row "swap"       "$SEL_swap"
printf "  "; if in_code "$TOPIC_Swapped"; then yes; else no; fi
printf " %-14s ${DIM}topic0 0x%s${RST}  bytecode\n" "Swapped(evt)" "$TOPIC_Swapped"

echo
echo "${BOLD}IPropAMMExactOut (optional extension)${RST}"
row "quoteExactOut" "$SEL_quoteExactOut"
row "swapExactOut"  "$SEL_swapExactOut"

echo
echo "${BOLD}ERC-165 supportsInterface${RST}"
printf "  IERC165          (%s) => %s\n" "$ID_IERC165"  "$S165"
printf "  0xffffffff (must be false) => %s\n" "$SFF"
printf "  IPropAMM         (%s) => %s\n" "$ID_IPROPAMM" "$SPROP"
printf "  IPropAMMExactOut (%s) => %s\n" "$ID_EXACTOUT" "$SEXO"
if ! $ERC165_OK; then
  echo "  ${YEL}note: not a compliant ERC-165 contract — these answers are NOT trusted for the verdict.${RST}"
fi
hr

# ──────────────────────────────────────────────────────────────────────────
# Verdict — combine the three signals.
# A member counts as "present" if found in bytecode OR confirmed by ERC-165
# OR (for the probed views) the live call returned data.
# ──────────────────────────────────────────────────────────────────────────
present() { # present <selector> [erc165-says] [live]
  in_code "$1" && return 0
  [[ "${2:-}" == "true" ]] && return 0
  [[ "${3:-}" == "ok"   ]] && return 0
  return 1
}
core_ok=true
present "$SEL_isActive" "$TRUST_PROP" "$LV_isActive" || core_ok=false
present "$SEL_getPairs" "$TRUST_PROP" "$LV_getPairs" || core_ok=false
present "$SEL_quote"    "$TRUST_PROP"                || core_ok=false
present "$SEL_swap"     "$TRUST_PROP"                || core_ok=false
event_ok=$( in_code "$TOPIC_Swapped" && echo true || echo false )
# ExactOut: by either bytecode or its own (trusted) ERC-165 id.
exo_ok=true
present "$SEL_quoteExactOut" "$TRUST_EXO" || exo_ok=false
present "$SEL_swapExactOut"  "$TRUST_EXO" || exo_ok=false

if $core_ok; then
  if [[ "$event_ok" == true ]]; then
    echo "${GRN}${BOLD}VERDICT: implements IPropAMM${RST} (all 4 core functions + Swapped event present)."
  else
    echo "${YEL}${BOLD}VERDICT: likely implements IPropAMM${RST} — all 4 core functions present, but the"
    echo "${YEL}Swapped event topic was not found in bytecode (proxy/non-Solidity emitter, or it never emits it).${RST}"
  fi
  if $exo_ok; then
    echo "${GRN}        + supports the IPropAMMExactOut extension (exact-output swaps).${RST}"
  else
    echo "${DIM}        exact-input only (no IPropAMMExactOut).${RST}"
  fi
  exit 0
else
  echo "${RED}${BOLD}VERDICT: does NOT implement IPropAMM${RST} — one or more core functions are missing"
  echo "${RED}across all three checks (bytecode scan, ERC-165, live call).${RST}"
  exit 1
fi
