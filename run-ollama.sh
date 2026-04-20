#!/bin/sh
set -eu

# Run the human terminal using the default local Ollama profile.
# All swarm agents resolve to qwen3.6:35b through the repo-local gateway config.
#
# Prerequisites:
#   1. Ollama running: ollama serve
#   2. Model pulled: ollama pull qwen3.6:35b
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

if ! curl -sf http://127.0.0.1:11434/api/tags | grep -Eq '"name"[[:space:]]*:[[:space:]]*"qwen3.6:35b"'; then
  printf '%s\n' "The model qwen3.6:35b is not available in Ollama yet." >&2
  printf '%s\n' "Pull it with: ollama pull qwen3.6:35b" >&2
  exit 1
fi

printf '%s\n' "Ollama detected. Default swarm route is qwen3.6:35b (local only)."
printf '%s\n' ""

export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
export BULKHEAD_LM_API_KEY="${BULKHEAD_LM_API_KEY:-sk-bulkhead-lm-dev}"
export AGENT_GRAPH_CLIENT_CONFIG="${AGENT_GRAPH_CLIENT_CONFIG:-$ROOT_DIR/config/client.json}"

exec "$ROOT_DIR/run.sh" "$@"
