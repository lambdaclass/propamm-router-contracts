"""Getting started: quote and swap 1 ETH for USDC through the best venue.

Install the SDK first, then run:

    pip install -e .
    python examples/getting_started.py

Defaults target a local anvil mainnet fork (`anvil --fork-url <mainnet rpc>`)
with anvil's default funded account and the mainnet router deployment.
Override with RPC_URL / PRIVATE_KEY / ROUTER_ADDRESS / SLIPPAGE_BPS.

Note: quotes automatically apply fresh pAMM state overrides (streamed from
Titan), but a fork still *executes* swaps against its frozen state — if the
swap reverts with `InsufficientOutput` there, raise SLIPPAGE_BPS (live chains
fill at the quoted state normally).
"""

from __future__ import annotations

import asyncio
import os

from propamm_sdk import ContractClient, PropAmmRouter, SwapParams
from propamm_sdk.common.accounts import account_from_key
from propamm_sdk.common.helpers import (
    apply_slippage,
    deadline_in,
    format_ether,
    format_units,
    parse_ether,
)
from propamm_sdk.common.tokens import ETH_SENTINEL, USDC

USDC_DECIMALS = 6

RPC_URL = os.getenv("RPC_URL", "http://localhost:8545")
# anvil's default funded account #0
PRIVATE_KEY = os.getenv(
    "PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
)
# mainnet router deployment
ROUTER_ADDRESS = os.getenv("ROUTER_ADDRESS", "0x4DdF368080CD7946db5b459aD591c350158175e1")
SLIPPAGE_BPS = int(os.getenv("SLIPPAGE_BPS", "50"))


async def main() -> None:
    account = account_from_key(PRIVATE_KEY)
    client = ContractClient(RPC_URL, account=account)
    router = PropAmmRouter(client, ROUTER_ADDRESS)

    amount_in = parse_ether("1")
    quote = await router.quote(ETH_SENTINEL, USDC, amount_in)
    print(
        f"quote: {format_ether(amount_in)} ETH -> "
        f"{format_units(quote.amount_out, USDC_DECIMALS)} USDC via {quote.venue}"
    )

    result = await router.swap_and_wait(
        SwapParams(
            token_in=ETH_SENTINEL,
            token_out=USDC,
            amount_in=amount_in,
            amount_out_min=apply_slippage(quote.amount_out, SLIPPAGE_BPS),
            recipient=account.address,
            deadline=deadline_in(300),  # now + 5 min
        )
    )
    print(
        f"swapped: received {format_units(result.amount_out, USDC_DECIMALS)} USDC "
        f"via {result.executed_venue} (tx {result.hash})"
    )

    await router.overrides.close()


if __name__ == "__main__":
    asyncio.run(main())
