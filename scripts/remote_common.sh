AGENT_GRAPH_REMOTE_ROOT_DIR=${AGENT_GRAPH_REMOTE_ROOT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}

agent_graph_remote_note() {
  printf '%s\n' "$*" >&2
}

agent_graph_remote_find_opam() {
  if [ -n "${AGENT_GRAPH_OPAM_BIN:-}" ] && [ -x "${AGENT_GRAPH_OPAM_BIN}" ]; then
    printf '%s\n' "${AGENT_GRAPH_OPAM_BIN}"
    return 0
  fi
  if command -v opam >/dev/null 2>&1; then
    command -v opam
    return 0
  fi
  if [ -x "/opt/homebrew/bin/opam" ]; then
    printf '%s\n' "/opt/homebrew/bin/opam"
    return 0
  fi
  if [ -x "/usr/local/bin/opam" ]; then
    printf '%s\n' "/usr/local/bin/opam"
    return 0
  fi
  return 1
}

agent_graph_remote_resolve_switch() {
  if [ -n "${AGENT_GRAPH_REMOTE_SWITCH:-}" ]; then
    printf '%s\n' "${AGENT_GRAPH_REMOTE_SWITCH}"
  elif [ -n "${OPAMSWITCH:-}" ]; then
    printf '%s\n' "${OPAMSWITCH}"
  elif [ -d "${AGENT_GRAPH_REMOTE_ROOT_DIR}/_opam" ]; then
    printf '%s\n' "${AGENT_GRAPH_REMOTE_ROOT_DIR}"
  else
    printf '%s\n' ""
  fi
}

agent_graph_remote_load_opam_env() {
  opam_bin=$(agent_graph_remote_find_opam || true)
  if [ -z "${opam_bin}" ]; then
    return 0
  fi
  switch_name=$(agent_graph_remote_resolve_switch)
  if [ -n "${switch_name}" ]; then
    eval "$("${opam_bin}" env --switch="${switch_name}" --set-switch)"
  else
    eval "$("${opam_bin}" env --set-switch)"
  fi
}

agent_graph_remote_find_client_runner() {
  if [ -n "${AGENT_GRAPH_REMOTE_CLIENT_BIN:-}" ] && [ -x "${AGENT_GRAPH_REMOTE_CLIENT_BIN}" ]; then
    printf 'bin:%s\n' "${AGENT_GRAPH_REMOTE_CLIENT_BIN}"
    return 0
  fi
  if [ -x "${AGENT_GRAPH_REMOTE_ROOT_DIR}/bin/ocaml-agent-graph-client" ]; then
    printf 'bin:%s\n' "${AGENT_GRAPH_REMOTE_ROOT_DIR}/bin/ocaml-agent-graph-client"
    return 0
  fi
  if [ -x "${AGENT_GRAPH_REMOTE_ROOT_DIR}/_build/default/bin/client.exe" ]; then
    printf 'bin:%s\n' "${AGENT_GRAPH_REMOTE_ROOT_DIR}/_build/default/bin/client.exe"
    return 0
  fi
  if command -v ocaml-agent-graph-client >/dev/null 2>&1; then
    printf 'bin:%s\n' "$(command -v ocaml-agent-graph-client)"
    return 0
  fi
  if command -v dune >/dev/null 2>&1; then
    printf '%s\n' "dune"
    return 0
  fi
  return 1
}

agent_graph_remote_exec_client() {
  runner=$(agent_graph_remote_find_client_runner || true)
  if [ -z "${runner}" ]; then
    agent_graph_remote_note "No ocaml-agent-graph client runner was found."
    agent_graph_remote_note "Expected one of:"
    agent_graph_remote_note "  - ${AGENT_GRAPH_REMOTE_ROOT_DIR}/_build/default/bin/client.exe"
    agent_graph_remote_note "  - ocaml-agent-graph-client in PATH"
    agent_graph_remote_note "  - dune in PATH"
    return 1
  fi

  cd "${AGENT_GRAPH_REMOTE_ROOT_DIR}"
  case "${runner}" in
    bin:*)
      exec "${runner#bin:}" "$@"
      ;;
    dune)
      exec dune exec ocaml-agent-graph-client -- "$@"
      ;;
    *)
      agent_graph_remote_note "Unsupported client runner descriptor: ${runner}"
      return 1
      ;;
  esac
}
