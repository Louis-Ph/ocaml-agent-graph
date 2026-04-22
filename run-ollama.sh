#!/bin/sh
set -eu

# Legacy compatibility wrapper.
# The default profile now routes everything through kimi-k2.6.
# This script remains as a thin alias to ./run.sh so older shell habits keep working.

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

printf '%s\n' "Default swarm route is kimi-k2.6."
printf '%s\n' "If the route is authenticated, make sure MOONSHOT_API_KEY is available to ./run.sh."
printf '%s\n' ""

export AGENT_GRAPH_CLIENT_CONFIG="${AGENT_GRAPH_CLIENT_CONFIG:-$ROOT_DIR/config/client.json}"

exec "$ROOT_DIR/run.sh" "$@"
