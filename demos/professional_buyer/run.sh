#!/bin/sh
set -eu
# Run the professional buyer demo through the swarm graph.
# Usage:
#   ./demos/professional_buyer/run.sh
#   ./demos/professional_buyer/run.sh "Find the best deal on industrial servo motors"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DEMO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
eval "$(opam env 2>/dev/null || true)"

QUERY="${1:-Find the best deal on the product described in the professional buyer scenario.}"

# Build the prompt from scenario + demo prompts
SCENARIO=$(cat "$DEMO_DIR/scenario.json")
PLANNER_PROMPT=$(cat "$DEMO_DIR/prompts/01_planner.md")
DECIDER_PROMPT=$(cat "$DEMO_DIR/prompts/04_procurement_decider.md")

FULL_PROMPT="You are a professional buyer AI agent. Here is the scenario:

$SCENARIO

Planner instructions:
$PLANNER_PROMPT

Procurement decider instructions:
$DECIDER_PROMPT

Now execute this buyer task: $QUERY

Produce a structured buyer memo with:
1. Sourcing brief
2. Market analysis
3. Ranked alternatives with cost breakdown
4. Final recommendation with rationale"

printf '%s\n' "{\"prompt\": $(printf '%s' "$FULL_PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  | dune exec --root "$ROOT_DIR" ./bin/client.exe -- call --kind=assistant \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get("response",{}).get("message","No response"))' 2>/dev/null \
  || printf '%s\n' "Demo completed. Check the output above."
