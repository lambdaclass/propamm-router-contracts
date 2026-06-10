# Reference

Public API by module. The crate root re-exports `ContractClient`,
`CallOverrides`, `PropAmmRouter`, `Error`/`Result`, and the primitives
(`Address`, `H256`, `U256`, `TxHash` — ethrex types). All async methods
return `Result<T, Error>`; the **Returns** lines below give the `Ok` type.

## `client`

### `ContractClient::connect(rpc_url)`

Read-only JSON-RPC client: calls, quotes, and views work; `send` fails.

- `rpc_url: &str` — JSON-RPC endpoint, e.g. `http://localhost:8545`.

**Returns** `ContractClient`. Fails on an invalid URL.

### `ContractClient::connect_with_signer(rpc_url, private_key)`

Signing client.

- `private_key: &str` — 0x-prefixed (or bare) secp256k1 private key.

**Returns** `ContractClient`. Fails on an invalid URL or key.

### `call(to, calldata, overrides)`

Simulate a call via `eth_call` and return its raw return data. This is how
the router's quote functions (nonpayable on-chain) are called.

- `to: Address` — contract to call.
- `calldata: Vec<u8>` — ABI-encoded call (see `encode_calldata` and the
  signature constants in `router::abi`).
- `overrides: &CallOverrides`:
  - `state: Option<StateOverrideSet>` — state overrides (third `eth_call`
    parameter, rex type).
  - `block: Option<BlockOverrideSet>` — block overrides (fourth parameter),
    e.g. a pinned `number`/`time`.

**Returns** `Vec<u8>` — raw return data; decode with
`router::abi::decode_values`. Reverts surface as `Error::Revert` with the
payload recovered when the node provides it.

### `send(to, calldata, value)`

Sign and send a contract call as an EIP-1559 transaction; gas and nonce are
filled by the node. Requires a signer.

- `value: Option<U256>` — ETH attached to the transaction, in wei.

**Returns** `H256` — the transaction hash (not mined yet).

### `wait_for_transaction(hash)`

Poll until the transaction is mined (2s interval, ~2min timeout).

