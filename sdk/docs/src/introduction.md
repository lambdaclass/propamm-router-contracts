# Introduction

SDKs for interacting with the `PropAMMRouter` contract: quote and execute
single-hop swaps across proprietary AMM venues, with a Uniswap V3 fallback.

Two implementations with the same surface:

- **[TypeScript](typescript/getting-started.md)** (`sdk/typescript`) — built on [viem](https://viem.sh).
- **[Rust](rust/getting-started.md)** (`sdk/rust`) — built on [rex](https://github.com/lambdaclass/rex) / [ethrex](https://github.com/lambdaclass/ethrex).

Both apply fresh [pAMM state overrides](concepts/state-overrides.md) to
quotes automatically, so quoted prices reflect off-chain liquidity instead of
stale on-chain state.
