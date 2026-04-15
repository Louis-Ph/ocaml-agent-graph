#!/bin/sh
set -eu

# Run the human terminal using local Ollama models exclusively.
# Zero cloud API cost — all inference runs on your machine.
#
# Prerequisites:
#   1. Ollama running: ollama serve
#   2. Models pulled: ollama pull qwen3:4b && ollama pull swarm-lead && ollama pull swarm-critic && ollama pull swarm-worker
#   3. BulkheadLM gateway started with Ollama config:
#      cd ../bulkhead-lm && ./scripts/with_local_toolchain.sh dune exec bulkhead-lm -- --config config/example.ollama_swarm.gateway.json
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

export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
export BULKHEAD_LM_API_KEY="${BULKHEAD_LM_API_KEY:-sk-bulkhead-lm-dev}"

# Use the Ollama client config
exec "$ROOT_DIR/run.sh" --client-config "$ROOT_DIR/config/client.ollama.json" "$@"
