#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/remote_common.sh"

CLIENT_CONFIG=${AGENT_GRAPH_REMOTE_CLIENT_CONFIG:-${AGENT_GRAPH_REMOTE_ROOT_DIR}/config/client.json}

print_help() {
  cat <<EOF
Usage: scripts/remote_human_terminal.sh [wrapper options] [-- ask options]

Wrapper options:
  --client-config FILE  Client config file. Default: ${CLIENT_CONFIG}
  --switch NAME         opam switch to load before starting
  --help                Show this help

Typical SSH usage:
  ssh -t user@host '/path/to/ocaml-agent-graph/scripts/remote_human_terminal.sh'

Use -t so the remote human terminal receives a pseudo-terminal.
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

if [ ! -t 0 ] || [ ! -t 1 ]; then
  agent_graph_remote_note "remote_human_terminal requires an interactive TTY."
  agent_graph_remote_note "Use ssh -t user@host '/path/to/ocaml-agent-graph/scripts/remote_human_terminal.sh'"
  exit 1
fi

agent_graph_remote_load_opam_env
agent_graph_remote_exec_client ask --client-config "${CLIENT_CONFIG}" "$@"
