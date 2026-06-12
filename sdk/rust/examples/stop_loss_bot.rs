//! Stop-loss bot: sell a fixed amount of ETH the moment its quote drops below a
//! threshold.
//!
//! Run:
//!
//!   cargo run --example stop_loss_bot
//!
//! We hold ETH and poll the router for how much USDC `AMOUNT_IN` ETH would fetch
//! right now. The first time that quote falls below `THRESHOLD` USDC we sell the
//! whole amount and exit. Configure with AMOUNT_IN / THRESHOLD / POLL_SECS (and
//! the usual RPC_URL / PRIVATE_KEY / ROUTER_ADDRESS / SLIPPAGE_BPS).
//!
//! Defaults target a local anvil mainnet fork (`anvil --fork-url <mainnet rpc>`)
//! with anvil's default funded account and the mainnet router deployment.
//!
//! Note: quotes automatically apply fresh pAMM state overrides (streamed from
//! Titan), but a fork still *executes* swaps against its frozen state — if the
//! swap reverts with `InsufficientOutput` there, raise SLIPPAGE_BPS (live
//! chains fill at the quoted state normally).

use std::time::Duration;

use propamm_sdk::common::helpers::{
    apply_slippage, deadline_in, format_ether, format_units, parse_address, parse_ether,
    parse_units,
};
use propamm_sdk::common::tokens::{ETH_SENTINEL, USDC};
use propamm_sdk::router::SwapParams;
use propamm_sdk::{ContractClient, PropAmmRouter};

/// USDC has 6 decimals; THRESHOLD and quote outputs are denominated in it.
const USDC_DECIMALS: u32 = 6;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let rpc_url = std::env::var("RPC_URL").unwrap_or_else(|_| "http://localhost:8545".into());
    // anvil's default funded account #0
    let private_key = std::env::var("PRIVATE_KEY").unwrap_or_else(|_| {
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80".into()
    });
    // mainnet router deployment
    let router_address = parse_address(
        &std::env::var("ROUTER_ADDRESS")
            .unwrap_or_else(|_| "0x4DdF368080CD7946db5b459aD591c350158175e1".into()),
    )?;
    let slippage_bps: u32 = std::env::var("SLIPPAGE_BPS")
        .unwrap_or_else(|_| "50".into())
        .parse()?;

    // Bot strategy: sell AMOUNT_IN ETH once a quote dips below THRESHOLD USDC.
    let amount_in = parse_ether(&std::env::var("AMOUNT_IN").unwrap_or_else(|_| "1".into()))?;
    let threshold = parse_units(
        &std::env::var("THRESHOLD").unwrap_or_else(|_| "1600".into()),
        USDC_DECIMALS,
    )?;
    let poll = Duration::from_secs(
        std::env::var("POLL_SECS")
            .unwrap_or_else(|_| "1".into())
            .parse()?,
    );

    let client = ContractClient::connect_with_signer(&rpc_url, &private_key)?;
    let me = client.signer_address().expect("signer configured");
    
    // `PropAmmRouter::new` attaches Titan's streaming overrides source by default, so quotes
    // price against fresh off-chain pAMM liquidity
    let router = PropAmmRouter::new(client, router_address);

    println!(
        "watching: sell {} ETH when its quote drops below {} USDC (every {}s)",
        format_ether(amount_in),
        format_units(threshold, USDC_DECIMALS),
        poll.as_secs(),
    );

    // Poll until the quote crosses the threshold
    let quote = loop {
        let quote = router.quote(ETH_SENTINEL, USDC, amount_in).await?;
        println!(
            "quote: {} ETH -> {} USDC",
            format_ether(amount_in),
            format_units(quote.amount_out, USDC_DECIMALS),
        );
        if quote.amount_out < threshold {
            break quote;
        }
        tokio::time::sleep(poll).await;
    };

    // Sell ETH at the quoted price, applying the given slippage
    let result = router
        .swap_and_wait(&SwapParams {
            token_in: ETH_SENTINEL,
            token_out: USDC,
            amount_in,
            amount_out_min: apply_slippage(quote.amount_out, slippage_bps)?,
            recipient: me,
            deadline: deadline_in(300), // now + 5 min
        })
        .await?;
    println!(
        "sold: received {} USDC via {:#x} (tx {:#x})",
        format_units(result.amount_out, USDC_DECIMALS),
        result.executed_venue,
        result.hash,
    );

    Ok(())
}
