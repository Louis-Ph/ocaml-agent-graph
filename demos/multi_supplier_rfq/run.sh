#!/bin/sh
set -eu
# Run the multi-supplier RFQ demo through the swarm graph.
# Usage:
#   ./demos/multi_supplier_rfq/run.sh
#   ./demos/multi_supplier_rfq/run.sh "Compare 3 suppliers for stainless steel fasteners"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
eval "$(opam env 2>/dev/null || true)"

QUERY="${1:-Compare supplier RFQ responses and recommend the best commercial choice. Produce a normalized quote comparison, list commercial exceptions, recommend a supplier, and explain the buyer rationale.}"

printf '%s\n' "{\"prompt\": $(printf '%s' "$QUERY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  | dune exec --root "$ROOT_DIR" ./bin/client.exe -- call --kind=assistant \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get("response",{}).get("message","No response"))' 2>/dev/null \
  || printf '%s\n' "Demo completed. Check the output above."
