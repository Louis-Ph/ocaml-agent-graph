#!/bin/sh
set -eu

# Run the human terminal using local Ollama models exclusively.
# Zero cloud API cost — all inference runs on your machine.
#
# Prerequisites:
#   1. Ollama running: ollama serve
#   2. Models pulled: ollama pull qwen3:4b && ollama pull swarm-lead && ollama pull swarm-critic && ollama pull swarm-worker
#   3. BulkheadLM gateway started with Ollama config (in a separate terminal):
#      cd ../bulkhead-lm && dune exec bulkhead-lm -- --config config/example.ollama_swarm.gateway.json
#
# Then just:
#   ./run-ollama.sh

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Check Ollama is reachable
if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  printf '%s\n' "Ollama is not running on 127.0.0.1:11434." >&2
  printf '%s\n' "Start it with: ollama serve" >&2
  exit 1
fi

printf '%s\n' "Ollama detected. Using local models only (zero cloud cost)."
printf '%s\n' ""

export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
export BULKHEAD_LM_API_KEY="${BULKHEAD_LM_API_KEY:-sk-bulkhead-lm-dev}"
export AGENT_GRAPH_CLIENT_CONFIG="$ROOT_DIR/config/client.ollama.json"

exec "$ROOT_DIR/run.sh" "$@"
