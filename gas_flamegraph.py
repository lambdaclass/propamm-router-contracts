#!/usr/bin/env python3
"""Generate a gas flamegraph (SVG) from an existing Ethereum transaction.

Usage:
    ./gas_flamegraph.py <txhash> <rpc-url> <name>

The RPC must support debug_traceTransaction (Alchemy/QuickNode/Reth/Geth archive).
Function selectors are resolved from local Foundry artifacts first, then 4byte.directory.
Rendering uses Brendan Gregg's flamegraph.pl (downloaded on first run; needs perl).
"""
import glob
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

# Known contract addresses -> readable names. Unknown addresses are left as-is.
NAMES = {
    "0x4ddf368080cd7946db5b459ad591c350158175e1": "PropAMMRouterProxy",
    "0x0ece81ca058e945f753fb6ff5ea09348760d1ac1": "PropAMMRouterImpl",
    "0x5979458912f80b96d30d4220af8e2e4925a33320": "FermiSwapWrapper",
    "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45": "UniswapRouter",
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": "WETH",
}

FLAMEGRAPH_PL = Path("/tmp/flamegraph.pl")
FLAMEGRAPH_URL = "https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl"


def load_selector_map():
    """selector (0x + 8 hex) -> function signature, from Foundry build artifacts."""
    selectors = {}
    for artifact in glob.glob("out/**/*.json", recursive=True):
        try:
            method_ids = json.load(open(artifact)).get("methodIdentifiers", {})
        except Exception:
            continue
        for sig_text, sel in method_ids.items():
            selectors.setdefault("0x" + sel, clean(sig_text))
    return selectors


def clean(text):
    """Make a label safe for flamegraph's folded-stack format."""
    return text.replace(";", "_").replace(" ", "")


def resolve_signature(selector, cache):
    """Resolve a 4-byte selector to a signature, falling back to 4byte.directory."""
    if selector in cache:
        return cache[selector]
    name = selector
    try:
        url = f"https://www.4byte.directory/api/v1/signatures/?hex_signature={selector}"
        results = json.load(urllib.request.urlopen(url, timeout=5))["results"]
        if results:
            name = min(results, key=lambda r: r["id"])["text_signature"]  # oldest = canonical
    except Exception:
        pass
    cache[selector] = clean(name)
    return cache[selector]


def fetch_trace(txhash, rpc):
    """Get the callTracer trace for a transaction via cast rpc."""
    out = subprocess.run(
        ["cast", "rpc", "--rpc-url", rpc, "debug_traceTransaction", txhash,
         '{"tracer":"callTracer","tracerConfig":{"withLog":false}}'],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def fold(node, stack, selectors, lines):
    """Walk the call tree, emitting one folded-stack line per frame with self-gas."""
    selector = node.get("input", "0x")[:10]
    label = resolve_signature(selector, selectors) if len(selector) == 10 else node.get("type", "")
    addr = node.get("to", "?")
    name = NAMES.get(addr.lower(), addr)
    frame = clean(f"{name}:{label}")

    full_stack = stack + [frame]
    children = node.get("calls", [])
    gas = lambda n: int(n.get("gasUsed", "0x0"), 16)
    self_gas = gas(node) - sum(gas(c) for c in children)
    if self_gas > 0:
        lines.append(f"{';'.join(full_stack)} {self_gas}")
    for child in children:
        fold(child, full_stack, selectors, lines)


def render(folded, title, out_path):
    """Render folded stacks to an SVG via flamegraph.pl, then open it."""
    if not FLAMEGRAPH_PL.exists():
        urllib.request.urlretrieve(FLAMEGRAPH_URL, FLAMEGRAPH_PL)
    svg = subprocess.run(
        ["perl", str(FLAMEGRAPH_PL), "--title", title, "--countname", "gas", "--minwidth", "0"],
        input="\n".join(folded), check=True, capture_output=True, text=True,
    ).stdout
    out_path.write_text(svg)
    print(f"wrote {out_path}")
    subprocess.run(["open", str(out_path)])


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    txhash, rpc, name = sys.argv[1:4]

    selectors = load_selector_map()
    trace = fetch_trace(txhash, rpc)
    folded = []
    fold(trace, [], selectors, folded)
    render(folded, name, Path(f"{name.replace(' ', '_')}.svg"))


if __name__ == "__main__":
    main()
