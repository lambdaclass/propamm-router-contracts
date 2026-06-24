//! pAMM price levels: Titan's pre-quoted prices for a range of trade sizes,
//! grouped per pAMM. Served from Titan's latest snapshot over HTTP (no node
//! RPC, no key), unlike `router.quote`, which runs an on-chain `eth_call`.
//!
//! Run:
//!
//!   cargo run --example price_levels
//!
//! Set PRICE_LEVELS_URL to use a specific HTTP endpoint.

use std::sync::Arc;

use propamm::common::helpers::{format_units, parse_address};
use propamm::common::pamms::PAMMS;
use propamm::common::tokens::{USDC, USDT, WETH};
use propamm::prices::{PriceLevels, PriceLevelsRpcSource};
use propamm::{Address, U256};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // PriceLevels defaults to a one-shot HTTP snapshot source. Set
    // PRICE_LEVELS_URL to point snapshots and quotes at a specific endpoint.
    let prices = match std::env::var("PRICE_LEVELS_URL") {
        Ok(url) => PriceLevels::with_source(Arc::new(PriceLevelsRpcSource::new(url))),
        Err(_) => PriceLevels::new(),
    };

    // 1. Full snapshot: every pAMM's order book.
    let snapshot = prices.get_price_levels().await?;
    println!(
        "snapshot @ block {} — {} pAMM(s)",
        snapshot
            .block_number
            .map_or_else(|| "?".to_string(), |b| b.to_string()),
        snapshot.pamms.len()
    );

    // Pick the first pAMM/pair that carries an order book to display.
    let Some((pamm, pair)) = snapshot.pamms.iter().find_map(|entry| {
        entry
            .pairs
            .iter()
            .find(|pair| !pair.order_book.is_empty())
            .map(|pair| (entry.pamm, pair))
    }) else {
        return Err("snapshot carried no order books".into());
    };

    println!(
        "\n{} order book: {} -> {}",
        venue_name(pamm),
        token_symbol(pair.token_in),
        token_symbol(pair.token_out),
    );
    for level in &pair.order_book {
        println!(
            "  {} -> {}  [{:?}]",
            fmt(level.amount_in, pair.token_in),
            fmt(level.amount_out, pair.token_out),
            level.variant,
        );
    }

    // 2. Quote helpers, for that pair and a mid-ladder size. `get_quote`
    // returns the best across all pAMMs; `get_quote_venue` pins to one.
    let size = pair.order_book[pair.order_book.len() / 2].amount_in;

    let best = prices
        .get_quote(pair.token_in, pair.token_out, size)
        .await?;
    println!(
        "\nbest quote:  {} -> {} via {}",
        fmt(best.amount_in, best.token_in),
        fmt(best.amount_out, best.token_out),
        venue_name(best.pamm),
    );

    let pinned = prices
        .get_quote_venue(pamm, pair.token_in, pair.token_out, size)
        .await?;
    println!(
        "{} quote: {} -> {}",
        venue_name(pamm),
        fmt(pinned.amount_in, pinned.token_in),
        fmt(pinned.amount_out, pinned.token_out),
    );

    Ok(())
}

/// Known tokens, for readable amounts. Unknown tokens print raw (0 decimals).
fn token_info(token: Address) -> (String, u32) {
    let wbtc = parse_address("0x2260fac5e5542a773aa44fbcfedf7c193bc2c599").unwrap();
    if token == USDC {
        ("USDC".into(), 6)
    } else if token == USDT {
        ("USDT".into(), 6)
    } else if token == WETH {
        ("WETH".into(), 18)
    } else if token == wbtc {
        ("WBTC".into(), 8)
    } else {
        (format!("{token:#x}"), 0)
    }
}

fn token_symbol(token: Address) -> String {
    token_info(token).0
}

fn fmt(amount: U256, token: Address) -> String {
    let (symbol, decimals) = token_info(token);
    format!("{} {}", format_units(amount, decimals), symbol)
}

/// Map a venue address back to its readable pAMM name, or its raw hex.
fn venue_name(address: Address) -> String {
    PAMMS
        .iter()
        .find(|(_, a)| *a == address)
        .map_or_else(|| format!("{address:#x}"), |(name, _)| name.to_string())
}
