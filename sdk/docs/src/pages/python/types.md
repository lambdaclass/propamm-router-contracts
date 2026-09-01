# Types

Shared types across the Python SDK. The value types (`SwapParams`, `Quote`,
`SwapResult`, …) are dataclasses re-exported from the package root
(`from propamm import SwapParams`); override types come from
`propamm.overrides`.

## SwapParams

Common parameters shared by every [swap entrypoint](/python/router/swap).

```python
@dataclass
class SwapParams:
    token_in: str
    token_out: str
    amount_in: int
    amount_out_min: int
    recipient: str
    deadline: int
```

- `token_in` — address of the token being sold, or `ETH_SENTINEL` for native ETH (attaches
  `msg.value` automatically).
- `token_out` — address of the token being bought; `ETH_SENTINEL` delivers native ETH.
- `amount_in` — exact input amount, in atomic units.
- `amount_out_min` — minimum acceptable output (net of the frontend fee, when
  one is passed); derive from a quote with `apply_slippage`.
- `recipient` — receiver of `token_out`.
- `deadline` — unix timestamp after which the swap is invalid; build with
  `deadline_in`.

## Quote

Result of every quote method.

```python
@dataclass
class Quote:
    amount_out: int
    venue: str
```

- `amount_out` — the quoted output amount, in atomic units.
- `venue` — the venue that produced the quote (or the Uniswap fallback
  router); pin it in a follow-up [`swap`](/python/router/swap) via
  [`SwapOptions.venues`](#swapoptions) to execute against it.

## SwapResult

Decoded outcome of a mined swap, from
[`wait_for_swap`](/python/router/wait_for_swap) or `swap_and_wait`.

```python
@dataclass
class SwapResult:
    hash: str
    receipt: Any
    amount_in: int
    amount_out: int
    executed_venue: str
    recipient: str
    fee: FeeCharged | None = None
```

- `hash` / `receipt` — the transaction hash and its receipt.
- `amount_in` — input pulled from the sender (from the `Swapped` event).
- `amount_out` — output delivered to the recipient, net of any fee.
- `executed_venue` — the venue that actually filled, or the Uniswap fallback
  router.
- `recipient` — who received `token_out`.
- `fee` — a [`FeeCharged`](#feecharged), present when the swap charged a
  frontend fee (from `FrontendFeeCharged`).

## FeeCharged

The frontend fee actually charged by a swap, on
[`SwapResult.fee`](#swapresult).

```python
@dataclass
class FeeCharged:
    recipient: str
    amount: int
```

## SwapOptions

Per-swap options, accepted by [`swap`](/python/router/swap) and
`swap_and_wait`.

```python
@dataclass
class SwapOptions:
    venues: list[str] | None = None
    frontend_fee: FrontendFee | None = None
    gas_limit: int | None = None
```

- `venues` — restrict the swap to these venues: a single entry executes
  through that venue directly, several re-quote on-chain and fill via the best
  of them. Must be non-empty when present; omit to swap through the
  best-quoting venue overall.
- `frontend_fee` — skim a [frontend fee](#frontendfee) from the output; routes
  the call through the contract's `WithFee` selector.
- `gas_limit` — explicit transaction gas limit, in gas units. Overrides the
  hardcoded per-function default (see [swap](/python/router/swap#gas-limits)).

## FrontendFee

Frontend fee skimmed from a swap's output; pass via
[`SwapOptions.frontend_fee`](#swapoptions). Validated before the swap is sent.

```python
@dataclass
class FrontendFee:
    bps: int
    recipient: str
```

- `bps` — fee in basis points of the output token, an integer in
  `[1, MAX_FEE_BPS]` (`MAX_FEE_BPS = 100`, i.e. 1%).
- `recipient` — receives the fee in `token_out`; must be a valid, non-zero
  address.

## QuoteOptions

Per-call options accepted by [`quote`](/python/router/quote).

```python
@dataclass
class QuoteOptions:
    overrides: ... = <attached source>
    bebop_default: bool = True
    venues: list[str] | None = None
```

- `overrides` — by default uses the router's attached overrides source. Replace
  it for this call with another `OverridesSource`, a fixed `OverridesSnapshot`,
  or `None` to quote raw on-chain state.
- `bebop_default` — set `False` to keep Bebop's raw on-chain slot instead of
  zeroing it when the snapshot has no Bebop entry (default `True`).
- `venues` — restrict the quote to these venues: a single entry quotes that
  venue directly, several pick the best among them. Must be non-empty when
  present.

## OverridesSnapshot

A parsed pAMM state-override payload, returned by every source's
`get_overrides()`.

```python
@dataclass
class OverridesSnapshot:
    block_number: int | None = None
    timestamp_ns: int | None = None
    per_pamm: dict[str, dict[str, dict[int, int]]] = ...
```

- `block_number` — block the overrides were generated against; quotes pin the
  simulation to it.
- `timestamp_ns` — generation time in nanoseconds since epoch; quotes pin the
  simulated `block.timestamp` to it.
- `per_pamm` — pAMM address → overridden contract → storage slot → value.

## OverridesSource

The abstract base both override sources implement — subclass it to plug in a
custom source.

```python
class OverridesSource(abc.ABC):
    async def get_overrides(self) -> OverridesSnapshot | None: ...
    async def close(self) -> None: ...  # optional teardown; default no-op
```

## PriceLevelsSnapshot

A parsed price-levels payload, returned by every source's `get_price_levels()`.

```python
@dataclass
class PriceLevelsSnapshot:
    block_number: int | None = None
    slot: int | None = None
    timestamp_ns: int | None = None
    pamms: list[PammPriceLevels] = ...
```

- `block_number` — block the levels were generated against.
- `slot` — beacon slot the levels were generated against.
- `timestamp_ns` — generation time in nanoseconds since epoch.
- `pamms` — per-pAMM order books.

## PammPriceLevels

One pAMM's price levels across all pairs it quotes.

```python
@dataclass
class PammPriceLevels:
    pamm: ChecksumAddress
    pairs: list[PairPriceLevels] = ...
```

## PairPriceLevels

The order book a pAMM quotes for one `token_in`/`token_out` pair.

```python
@dataclass
class PairPriceLevels:
    token_in: ChecksumAddress
    token_out: ChecksumAddress
    order_book: list[PriceLevel] = ...
```

## PriceLevel

One rung of a pair's order book.

```python
@dataclass
class PriceLevel:
    amount_in: int
    amount_out: int
    variant: Literal["Simulated", "Interpolated"]
```

- `amount_in` / `amount_out` — amounts in atomic units.
- `variant` — `"Simulated"` means the rung came from an EVM simulation;
  `"Interpolated"` from a linear spline between simulated rungs.

## TitanQuote

Result of `get_quote` / `get_quote_venue` (`titan_getPammQuote` /
`titan_getPammQuoteVenue`).

```python
@dataclass
class TitanQuote:
    token_in: ChecksumAddress
    token_out: ChecksumAddress
    amount_in: int
    amount_out: int
    pamm: ChecksumAddress
    router: ChecksumAddress
    block_number: int | None = None
    slot: int | None = None
    timestamp_ns: int | None = None
```

- `pamm` — pAMM that produced the quote.
- `router` — router associated with the quote.

## PriceLevelsSource

The abstract base both price-level sources implement — subclass it to plug in a
custom source.

```python
class PriceLevelsSource(abc.ABC):
    async def get_price_levels(self) -> PriceLevelsSnapshot: ...
    async def close(self) -> None: ...  # default no-op
```
