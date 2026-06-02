# PropAMM Interface rationale

This document contains the rationale for some of the propAMM interface design decisions, based on feedback we received for it. Each item is a common piece of feedback we received and the way we addressed it.

## Formalize events emitted by PropAMMs

Our first version of the propAMM's interface did not contain any events. We added one to be emitted when the propAMM does a swap. Its signature is the following:

```
/// @notice Emitted once per successful swap after `tokenOut` is delivered to `recipient`.
/// @param sender The address that invoked the swap entrypoint and supplied
/// `amountIn` of `tokenIn`. Indexed so consumers can fetch a given account's
/// recent swaps.
/// @param tokenIn The token sold.
/// @param tokenOut The token bought.
/// @param amountIn The exact amount of `tokenIn` pulled from `sender`.
/// @param amountOut The amount of `tokenOut` delivered to `recipient`,
/// measured as a balance delta.
/// @param recipient The address that received `tokenOut`.
event Swapped(
    address indexed sender,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    address recipient
);
```

On the router we don't actually consume this event in any way, and we also emit our own, identical to this one but with an added `marketMaker` value specifying the venue the swap went through. That said, we do believe it's good that the propAMMs have their own standardized version of it, since not every swap may go through our router.

## Expiry/deadline parameters for swaps

Most AMMs like uniswap provide a `deadline` parameter (a unix timestamp) used to impose a TTL on swaps, making them revert after the `deadline` has passed. This is very useful and we provide it ourselves on the router.

However, we believe this is good feedback and have added the parameter to the propAMM interface as well, since (as with the previous item) it's possible that there are calls to them that do not go through our router; in those cases, the propAMM may want to check the `deadline` themselves.


## Return `amountOut` on the swap function

Straightforward feedback that makes perfect sense. We have added the `amountOut` return parameter on every swap function. Note, however, that on the router we do not use it; we check ourselves the balance before and after to remove trust assumptions.

## `Active` vs `Unlocked` statuses for token pairs

Some propAMMs differentiate between an `active` and an `unlocked` token pair. A pair not being `active` means trading for the pair is halted/paused, but oracle updates may still come through. A pair being `locked` means oracle updates are paused.

On the router, we do not care about this distinction. For us, a pair being `active` means we can consider it for swapping, it being `inactive` that we can rule it out entirely without having to requote on-chain. Any other distinction is something individual propAMMs can track internally, but that we do not need exposed to us.

## Including `msg.sender` as a parameter to `quote()` and `swap()`

Adding a `sender` parameter function is an odd choice, since it's a trust boundary where the `swap`/`quote` function is trusting that the caller is supplying the correct value. On top of that, no propAMM currently makes use of a `sender`  parameter, so it's not clear what its use would be. For these reasons, we believe it's better to leave it out, and did not include it.

## Add a `PairListed` event to track active pairs for propAMMs

The idea behind this is to make propAMMs emit an event whenever they add a new pair or when they change it from inactive to active. This way aggregators get an easy way to track active pairs. While this sounds good, this can already be done by calling the `getPairs()` function or querying individual ones with `isActive(pair)`. 

Doing this tracking through events is a problem because, a priori, the fact that a pair is active or not for a specific AMM can be arbitrary logic, dependent upon the current state of the chain. An event cannot properly capture this dynamic nature of the `active`/`inactive` status.

Because of these reasons, we decided not to add this event.

## Add the ERC20 symbols to the `TokenPair` struct

While this sounds like a QoL/convenient thing to have, so people calling `getPairs` could get token symbols directly, we believe it is better to leave the work of resolving symbols to the services that consume the `getPairs` function off-chain. It's a very simple thing to do and relieves us from having to do string manipulation on our function, dealing with possible symbol invalidation, etc.

Basically, services can call `getPairs` and then immediately resolve the token addresses to their corresponding symbol easily on their side.
