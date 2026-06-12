// deno-fmt-ignore-file
// biome-ignore format: generated types do not need formatting
// prettier-ignore
import type { PathsForPages } from 'waku/router'

// prettier-ignore
type Page =
  | { path: '/'; render: 'static' }
  | { path: '/propamms'; render: 'static' }
  | { path: '/propamms/makers'; render: 'static' }
  | { path: '/propamms/router'; render: 'static' }
  | { path: '/propamms/takers'; render: 'static' }
  | { path: '/rust/getting-started'; render: 'static' }
  | { path: '/rust/helpers'; render: 'static' }
  | { path: '/rust/installation'; render: 'static' }
  | { path: '/rust/overrides/rpc-source'; render: 'static' }
  | { path: '/rust/overrides/utilities'; render: 'static' }
  | { path: '/rust/overrides/ws-source'; render: 'static' }
  | { path: '/rust/router/allowance'; render: 'static' }
  | { path: '/rust/router/approve'; render: 'static' }
  | { path: '/rust/router/quote'; render: 'static' }
  | { path: '/rust/router/swap'; render: 'static' }
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
  | { path: '/typescript/router/quote'; render: 'static' }
  | { path: '/typescript/router/swap'; render: 'static' }
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
