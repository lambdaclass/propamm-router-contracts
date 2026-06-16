# PropAMM Python SDK

SDK for interacting with the `PropAMMRouter` contract over JSON-RPC, built on
[web3.py](https://web3py.readthedocs.io/) (`AsyncWeb3` transport, signing,
`eth_call` with state overrides) and [`eth-abi`](https://github.com/ethereum/eth-abi)
for ABI encoding/decoding (signature strings; selectors are regression-tested
against `forge inspect PropAMMRouter methodIdentifiers`). Mirrors the
TypeScript (`../typescript`) and Rust (`../rust`) SDKs: same surface,
snake_case names, no on-chain `V1` suffix. Fully async (`asyncio`).

`eth_call` with a block override (the 4th RPC parameter) is not exposed by
web3.py's `eth.call`, so override-carrying quote calls go through a raw
`provider.make_request("eth_call", …)` and decode/handle errors in
`ContractClient.call`. Reverts are re-shaped into `RevertError` carrying the
raw payload so the router bindings can decode named contract errors from it.

## Setup

```sh
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest          # incl. ABI selector & overrides regression tests
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


async def main():
    account = account_from_key("0x...")
    client = ContractClient("https://...", account=account)
    router = PropAmmRouter(client, "0x...")  # deployed router proxy

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
| `propamm_sdk.client` | `ContractClient`: `AsyncWeb3` wrapper (`call` / `send` / `wait_for_transaction`). |
| `propamm_sdk.router` | `PropAmmRouter` bindings: quotes, swaps, ERC-20, views. |
| `propamm_sdk.router.abi` | Router ABI signature strings + custom-error table. |
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
