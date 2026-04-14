#!/bin/sh
set -eu
# Run the category restock optimizer demo through the swarm graph.
# Usage:
#   ./demos/category_restock_optimizer/run.sh
#   ./demos/category_restock_optimizer/run.sh "Optimize restock for industrial bearing category"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
eval "$(opam env 2>/dev/null || true)"

QUERY="${1:-Optimize category-level replenishment using current market conditions and procurement constraints. Balance price, reliability, lead time, supplier risk, and reorder urgency. Produce a restock shortlist, supplier risk notes, and a reorder recommendation.}"

printf '%s\n' "{\"prompt\": $(printf '%s' "$QUERY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  | dune exec --root "$ROOT_DIR" ./bin/client.exe -- call --kind=assistant \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get("response",{}).get("message","No response"))' 2>/dev/null \
  || printf '%s\n' "Demo completed. Check the output above."
