# Getting started

Once the SDK is [installed](/python/installation), a quote and swap is a
client, a router, and two calls.

## Quote and swap

```python
import asyncio

from propamm import ContractClient, PropAmmRouter, SwapParams
from propamm.common.accounts import account_from_key
from propamm.common.helpers import apply_slippage, deadline_in, format_units, parse_ether
from propamm.common.tokens import ETH_SENTINEL, USDC


async def main():
    account = account_from_key("0x...")
    client = ContractClient("https://...", account=account)
    # ContractClient("https://...") for a read-only client (quotes and views still work)
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
    print(f"received {format_units(result.amount_out, 6)} USDC via {result.executed_venue}")


asyncio.run(main())
```

The quote already reflects fresh off-chain liquidity — pAMM state overrides
are applied automatically. Native ETH input is signalled with `ETH_SENTINEL`
(no ERC-20 approval needed; `msg.value` is attached automatically).
