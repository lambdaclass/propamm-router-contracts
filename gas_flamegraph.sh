#!/usr/bin/env bash
# Usage: ./gas_flamegraph.sh <txhash> <rpc-url>
# Optional: export ETHERSCAN_API_KEY=... for contract-name resolution of external contracts.
# Labels + decoded sigs come from foundry's `cast run` trace decoder.
set -euo pipefail
TX=$1; RPC=$2
FG=/tmp/flamegraph.pl
[ -f "$FG" ] || curl -sL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl -o "$FG"

cast run "$TX" --rpc-url "$RPC" --with-local-artifacts \
  ${ETHERSCAN_API_KEY:+--etherscan-api-key "$ETHERSCAN_API_KEY"} -vvvv 2>&1 \
| python3 -c '
import sys,re
TREE=set(" │├└─")   # space │ ├ └ ─
rx=re.compile(r"\[(\d+)\]\s+(.+?)\(")
stack=[]  # each: [depth,label,gas,children_gas]
def emit(node,ancestors):
    self=max(node[2]-node[3],0)
    if self>0:
        print(";".join(a[1] for a in ancestors)+";"+node[1], self)
for line in sys.stdin:
    line=line.rstrip("\n")
    i=0
    while i<len(line) and line[i] in TREE: i+=1
    m=rx.match(line[i:])
    if not m: continue           # skip emit/return/non-call lines
    depth=max((i-2)//4,0)
    gas=int(m.group(1)); label=m.group(2).strip()
    while stack and stack[-1][0]>=depth:
        emit(stack.pop(),stack)
    if stack: stack[-1][3]+=gas   # add to parents child-gas
    stack.append([depth,label,gas,0])
while stack: emit(stack.pop(),stack)
' \
| perl "$FG" --title "gas $TX" --countname gas --hash > flamegraph.svg

echo "wrote flamegraph.svg"
open flamegraph.svg
