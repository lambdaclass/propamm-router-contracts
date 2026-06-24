# PropAMM Python SDK

An async Python SDK for the `PropAMMRouter` contract, built on
[web3.py](https://web3py.readthedocs.io/). 
Features:
- **Typed router bindings**: quote and swap across all whitelisted venues, a
  single venue, or a chosen subset, plus the router's views and ERC-20 approvals.
- **Accurate quotes**: quotes automatically apply fresh pAMM state overrides,
  so they price live off-chain liquidity rather than stale on-chain state.
- **Helpers**: amount/unit conversion, slippage, deadlines, and well-known
  token and venue addresses.
- **A typed error hierarchy**: contract reverts surface as human-readable
  errors (e.g. `InsufficientOutput(...)`).

Method names drop the on-chain `V1` suffix (`router.swap(...)` calls `swapV1`).
A client is read-only by default; pass an account to send transactions.

## Setup

Using [uv](https://docs.astral.sh/uv/) (installs the exact pinned versions from `uv.lock`):

```sh
uv sync --extra dev
uv run pytest          # incl. ABI selector & overrides regression tests
uv run ruff check .
```

Using pip (resolves the dependency ranges in `pyproject.toml`):

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest
ruff check .
```

## Getting started

Quote and swap 1 ETH for USDC through the best venue:

```python
import asyncio
from propamm import ContractClient, PropAmmRouter, SwapParams
from propamm.common.accounts import account_from_key
from propamm.common.helpers import apply_slippage, deadline_in, parse_ether
from propamm.common.tokens import ETH_SENTINEL, USDC

PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" # anvil rich account
RPC_URL = "http://localhost:8545" # local anvil instance
ROUTER_ADDRESS = "0x4DdF368080CD7946db5b459aD591c350158175e1" # mainnet router deployment

async def main():
    account = account_from_key(PRIVATE_KEY)
    client = ContractClient(RPC_URL, account=account)
    router = PropAmmRouter(client, ROUTER_ADDRESS)

    amount_in = parse_ether("1")
    quote = await router.quote(ETH_SENTINEL, USDC, amount_in)

    result = await router.swap_and_wait(
        SwapParams(
            token_in=ETH_SENTINEL,
            token_out=USDC,
            amount_in=amount_in,
            amount_out_min=apply_slippage(quote.amount_out, 50),  # quote - 0.5%
            recipient=account.address,
            deadline=deadline_in(300),  # now + 5 min
        )
    )
    print(f"received {result.amount_out} USDC via {result.executed_venue}")


asyncio.run(main())
```

A runnable version lives in [`examples/getting_started.py`](examples/getting_started.py).

```sh
python3 examples/getting_started.py
```

It defaults to a local anvil mainnet fork (`anvil --fork-url <mainnet rpc>`)
with anvil's default funded account and the mainnet router deployment. Override
with `RPC_URL` / `PRIVATE_KEY` / `ROUTER_ADDRESS` / `SLIPPAGE_BPS`.

## Layout

| Module | Purpose |
| --- | --- |
| `propamm.client` | `ContractClient`: `AsyncWeb3` wrapper (`contract` / `call_with_overrides` / `send` / `wait_for_transaction`). |
| `propamm.router` | `PropAmmRouter` bindings: quotes, swaps, ERC-20, views. |
| `propamm.router.abi` | Vendored router ABI and custom-error naming. |
| `propamm.overrides` | pAMM state-override sources (`OverridesRpcSource`, `OverridesWsSource`). |
| `propamm.prices` | `PriceLevels` client + price-level sources (`PriceLevelsRpcSource`, `PriceLevelsWsSource`) and the Titan quote helpers. |
| `propamm.common` | `tokens`, `pamms`, `helpers`, `accounts`. |

## Quotes & state overrides

Quote functions are nonpayable on-chain (not `view`), so they run through
`eth_call` simulation. By default each quote attaches the latest pAMM state
overrides (streamed from Titan via `OverridesWsSource`) plus the snapshot's
block number/timestamp, so venues price fresh off-chain liquidity. Pass
`QuoteOptions(overrides=None)` to quote without overrides, or supply your own
`OverridesSource` / `OverridesSnapshot`.

> Note: quotes apply fresh overrides, but a fork still *executes* swaps against
> its frozen state — if a swap reverts with `InsufficientOutput` on a fork,
> raise the slippage. Live chains fill at the quoted state normally.

## Price levels

Alongside the raw state overrides, Titan publishes prices it has *already
quoted*, grouped per pAMM: for each pair, an `order_book` of rungs mapping an
input amount to the output it would receive. This lets a taker read prices
across a range of trade sizes without an `eth_call` per size. Rungs are either
`Simulated` (from an EVM simulation) or `Interpolated` (a linear spline between
simulated rungs, for finer granularity).

The `PriceLevels` client wraps it, mirroring `PropAmmRouter`: a single class
with a default snapshot source you can override.

```python
from propamm import PriceLevels
from propamm.common.helpers import parse_units
from propamm.common.tokens import USDC, WETH

prices = PriceLevels()  # default: one-shot HTTP snapshot source

snapshot = await prices.get_price_levels()
# snapshot.pamms[i].pairs[j].order_book -> [PriceLevel(amount_in, amount_out, variant), ...]

# Quote helpers are served from Titan's latest snapshot over HTTP, skipping the
# on-chain eth_call that router.quote runs.
best = await prices.get_quote(USDC, WETH, parse_units("1000", 6))
# TitanQuote(token_in, token_out, amount_in, amount_out, pamm, router, block_number, slot, ...)
pinned = await prices.get_quote_venue(best.pamm, USDC, WETH, parse_units("1000", 6))
```

The snapshot source defaults to a `PriceLevelsRpcSource` (one
`titan_getPammPriceLevels` call per `get_price_levels`). For a live feed, pass a
`PriceLevelsWsSource` instead — it streams complete snapshots, reconnects with
backoff, and idle auto-closes, like `OverridesWsSource`. The stream is served
from regional hosts (`eu.`, `ap.`, `us.`); pick the nearest:

```python
from propamm import PriceLevels, PriceLevelsWsSource

prices = PriceLevels(
    PriceLevelsWsSource("wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels")
)
snapshot = await prices.get_price_levels()  # served from the live stream
await prices.close()  # close the stream socket when done (no-op for the HTTP default)
```

Passing a `PriceLevelsRpcSource` with a custom URL instead points both the
snapshots and the quote helpers at that endpoint (the quotes are HTTP-only).

A runnable version lives in [`examples/price_levels.py`](examples/price_levels.py)
(`python3 examples/price_levels.py`; override the HTTP endpoint with `PRICE_LEVELS_URL`).
