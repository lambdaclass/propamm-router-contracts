# swap

Swap through the best-quoting venue; falls back to Uniswap V3 if the chosen
venue fails to fill. Returns the transaction hash — pair with
[`wait_for_swap`](/python/router/wait_for_swap), or use `swap_and_wait` to do
both in one call.

```python
async def swap(self, params: SwapParams, opts: SwapOptions | None = None) -> str
async def swap_and_wait(self, params: SwapParams, opts: SwapOptions | None = None) -> SwapResult
```

## Usage

::: code-group

```python [example.py]
from propamm import SwapParams
from propamm.common.helpers import apply_slippage, deadline_in, parse_ether
from propamm.common.tokens import ETH_SENTINEL, USDC
from config import account, router

amount_in = parse_ether("1")
quote = await router.quote(ETH_SENTINEL, USDC, amount_in)

tx_hash = await router.swap(
    SwapParams(
        token_in=ETH_SENTINEL,
        token_out=USDC,
        amount_in=amount_in,
        amount_out_min=apply_slippage(quote.amount_out, 50),
        recipient=account.address,
        deadline=deadline_in(300),
    )
)
```

```python [config.py]
from propamm import ContractClient, PropAmmRouter
from propamm.common.accounts import account_from_key

account = account_from_key("0x...")
client = ContractClient("https://...", account=account)
router = PropAmmRouter(client, "0x...")
```

:::

## Returns

`str`

The transaction hash. Gas is estimated before sending, so reverts surface as
errors without spending gas.

## swap_and_wait

Same parameters; additionally waits for the receipt and decodes the outcome.
Returns [`SwapResult`](/python/router/wait_for_swap#returns).

```python
result = await router.swap_and_wait(SwapParams(...))
```

## Parameters

### params

- **Type:** [`SwapParams`](/python/types#swapparams)

The parameters shared by every swap entrypoint — see the type for
field-by-field docs. Derive `amount_out_min` from a quote with
`apply_slippage`, and `deadline` with `deadline_in`.

```python
tx_hash = await router.swap(
    SwapParams(
        # ...
        amount_out_min=apply_slippage(quote.amount_out, 50),  # quote - 0.5%
    )
)
```

### opts (optional)

- **Type:** [`SwapOptions`](/python/types#swapoptions)

Per-swap options: restrict the venues and/or charge a frontend fee.

`venues` restricts the swap: a single entry executes through that venue
directly (raising `UnknownVenue` on a non-venue address), several re-quote
on-chain and fill via the best of them. Must be non-empty when present; omit
to swap through the best-quoting venue overall.

```python
from propamm import SwapOptions
from propamm.common.pamms import BEBOP, FERMI, KIPSELI

# exactly this venue
tx_hash = await router.swap(params, SwapOptions(venues=[KIPSELI]))

# best of a subset
tx_hash2 = await router.swap(params, SwapOptions(venues=[FERMI, BEBOP]))
```

`frontend_fee` skims a fee from the output token, paid to its `recipient`.
`bps` must be an integer in `[1, MAX_FEE_BPS]` (100 = 1%) — validated before
sending. With a fee, `amount_out_min` is the **net** minimum the recipient
must receive after the fee, and the decoded result's `fee` field (via
[`wait_for_swap`](/python/router/wait_for_swap)) carries the charged amount and
recipient.

```python
from propamm import FrontendFee, SwapOptions

tx_hash = await router.swap(
    params,
    SwapOptions(frontend_fee=FrontendFee(bps=25, recipient="0x...")),  # 0.25%
)
```

`gas_limit` sets an explicit transaction gas limit, overriding the per-function
default described below.

```python
tx_hash = await router.swap(params, SwapOptions(gas_limit=800_000))
```

## Gas limits

Swaps attach a **hardcoded per-function gas limit** and skip node gas
estimation. Estimation runs against the current state, but the swap can take a
heavier branch when it executes, so an estimate can under-shoot and the
transaction runs out of gas. The hardcoded limits sit above the worst observed
branch (plus headroom), and are tiered by how much quoting each entrypoint does
on-chain (a single named venue is cheapest; the all-venues requote is highest).

Pass [`SwapOptions.gas_limit`](/python/types#swapoptions) to override the
default for a call.
