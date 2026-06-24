import { defineConfig } from "vitepress";

// `base` is set by the Pages deploy workflow (project sites serve at /<repo>/).
// VitePress requires a leading and trailing slash, so normalize BASE_PATH.
const base = process.env.BASE_PATH ? `${process.env.BASE_PATH}/` : "/";

export default defineConfig({
  title: "PropAMM SDK",
  description: "SDKs for interacting with the PropAMM contracts",
  base,
  // Content lives under src/pages/; routes mirror the file tree.
  srcDir: "src/pages",
  // Extensionless URLs (matches the previous vocs site; GitHub Pages resolves
  // `/foo` -> `foo.html`).
  cleanUrls: true,
  themeConfig: {
    search: {
      provider: "local",
      options: {
        // Same page names exist under both SDKs (e.g. `quote`), so a bare
        // search result can't tell TypeScript from Rust. Prefix the first
        // heading's text with the SDK tag in the search index only (the
        // rendered page is unaffected) so results read e.g. "[Rust] quote".
        _render(src, env, md) {
          const html = md.render(src, env);
          if (env.frontmatter?.search === false) return "";
          const path = env.relativePath ?? "";
          const sdk = path.startsWith("typescript/")
            ? "TypeScript"
            : path.startsWith("rust/")
              ? "Rust"
              : path.startsWith("python/")
                ? "Python"
                : "";
          if (!sdk) return html;
          // Inject the tag before the heading's anchor link, so the splitter
          // picks it up as part of the section title.
          return html.replace(
            /(<h[1-6][^>]*>)(.*?)(<a\b)/i,
            (_match, open, text, anchor) => `${open}[${sdk}] ${text}${anchor}`,
          );
        },
      },
    },
    socialLinks: [
      {
        icon: "github",
        link: "https://github.com/lambdaclass/propamm-router-contracts",
      },
    ],
    sidebar: [
      { text: "Introduction", link: "/" },
      {
        text: "PropAMMs",
        collapsed: false,
        items: [
          { text: "What is a PropAMM?", link: "/propamms/" },
          { text: "Makers", link: "/propamms/makers" },
          { text: "Takers", link: "/propamms/takers" },
          { text: "PropAMMRouter", link: "/propamms/router" },
        ],
      },
      {
        text: "TypeScript SDK",
        collapsed: false,
        items: [
          { text: "Installation", link: "/typescript/installation" },
          { text: "Getting started", link: "/typescript/getting-started" },
          {
            text: "Router",
            collapsed: true,
            items: [
              { text: "quote", link: "/typescript/router/quote" },
              { text: "swap", link: "/typescript/router/swap" },
              { text: "waitForSwap", link: "/typescript/router/waitForSwap" },
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
          { text: "Installation", link: "/rust/installation" },
          { text: "Getting started", link: "/rust/getting-started" },
          {
            text: "Router",
            collapsed: true,
            items: [
              { text: "quote", link: "/rust/router/quote" },
              { text: "swap", link: "/rust/router/swap" },
              { text: "wait_for_swap", link: "/rust/router/wait_for_swap" },
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
      {
        text: "Python SDK",
        collapsed: false,
        items: [
          { text: "Installation", link: "/python/installation" },
          { text: "Getting started", link: "/python/getting-started" },
          {
            text: "Router",
            collapsed: true,
            items: [
              { text: "quote", link: "/python/router/quote" },
              { text: "swap", link: "/python/router/swap" },
              { text: "wait_for_swap", link: "/python/router/wait_for_swap" },
              { text: "approve", link: "/python/router/approve" },
              { text: "allowance", link: "/python/router/allowance" },
              { text: "Views", link: "/python/router/views" },
            ],
          },
          {
            text: "State overrides",
            collapsed: true,
            items: [
              { text: "OverridesWsSource", link: "/python/overrides/ws-source" },
              { text: "OverridesRpcSource", link: "/python/overrides/rpc-source" },
              { text: "Utilities", link: "/python/overrides/utilities" },
            ],
          },
          {
            text: "Price levels",
            collapsed: true,
            items: [
              { text: "PriceLevels", link: "/python/prices/price-levels" },
              { text: "PriceLevelsWsSource", link: "/python/prices/ws-source" },
              { text: "PriceLevelsRpcSource", link: "/python/prices/rpc-source" },
              { text: "Utilities", link: "/python/prices/utilities" },
            ],
          },
          { text: "Helpers", link: "/python/helpers" },
          { text: "Types", link: "/python/types" },
        ],
      },
    ],
  },
});
