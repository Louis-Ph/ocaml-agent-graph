#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/remote_common.sh"

CLIENT_CONFIG=${AGENT_GRAPH_REMOTE_CLIENT_CONFIG:-${AGENT_GRAPH_REMOTE_ROOT_DIR}/config/client.json}
PORT=${AGENT_GRAPH_REMOTE_HTTP_PORT:-8087}

print_help() {
  cat <<EOF
Usage: scripts/http_machine_server.sh [wrapper options] [-- serve-http options]

Wrapper options:
  --client-config FILE  Client config file. Default: ${CLIENT_CONFIG}
  --port PORT           HTTP workflow port. Default: ${PORT}
  --switch NAME         opam switch to load before starting
  --help                Show this help

Example:
  /path/to/ocaml-agent-graph/scripts/http_machine_server.sh --port 8087

Then another machine can call:
  curl -fsS http://host:8087/health
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --client-config)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--client-config requires a value"; exit 1; }
      CLIENT_CONFIG=$2
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--port requires a value"; exit 1; }
      PORT=$2
      shift 2
      ;;
    --switch)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--switch requires a value"; exit 1; }
      AGENT_GRAPH_REMOTE_SWITCH=$2
      export AGENT_GRAPH_REMOTE_SWITCH
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

agent_graph_remote_load_opam_env
agent_graph_remote_exec_client serve-http --client-config "${CLIENT_CONFIG}" --port "${PORT}" "$@"
