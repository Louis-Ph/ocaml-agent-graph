#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/remote_common.sh"

MODE=
ORIGIN=${AGENT_GRAPH_INSTALL_ORIGIN:-}
BASE_URL=${AGENT_GRAPH_INSTALL_BASE_URL:-}
DEFAULT_TARGET=${AGENT_GRAPH_REMOTE_INSTALL_DEFAULT_TARGET}
SELF_PATH="${SCRIPT_DIR}/remote_install.sh"

print_help() {
  cat <<EOF
Usage:
  scripts/remote_install.sh --archive
  scripts/remote_install.sh --emit-installer --origin user@host [--default-target EXPR]
  scripts/remote_install.sh --emit-http-installer --base-url URL [--default-target EXPR]

Modes:
  --archive             Stream a filtered tar.gz snapshot of this ocaml-agent-graph repo to stdout
  --emit-installer      Emit a local SSH-based installer shell script to stdout
  --emit-http-installer Emit a local HTTP-based installer shell script to stdout

Options:
  --origin DEST         SSH destination that the emitted installer should call back
  --base-url URL        Public HTTP base URL serving install.sh and ocaml-agent-graph.tar.gz
  --default-target EXPR Default local install target expression. Default: ${DEFAULT_TARGET}
  --help                Show this help

Examples:
  ssh user@host '${SELF_PATH} --emit-installer --origin user@host' | sh
  ${SELF_PATH} --emit-http-installer --base-url http://127.0.0.1:8788 > install.sh
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --archive)
      [ -z "${MODE}" ] || { agent_graph_remote_note "Choose only one mode."; exit 1; }
      MODE=archive
      shift
      ;;
    --emit-installer)
      [ -z "${MODE}" ] || { agent_graph_remote_note "Choose only one mode."; exit 1; }
      MODE=ssh-installer
      shift
      ;;
    --emit-http-installer)
      [ -z "${MODE}" ] || { agent_graph_remote_note "Choose only one mode."; exit 1; }
      MODE=http-installer
      shift
      ;;
    --origin)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--origin requires a value"; exit 1; }
      ORIGIN=$2
      shift 2
      ;;
    --base-url)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--base-url requires a value"; exit 1; }
      BASE_URL=$2
      shift 2
      ;;
    --default-target)
      [ "$#" -ge 2 ] || { agent_graph_remote_note "--default-target requires a value"; exit 1; }
      DEFAULT_TARGET=$2
      shift 2
      ;;
    *)
      agent_graph_remote_note "Unknown option: $1"
      exit 1
      ;;
  esac
done

case "${MODE}" in
  archive)
    agent_graph_remote_stream_archive
    ;;
  ssh-installer)
    if [ -z "${ORIGIN}" ]; then
      agent_graph_remote_note "--origin is required with --emit-installer."
      exit 1
    fi
    agent_graph_remote_emit_ssh_installer "${ORIGIN}" "${SELF_PATH}" "${DEFAULT_TARGET}"
    ;;
  http-installer)
    if [ -z "${BASE_URL}" ]; then
      agent_graph_remote_note "--base-url is required with --emit-http-installer."
      exit 1
    fi
    agent_graph_remote_emit_http_installer "${BASE_URL}" "${DEFAULT_TARGET}"
    ;;
  *)
    print_help >&2
    exit 1
    ;;
esac