**Returns** `TransactionReceipt` (ethrex's `RpcReceipt`).

### `signer_address()` / `eth()`

The configured signer's address (`Option<Address>`), and the underlying
ethrex `EthClient` for anything not wrapped here.

## `router`

### `PropAmmRouter::new(client, address)`

Typed `PropAMMRouter` bindings with the default streaming overrides source
(connects lazily on the first quote). Method names drop the on-chain `V1`
suffix (`swap` calls `swapV1`, ...).

- `client: ContractClient` — the client to call/send through.
- `address: Address` — deployed router (proxy) address.

### `PropAmmRouter::with_overrides(client, address, overrides)`

Same, with an explicit source.

- `overrides: Arc<dyn OverridesSource>` — e.g.
  `Arc::new(OverridesRpcSource::default())`.

### Quotes

All quote methods simulate via `eth_call`, by default carrying the latest
state overrides plus their block number/timestamp, and return
`Quote { amount_out: U256, venue: Address }` — the output amount and the
venue that produced it.

Common parameters:

- `token_in: Address` — token being sold, or `ETH_SENTINEL` for native ETH.
- `token_out: Address` — token being bought, or `ETH_SENTINEL`.
- `amount_in: U256` — exact input amount, in atomic units.

Each method has a `_with` variant taking `opts: &QuoteOptions`:

- `overrides: QuoteOverrides` — `Attached` (the router's source, default),
  `Skip` (no overrides), `Source(Arc<dyn OverridesSource>)` (for this call
  only), or `Snapshot(OverridesSnapshot)` (a fixed snapshot).
- `skip_bebop_default: bool` — set `true` to keep Bebop's raw on-chain slot
  instead of zeroing it when the snapshot has no Bebop entry.

#### `quote(token_in, token_out, amount_in)` / `quote_with(..., opts)`

Best quote across all whitelisted venues and the Uniswap V3 fallback.

#### `quote_venue(venue, token_in, token_out, amount_in)` / `quote_venue_with(..., opts)`

Quote a specific venue.

- `venue: Address` — a whitelisted pAMM (see `common::pamms`) or the fallback
  router address. When the venue can't be priced, the call does **not**
  fail: it falls back to the Uniswap V3 quote and reports the fallback
  router as `venue` in the result.

#### `quote_selected_venues(venues, token_in, token_out, amount_in)` / `quote_selected_venues_with(..., opts)`

Best quote among a caller-supplied set of venues.

- `venues: Vec<Address>` — the only venues considered. Venues that revert
  while quoting are skipped; when none can be priced the router falls back
  to the Uniswap V3 quote.

#### `quote_uniswap_v3(token_in, token_out, amount_in)`

Quote the Uniswap V3 fallback route directly, at the pair's resolved fee
tier. Never applies overrides (the fallback quoter only reads live on-chain
pool state).

**Returns** `U256` — the output amount.

### Swaps

All swap entrypoints take `params: &SwapParams`:

- `token_in: Address` — token being sold; `ETH_SENTINEL` for native ETH (the
  SDK attaches `msg.value = amount_in` automatically; otherwise the router
  needs an ERC-20 allowance — see `approve`).
- `token_out: Address` — token being bought; `ETH_SENTINEL` delivers native ETH.
- `amount_in: U256` — exact input amount, in atomic units.
- `amount_out_min: U256` — minimum acceptable output. On the `_with_fee`
  paths this is the **net** minimum the recipient must receive after the fee.
- `recipient: Address` — receiver of `token_out`.
- `deadline: U256` — unix timestamp after which the swap is invalid (see
  `deadline_in`).

Each returns `H256` — the transaction hash. Requires a signer.

#### `swap(params)`

Swap through the best-quoting venue; falls back to Uniswap V3 if the chosen
venue fails to fill.

#### `swap_with_fee(params, fee)`

`swap` plus a frontend fee skimmed from the output token.

- `fee: FrontendFee` — build with `frontend_fee(bps, recipient)`.

#### `swap_via_venue(venue, params)`

Swap through an explicit venue.

- `venue: Address` — a whitelisted pAMM or the fallback router address;
  anything else reverts with `UnknownVenue`.

#### `swap_via_venue_with_fee(venue, params, fee)`

`swap_via_venue` plus a frontend fee.

#### `swap_via_selected_venues(venues, params)`

Re-quote only `venues` on-chain and swap through the best one; routes to the
Uniswap V3 fallback when none can be priced.

#### `swap_via_selected_venues_with_fee(venues, params, fee)`

`swap_via_selected_venues` plus a frontend fee.

#### `swap_and_wait`, `swap_with_fee_and_wait`, `swap_via_venue_and_wait`, `swap_via_venue_with_fee_and_wait`, `swap_via_selected_venues_and_wait`, `swap_via_selected_venues_with_fee_and_wait`

Same signatures as their base methods, but wait for the receipt and decode
the outcome in one call. **Return** `SwapResult`.

#### `wait_for_swap(hash)`

Wait until a swap is mined and decode its outcome from the router's events.

- `hash: H256` — hash returned by any swap method.

**Returns** `SwapResult`:

- `hash` / `receipt` — the transaction and its receipt.
- `amount_in: U256` — input pulled from the sender (from `Swapped`).
- `amount_out: U256` — output delivered to the recipient (net of any fee).
- `executed_venue: Address` — the venue that actually filled, or the Uniswap
  fallback router.
- `recipient: Address` — who received `token_out`.
- `fee: Option<FeeCharged>` — `{ recipient, amount }`, present when the swap
  charged a frontend fee (from `FrontendFeeCharged`).

Fails if the transaction reverted or emitted no `Swapped` event.

### ERC-20

#### `approve(token, amount)`

Approve the router to pull `amount` of `token` from the signer. **Returns**
`H256`.

#### `allowance(token, owner)`

Current allowance `owner` has granted the router for `token`. **Returns**
`U256`.

### Views

| Method | Returns | Description |
|---|---|---|
| `fallback_swap_router()` | `Address` | the Uniswap fallback "venue" address (dynamic router configuration) |
| `fallback_quoter()` | `Address` | quoter used to price the fallback route |
| `fallback_fee()` | `u32` | global fallback fee tier, in hundredths of a bip (e.g. `3000` = 0.30%) |
| `get_pair_fee(token_a, token_b)` | `u32` | raw per-pair tier override, `0` if unset; order-independent |
| `resolved_fee(token_in, token_out)` | `u32` | effective tier for a pair: the override if set, else the global fee |
| `is_whitelisted_venue(venue)` | `bool` | whether `venue` is a whitelisted pAMM (the fallback is *not* a member) |
| `get_whitelisted_venues()` | `Vec<Address>` | every whitelisted pAMM; order not guaranteed |
| `paused()` | `bool` | whether swaps are paused (quotes still work while paused) |

### `frontend_fee(bps, recipient)`

Validated `FrontendFee` builder.

- `bps: u16` — fee in basis points of the output; at most `MAX_FEE_BPS`
  (`100`, i.e. 1%).
- `recipient: Address` — receives the fee in `token_out`; must be non-zero.

**Returns** `FrontendFee`. Fails with `Error::InvalidInput` otherwise.

## `router::abi`

Hand-rolled ABI surface over ethrex's calldata codec, guarded by tests that
check every signature against the compiled contract (selector checks plus
two-direction function/event/error parity).

### Signature constants

Canonical signature strings for every bound entrypoint — `SWAP`, `QUOTE`,
`ADD_VENUE`, `SWAPPED_EVENT`, ... — usable directly with ethrex's
`encode_calldata`. `FUNCTIONS` and `EVENTS` enumerate them (the parity test
iterates these). `ERC20_APPROVE` / `ERC20_ALLOWANCE` cover the token side.

### `decode_values(types, data)`

Decode ABI-encoded return data (or any bare tuple — event data, error args)
against a comma-separated type list.

- `types: &str` — e.g. `"uint256,address"`.
- `data: &[u8]` — raw bytes (no selector).

**Returns** `Vec<Value>` — unwrap with the extractors below.

### `as_u256(value)` / `as_address(value)` / `as_bool(value)` / `as_address_array(value)`

Extract a typed value from a decoded `Value`, failing with `Error::Abi` on a
mismatch.

### `event_topic(signature)`

keccak topic0 of an event signature. **Returns** `H256`.

### `topic_as_address(topic)`

Read an indexed event argument (a 32-byte topic) as an `Address`.

### `decode_error(data)`

Name a revert payload against the router's known custom errors.

- `data: &[u8]` — raw revert data (selector + args).

**Returns** `Option<String>` — e.g. `InsufficientOutput(1000, 900)`; `None`
for unknown selectors.

## `overrides`

### `trait OverridesSource`

Anything quotes can pull override snapshots from. Implement to plug in a
custom source.

- `async fn get_overrides(&self) -> Result<OverridesSnapshot>`
- `fn close(&self)` — immediate, permanent teardown (default: no-op).

### `OverridesWsSource::new(config)` / `::default()`

Streaming source (the router default). `OverridesWsSourceConfig`:

- `url: String` — stream endpoint (default
  `wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream`).
- `first_frame_timeout: Duration` — how long `get_overrides` waits for the
  first frame before failing (default 5s).
- `idle_timeout: Duration` — drop the connection after this long without a
  `get_overrides` call (default 30s); the next call reconnects transparently
  and waits for a fresh frame.

`get_overrides()` returns the accumulated snapshot — per-pAMM entries persist
across frames (a frame only carries the pAMMs it updates). Connects lazily on
first use.

### `OverridesRpcSource::new(url)` / `::default()`

Fetch-on-demand source: one `titan_getPammStateOverrides` HTTP call per
`get_overrides()` (default endpoint `https://rpc.titanbuilder.xyz`).

### `parse_overrides_message(raw)`

Parse a raw payload (a WS frame or the JSON-RPC `result`) into an
`OverridesSnapshot`; pAMMs/contracts with empty `stateDiff`s are dropped.

- `raw: &serde_json::Value` — the decoded JSON.

**Returns** `OverridesSnapshot`. Fails if `raw` is not a JSON object.

### `to_state_override(snapshot, options)`

Flatten a snapshot into rex's `StateOverrideSet` for `eth_call`.

- `options: &ToStateOverrideOptions`:
  - `pamms: Option<Vec<Address>>` — restrict to these pAMM entries (default all).
  - `skip_bebop_default: bool` — skip injecting the Bebop default slot when
    no Bebop entry is present.

**Returns** `StateOverrideSet` — diffs merged at slot level.

### Types and constants

- `OverridesSnapshot { block_number: Option<u64>, timestamp_ns: Option<u64>, per_pamm }`
  — `per_pamm` maps pAMM address → contract address → slot → value.
- `BEBOP_DEFAULT_SLOT`, `DEFAULT_OVERRIDES_RPC_URL`, `DEFAULT_OVERRIDES_WS_URL`.

## `common`

### `common::tokens`

`ETH_SENTINEL` (pass as `token_in`/`token_out` to signal native ETH), and the
mainnet token addresses `USDC`, `USDT`, `WETH`.

### `common::pamms`

`FERMI`, `BEBOP`, `KIPSELI` venue addresses; `PAMMS` name → address array.
The Uniswap fallback is intentionally absent — read it via
`router.fallback_swap_router()`.

### `common::helpers`

#### `apply_slippage(amount, bps)`

Shave `bps` basis points off `amount` — derive `amount_out_min` from a quote.

- `amount: U256` — e.g. a quoted output.
- `bps: u32` — at most `10000`; fails with `Error::InvalidInput` otherwise.

**Returns** `U256` — `amount - amount * bps / 10000`.

#### `deadline_in(seconds)`

Unix-timestamp deadline `seconds` from now. **Returns** `U256`.

#### `parse_address(s)`

Parse a 0x-prefixed (or bare) 20-byte hex address. **Returns** `Address`.

#### `parse_units(amount, decimals)` / `format_units(value, decimals)` / `parse_ether(amount)` / `format_ether(value)`

Decimal ↔ atomic-unit conversion: `parse_units("1.5", 6)` → `1500000`;
`format_units(1500000, 6)` → `"1.5"` (trailing zeros trimmed); the `ether`
variants fix `decimals = 18`. Parsing fails on malformed numbers, more
fractional digits than `decimals`, or uint256 overflow.

## `error`

```rust
enum Error {
    Client(EthClientError),                        // transport / node / tx errors
    Revert { message, data: Option<Vec<u8>> },     // eth_call reverts; router calls
                                                   // append the named error when decodable
    Abi(String),                                   // encode/decode failures
    Overrides(String),                             // overrides fetch/parse failures
    Timeout(String),                               // first-frame / receipt timeouts
    InvalidInput(String),                          // addresses, fee bounds, keys, URLs
    Other(String),
}
```
