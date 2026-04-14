#!/bin/sh
set -eu
# Run the price watch demo through the swarm graph.
# Usage:
#   ./demos/price_watch/run.sh
#   ./demos/price_watch/run.sh "Track prices for NVIDIA H100 GPUs and recommend a buy window"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
eval "$(opam env 2>/dev/null || true)"

QUERY="${1:-Monitor live offers for a product category and trigger a buy recommendation when price and supply conditions are favorable. Produce a tracked offer table, price movement summary, and a buy now or wait recommendation.}"

printf '%s\n' "{\"prompt\": $(printf '%s' "$QUERY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  | dune exec --root "$ROOT_DIR" ./bin/client.exe -- call --kind=assistant \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get("response",{}).get("message","No response"))' 2>/dev/null \
  || printf '%s\n' "Demo completed. Check the output above."
