#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/remote_common.sh"

CLIENT_CONFIG=${AGENT_GRAPH_REMOTE_CLIENT_CONFIG:-${AGENT_GRAPH_REMOTE_ROOT_DIR}/config/client.json}
JOBS=${AGENT_GRAPH_REMOTE_JOBS:-4}

print_help() {
  cat <<EOF
Usage: scripts/remote_machine_terminal.sh [wrapper options] [-- worker options]

Wrapper options:
  --client-config FILE  Client config file. Default: ${CLIENT_CONFIG}
  --jobs N              Worker concurrency. Default: ${JOBS}
  --switch NAME         opam switch to load before starting
  --help                Show this help

Typical SSH usage:
  ssh -T user@host '/path/to/ocaml-agent-graph/scripts/remote_machine_terminal.sh'

Use -T so stdout stays clean for JSONL traffic.
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
    --jobs)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--jobs requires a value"; exit 1; }
      JOBS=$2
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
agent_graph_remote_exec_client worker --client-config "${CLIENT_CONFIG}" --jobs "${JOBS}" "$@"
