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
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest
ruff check .
```

## Getting started

Quote and swap 1 ETH for USDC through the best venue:

```python
import asyncio
from propamm_sdk import ContractClient, PropAmmRouter, SwapParams
from propamm_sdk.common.accounts import account_from_key
from propamm_sdk.common.helpers import apply_slippage, deadline_in, parse_ether
from propamm_sdk.common.tokens import ETH_SENTINEL, USDC

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

A runnable version lives in [`examples/getting_started.py`](examples/getting_started.py):

```sh
python examples/getting_started.py
```

It defaults to a local anvil mainnet fork (`anvil --fork-url <mainnet rpc>`)
with anvil's default funded account and the mainnet router deployment. Override
with `RPC_URL` / `PRIVATE_KEY` / `ROUTER_ADDRESS` / `SLIPPAGE_BPS`.

## Layout

| Module | Purpose |
| --- | --- |
| `propamm_sdk.client` | `ContractClient`: `AsyncWeb3` wrapper (`contract` / `call_with_overrides` / `send` / `wait_for_transaction`). |
| `propamm_sdk.router` | `PropAmmRouter` bindings: quotes, swaps, ERC-20, views. |
| `propamm_sdk.router.abi` | Vendored router ABI and custom-error naming. |
| `propamm_sdk.overrides` | pAMM state-override sources (`OverridesRpcSource`, `OverridesWsSource`). |
| `propamm_sdk.common` | `tokens`, `pamms`, `helpers`, `accounts`. |

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
