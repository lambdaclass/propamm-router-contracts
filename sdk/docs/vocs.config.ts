import { defineConfig } from "vocs";

export default defineConfig({
  title: "PropAMM SDK",
  description: "SDKs for interacting with the PropAMM contracts",
  // Set by the Pages deploy workflow (project sites serve at /<repo>/).
  basePath: process.env.BASE_PATH,
  theme: {
    accentColor: "#8051e7",
  },
  socials: [
    {
      icon: "github",
      link: "https://github.com/lambdaclass/propamm-router-contracts",
    },
  ],
  sidebar: [
    { text: "Introduction", link: "/" },
    {
      text: "TypeScript SDK",
      collapsed: false,
      items: [
        { text: "Getting started", link: "/typescript/getting-started" },
        {
          text: "Quotes",
          collapsed: true,
          items: [
            { text: "quote", link: "/typescript/router/quote" },
            { text: "quoteVenue", link: "/typescript/router/quoteVenue" },
            { text: "quoteSelectedVenues", link: "/typescript/router/quoteSelectedVenues" },
            { text: "quoteUniswapV3", link: "/typescript/router/quoteUniswapV3" },
          ],
        },
        {
          text: "Swaps",
          collapsed: true,
          items: [
            { text: "swap", link: "/typescript/router/swap" },
            { text: "swapWithFee", link: "/typescript/router/swapWithFee" },
            { text: "swapViaVenue", link: "/typescript/router/swapViaVenue" },
            { text: "swapViaVenueWithFee", link: "/typescript/router/swapViaVenueWithFee" },
            { text: "swapViaSelectedVenues", link: "/typescript/router/swapViaSelectedVenues" },
            {
              text: "swapViaSelectedVenuesWithFee",
              link: "/typescript/router/swapViaSelectedVenuesWithFee",
            },
            { text: "waitForSwap", link: "/typescript/router/waitForSwap" },
            { text: "frontendFee", link: "/typescript/router/frontendFee" },
          ],
        },
        {
          text: "Router",
          collapsed: true,
          items: [
            { text: "approve", link: "/typescript/router/approve" },
            { text: "allowance", link: "/typescript/router/allowance" },
            { text: "Views", link: "/typescript/router/views" },
          ],
        },
        {
          text: "State overrides",
          collapsed: true,
          items: [
            { text: "OverridesWsSource", link: "/typescript/overrides/ws-source" },
            { text: "OverridesRpcSource", link: "/typescript/overrides/rpc-source" },
            { text: "Utilities", link: "/typescript/overrides/utilities" },
          ],
        },
        { text: "Helpers", link: "/typescript/helpers" },
        { text: "Types", link: "/typescript/types" },
      ],
    },
    {
      text: "Rust SDK",
      collapsed: false,
      items: [
        { text: "Getting started", link: "/rust/getting-started" },
        {
          text: "Quotes",
          collapsed: true,
          items: [
            { text: "quote", link: "/rust/router/quote" },
            { text: "quote_venue", link: "/rust/router/quote_venue" },
            { text: "quote_selected_venues", link: "/rust/router/quote_selected_venues" },
            { text: "quote_uniswap_v3", link: "/rust/router/quote_uniswap_v3" },
          ],
        },
        {
          text: "Swaps",
          collapsed: true,
          items: [
            { text: "swap", link: "/rust/router/swap" },
            { text: "swap_with_fee", link: "/rust/router/swap_with_fee" },
            { text: "swap_via_venue", link: "/rust/router/swap_via_venue" },
            { text: "swap_via_venue_with_fee", link: "/rust/router/swap_via_venue_with_fee" },
            { text: "swap_via_selected_venues", link: "/rust/router/swap_via_selected_venues" },
            {
              text: "swap_via_selected_venues_with_fee",
              link: "/rust/router/swap_via_selected_venues_with_fee",
            },
            { text: "wait_for_swap", link: "/rust/router/wait_for_swap" },
            { text: "frontend_fee", link: "/rust/router/frontend_fee" },
          ],
        },
        {
          text: "Router",
          collapsed: true,
          items: [
            { text: "approve", link: "/rust/router/approve" },
            { text: "allowance", link: "/rust/router/allowance" },
            { text: "Views", link: "/rust/router/views" },
          ],
        },
        {
          text: "State overrides",
          collapsed: true,
          items: [
            { text: "OverridesWsSource", link: "/rust/overrides/ws-source" },
            { text: "OverridesRpcSource", link: "/rust/overrides/rpc-source" },
            { text: "Utilities", link: "/rust/overrides/utilities" },
          ],
        },
        { text: "Helpers", link: "/rust/helpers" },
        { text: "Types", link: "/rust/types" },
      ],
    },
  ],
});
