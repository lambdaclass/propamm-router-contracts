import { defineConfig } from "vocs/config";

export default defineConfig({
  title: "PropAMM SDK",
  description: "SDKs for interacting with the PropAMM contracts",
  // Set by the Pages deploy workflow (project sites serve at /<repo>/).
  basePath: process.env.BASE_PATH,
  // Emit a fully static site (plain HTML) for GitHub Pages hosting.
  renderStrategy: "full-static",
  accentColor: "#8051e7",
  socials: [
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
        { text: "What is a PropAMM?", link: "/propamms" },
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
  ],
});
