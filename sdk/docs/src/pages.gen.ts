// deno-fmt-ignore-file
// biome-ignore format: generated types do not need formatting
// prettier-ignore
import type { PathsForPages } from 'waku/router'

// prettier-ignore
type Page =
  | { path: '/'; render: 'static' }
  | { path: '/rust/getting-started'; render: 'static' }
  | { path: '/rust/helpers'; render: 'static' }
  | { path: '/rust/installation'; render: 'static' }
  | { path: '/rust/overrides/rpc-source'; render: 'static' }
  | { path: '/rust/overrides/utilities'; render: 'static' }
  | { path: '/rust/overrides/ws-source'; render: 'static' }
  | { path: '/rust/router/allowance'; render: 'static' }
  | { path: '/rust/router/approve'; render: 'static' }
  | { path: '/rust/router/frontend_fee'; render: 'static' }
  | { path: '/rust/router/quote'; render: 'static' }
  | { path: '/rust/router/quote_selected_venues'; render: 'static' }
  | { path: '/rust/router/quote_uniswap_v3'; render: 'static' }
  | { path: '/rust/router/quote_venue'; render: 'static' }
  | { path: '/rust/router/swap'; render: 'static' }
  | { path: '/rust/router/swap_via_selected_venues'; render: 'static' }
  | { path: '/rust/router/swap_via_selected_venues_with_fee'; render: 'static' }
  | { path: '/rust/router/swap_via_venue'; render: 'static' }
  | { path: '/rust/router/swap_via_venue_with_fee'; render: 'static' }
  | { path: '/rust/router/swap_with_fee'; render: 'static' }
  | { path: '/rust/router/views'; render: 'static' }
  | { path: '/rust/router/wait_for_swap'; render: 'static' }
  | { path: '/rust/types'; render: 'static' }
  | { path: '/typescript/getting-started'; render: 'static' }
  | { path: '/typescript/helpers'; render: 'static' }
  | { path: '/typescript/installation'; render: 'static' }
  | { path: '/typescript/overrides/rpc-source'; render: 'static' }
  | { path: '/typescript/overrides/utilities'; render: 'static' }
  | { path: '/typescript/overrides/ws-source'; render: 'static' }
  | { path: '/typescript/router/allowance'; render: 'static' }
  | { path: '/typescript/router/approve'; render: 'static' }
  | { path: '/typescript/router/frontendFee'; render: 'static' }
  | { path: '/typescript/router/quote'; render: 'static' }
  | { path: '/typescript/router/quoteSelectedVenues'; render: 'static' }
  | { path: '/typescript/router/quoteUniswapV3'; render: 'static' }
  | { path: '/typescript/router/quoteVenue'; render: 'static' }
  | { path: '/typescript/router/swap'; render: 'static' }
  | { path: '/typescript/router/swapViaSelectedVenues'; render: 'static' }
  | { path: '/typescript/router/swapViaSelectedVenuesWithFee'; render: 'static' }
  | { path: '/typescript/router/swapViaVenue'; render: 'static' }
  | { path: '/typescript/router/swapViaVenueWithFee'; render: 'static' }
  | { path: '/typescript/router/swapWithFee'; render: 'static' }
  | { path: '/typescript/router/views'; render: 'static' }
  | { path: '/typescript/router/waitForSwap'; render: 'static' }
  | { path: '/typescript/types'; render: 'static' }

// prettier-ignore
declare module 'waku/router' {
  interface RouteConfig {
    paths: PathsForPages<Page>
  }
  interface CreatePagesConfig {
    pages: Page
  }
}
