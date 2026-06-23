//! Getting started: quote and swap 1 ETH for USDC through the best venue.
//!
//! Run:
//!
//!   cargo run --example getting_started
//!
//! Defaults target a local anvil mainnet fork (`anvil --fork-url <mainnet rpc>`)
//! with anvil's default funded account and the mainnet router deployment.
//! Override with RPC_URL / PRIVATE_KEY / ROUTER_ADDRESS / SLIPPAGE_BPS.
//!
//! Note: quotes automatically apply fresh pAMM state overrides (streamed from
//! Titan), but a fork still *executes* swaps against its frozen state — if the
//! swap reverts with `InsufficientOutput` there, raise SLIPPAGE_BPS (live
//! chains fill at the quoted state normally).

use propamm::common::helpers::{
    apply_slippage, deadline_in, format_ether, format_units, parse_address, parse_ether,
};
use propamm::common::tokens::{ETH_SENTINEL, USDC};
use propamm::router::SwapParams;
use propamm::{ContractClient, PropAmmRouter};

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

    let client = ContractClient::connect_with_signer(&rpc_url, &private_key)?;
    let me = client.signer_address().expect("signer configured");
    let router = PropAmmRouter::new(client, router_address);

    let amount_in = parse_ether("1")?;
    let quote = router.quote(ETH_SENTINEL, USDC, amount_in).await?;
    println!(
        "quote: {} ETH -> {} USDC via {:#x}",
        format_ether(amount_in),
        format_units(quote.amount_out, 6),
        quote.venue
    );

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
        "swapped: received {} USDC via {:#x} (tx {:#x})",
        format_units(result.amount_out, 6),
        result.executed_venue,
        result.hash
    );

    Ok(())
}
