#!/bin/sh

DEFAULT_CLIENT_CONFIG=${AGENT_GRAPH_CLIENT_CONFIG:-$ROOT_DIR/config/client.json}
DEFAULT_BULKHEAD_LM_DIR=${AGENT_GRAPH_BULKHEAD_LM_DIR:-$ROOT_DIR/../bulkhead-lm}
DEFAULT_BULKHEAD_LM_REPO_URL=${AGENT_GRAPH_BULKHEAD_LM_REPO_URL:-https://github.com/Louis-Ph/bulkhead-lm.git}
DEFAULT_OCAML_COMPILER=${AGENT_GRAPH_OCAML_COMPILER:-ocaml-base-compiler.5.2.1}
USE_GLOBAL_SWITCH=${AGENT_GRAPH_USE_GLOBAL_SWITCH:-0}
FORCE_LOCAL_SWITCH=${AGENT_GRAPH_FORCE_LOCAL_SWITCH:-0}
DEFAULT_ENV_FILES="$HOME/.zshrc.secret:$HOME/.zshrc.secrets:$HOME/.bashrc.secret:$HOME/.bashrc.secrets:$HOME/.profile.secret:$HOME/.profile.secrets:$HOME/.config/bulkhead-lm/env:$HOME/.config/ocaml-agent-graph/env"
STARTER_ENV_FILES=${AGENT_GRAPH_STARTER_ENV_FILES:-$DEFAULT_ENV_FILES}
BUILD_LOG=""
OPAM_BIN=""
BULKHEAD_LM_PIN_REFRESH_REQUIRED=0

say() {
  printf '%s\n' "$1"
}

say_err() {
  printf '%s\n' "$1" >&2
}

has_hook() {
  command -v "$1" >/dev/null 2>&1
}

prompt_yes_no() {
  label=$1
  default_answer=${2:-Y}
  prompt_suffix="y/N"
  if [ "$default_answer" = "Y" ]; then
    prompt_suffix="Y/n"
  fi

  printf "%s [%s]: " "$label" "$prompt_suffix"
  answer=""
  if ! read -r answer; then
    answer=""
  fi
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
  if [ -z "$answer" ]; then
    [ "$default_answer" = "Y" ]
    return
  fi
  [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

ensure_build_log() {
  if [ -z "$BUILD_LOG" ]; then
    BUILD_LOG=$(mktemp "${TMPDIR:-/tmp}/agent-graph-starter.XXXXXX")
  fi
}

cleanup_temp_files() {
  if [ -n "$BUILD_LOG" ] && [ -e "$BUILD_LOG" ]; then
    rm -f "$BUILD_LOG"
  fi
}

manual_setup_commands() {
  if has_hook platform_manual_setup_commands; then
    platform_manual_setup_commands
    return
  fi

  cat <<EOF
Manual setup options:
  Clone the sibling dependency if it is missing:
    git clone "$DEFAULT_BULKHEAD_LM_REPO_URL" "$DEFAULT_BULKHEAD_LM_DIR"

  Reuse the current switch:
    eval "\$(opam env --set-switch)"
    opam pin add bulkhead_lm "$DEFAULT_BULKHEAD_LM_DIR" --yes --no-action
    opam install . --deps-only --yes
    dune build bin/client.exe
    ./run.sh

  Or create a project-local fallback:
    cd "$ROOT_DIR"
    opam switch create . "$DEFAULT_OCAML_COMPILER" --yes
    eval "\$(opam env --switch . --set-switch)"
    opam pin add bulkhead_lm "$DEFAULT_BULKHEAD_LM_DIR" --yes --no-action
    opam install . --deps-only --yes
    ./run.sh
EOF
}

ensure_exec_bits() {
  chmod +x "$ROOT_DIR/run.sh" "$STARTER_SCRIPT_PATH" "$ROOT_DIR/scripts/starter_common.sh" 2>/dev/null || true
  chmod +x \
    "$ROOT_DIR/scripts/remote_human_terminal.sh" \
    "$ROOT_DIR/scripts/remote_machine_terminal.sh" \
    "$ROOT_DIR/scripts/remote_install.sh" \
    "$ROOT_DIR/scripts/http_machine_server.sh" \
    "$ROOT_DIR/scripts/http_dist_server.sh" 2>/dev/null || true
  if [ -n "${STARTER_EXTRA_EXECUTABLE:-}" ]; then
    chmod +x "$STARTER_EXTRA_EXECUTABLE" 2>/dev/null || true
  fi
}

load_secret_file() {
  secret_file=$1
  [ -r "$secret_file" ] || return 0

  set +e
  set +u
  set -a
  . "$secret_file" >/dev/null 2>&1
  status=$?
  set +a
  set -eu

  if [ "$status" -ne 0 ]; then
    say_err "Warning: could not load $secret_file under /bin/sh; continuing."
  fi
}

load_secret_files() {
  old_ifs=$IFS
  IFS=:
  for secret_file in $STARTER_ENV_FILES; do
    load_secret_file "$secret_file"
  done
  IFS=$old_ifs
}

ensure_connector_auth() {
  if [ -z "${BULKHEAD_LM_API_KEY:-}" ]; then
    BULKHEAD_LM_API_KEY="sk-bulkhead-lm-dev"
    export BULKHEAD_LM_API_KEY
  fi
}

find_opam() {
  if [ -n "${AGENT_GRAPH_OPAM_BIN:-}" ] && [ -x "${AGENT_GRAPH_OPAM_BIN}" ]; then
    OPAM_BIN=${AGENT_GRAPH_OPAM_BIN}
    return
  fi

  if command -v opam >/dev/null 2>&1; then
    OPAM_BIN=$(command -v opam)
    return
  fi

  if has_hook platform_find_opam; then
    candidate=$(platform_find_opam || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      OPAM_BIN=$candidate
      return
    fi
  fi
}

run_privileged() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  if command -v doas >/dev/null 2>&1; then
    doas "$@"
    return
  fi
  say_err "Neither sudo nor doas was found."
  return 1
}

ensure_opam() {
  find_opam
  if [ -n "$OPAM_BIN" ]; then
    return
  fi

  say_err "opam was not found."
  if ! has_hook platform_install_opam; then
    manual_setup_commands >&2
    exit 1
  fi

  if ! platform_install_opam; then
    manual_setup_commands >&2
    exit 1
  fi

  find_opam
  if [ -z "$OPAM_BIN" ]; then
    say_err "opam is still not available after the install step."
    manual_setup_commands >&2
    exit 1
  fi
}

ensure_opam_initialized() {
  if [ -f "$HOME/.opam/config" ]; then
    return
  fi

  say "Initializing opam for first use..."
  ensure_build_log
  if ! "$OPAM_BIN" init --yes >"$BUILD_LOG" 2>&1; then
    say_err "opam init failed."
    say_err "See $BUILD_LOG for details."
    manual_setup_commands >&2
    exit 1
  fi
}

current_switch_name() {
  if [ -n "${OPAMSWITCH:-}" ]; then
    printf '%s\n' "$OPAMSWITCH"
  else
    "$OPAM_BIN" switch show 2>/dev/null || true
  fi
}

apply_current_switch_environment() {
  if [ -n "${OPAMSWITCH:-}" ]; then
    eval "$("$OPAM_BIN" env --switch="$OPAMSWITCH" --set-switch)"
  else
    eval "$("$OPAM_BIN" env --set-switch)"
  fi
}

apply_local_switch_environment() {
  eval "$("$OPAM_BIN" env --switch="$ROOT_DIR" --set-switch)"
}

describe_active_toolchain() {
  switch_name=$(current_switch_name)
  prefix=$("$OPAM_BIN" var prefix 2>/dev/null || true)
  say "Checking OCaml toolchain in switch: ${switch_name:-unknown}"
  if [ -n "$prefix" ]; then
    say "Active prefix: $prefix"
  fi
}

normalize_existing_dir() {
  target_dir=$1
  if [ ! -d "$target_dir" ]; then
    return 1
  fi
  (cd "$target_dir" && pwd -P)
}

ensure_bulkhead_lm_checkout() {
  if [ -f "$DEFAULT_BULKHEAD_LM_DIR/dune-project" ]; then
    # Auto-pull latest version if git is available
    if command -v git >/dev/null 2>&1 && [ -d "$DEFAULT_BULKHEAD_LM_DIR/.git" ]; then
      local_rev=$(git -C "$DEFAULT_BULKHEAD_LM_DIR" rev-parse HEAD 2>/dev/null || true)
      git -C "$DEFAULT_BULKHEAD_LM_DIR" fetch --quiet origin main 2>/dev/null || true
      remote_rev=$(git -C "$DEFAULT_BULKHEAD_LM_DIR" rev-parse origin/main 2>/dev/null || true)
      if [ -n "$remote_rev" ] && [ -n "$local_rev" ] && [ "$local_rev" != "$remote_rev" ]; then
        say "Updating BulkheadLM to latest version ..."
        git -C "$DEFAULT_BULKHEAD_LM_DIR" pull --quiet --ff-only origin main 2>/dev/null || true
      fi
    fi
    return 0
  fi

  if [ -e "$DEFAULT_BULKHEAD_LM_DIR" ] && [ ! -d "$DEFAULT_BULKHEAD_LM_DIR" ]; then
    say_err "BulkheadLM path exists but is not a directory: $DEFAULT_BULKHEAD_LM_DIR"
    return 1
  fi

  say "BulkheadLM checkout was not found at $DEFAULT_BULKHEAD_LM_DIR."
  if ! command -v git >/dev/null 2>&1; then
    say_err "git is required to clone the sibling dependency automatically."
    return 1
  fi

  say "Cloning bulkhead-lm next to this repository ..."
  parent_dir=$(dirname "$DEFAULT_BULKHEAD_LM_DIR")
  mkdir -p "$parent_dir"
  if ! git clone --quiet "$DEFAULT_BULKHEAD_LM_REPO_URL" "$DEFAULT_BULKHEAD_LM_DIR"; then
    say_err "Automatic clone of bulkhead-lm failed."
    return 1
  fi
  return 0
}

bulkhead_lm_pin_matches() {
  desired_dir=$(normalize_existing_dir "$DEFAULT_BULKHEAD_LM_DIR" || true)
  if [ -z "$desired_dir" ]; then
    return 1
  fi

  pin_list=$("$OPAM_BIN" pin list 2>/dev/null || true)
  case "$pin_list" in
    *"$desired_dir"*)
      ;;
    *)
      return 1
      ;;
  esac

  pin_src=$("$OPAM_BIN" show bulkhead_lm --raw 2>/dev/null | sed -n 's/^[[:space:]]*src:[[:space:]]*"\(.*\)".*$/\1/p' | head -n 1)
  case "$pin_src" in
    *"$desired_dir"*)
      ;;
    *)
      return 1
      ;;
  esac

  current_revision=""
  if command -v git >/dev/null 2>&1; then
    current_revision=$(git -C "$desired_dir" rev-parse HEAD 2>/dev/null || true)
  fi

  if [ -n "$current_revision" ]; then
    pinned_revision=$(printf '%s\n' "$pin_list" | sed -n 's/^bulkhead_lm\..*(at \([0-9a-f][0-9a-f]*\)).*$/\1/p' | head -n 1)
    if [ -n "$pinned_revision" ] && [ "$pinned_revision" != "$current_revision" ]; then
      return 1
    fi
  fi

  return 0
}

pin_bulkhead_lm_dependency() {
  if bulkhead_lm_pin_matches; then
    return 0
  fi
  ensure_build_log
  say "Refreshing bulkhead_lm pin to $DEFAULT_BULKHEAD_LM_DIR ..."
  if ! "$OPAM_BIN" pin add bulkhead_lm "$DEFAULT_BULKHEAD_LM_DIR" --yes --no-action >"$BUILD_LOG" 2>&1; then
    say_err "Unable to pin bulkhead_lm from $DEFAULT_BULKHEAD_LM_DIR."
    say_err "See $BUILD_LOG for details."
    return 1
  fi
  BULKHEAD_LM_PIN_REFRESH_REQUIRED=1
  return 0
}

prepare_local_dependencies() {
  ensure_bulkhead_lm_checkout || return 1
  pin_bulkhead_lm_dependency || return 1
  return 0
}

build_client() {
  ensure_build_log
  (cd "$ROOT_DIR" && dune build bin/client.exe >"$BUILD_LOG" 2>&1)
}

install_project_deps() {
  ensure_build_log
  prepare_local_dependencies || return 1
  (cd "$ROOT_DIR" && "$OPAM_BIN" install . --deps-only --yes >"$BUILD_LOG" 2>&1)
}

reset_build_log() {
  rm -f "$BUILD_LOG"
  BUILD_LOG=""
}

find_built_client_runner() {
  if [ -x "$ROOT_DIR/_build/default/bin/client.exe" ]; then
    printf '%s\n' "$ROOT_DIR/_build/default/bin/client.exe"
    return 0
  fi
  return 1
}

find_installed_client_runner() {
  if command -v ocaml-agent-graph-client >/dev/null 2>&1; then
    command -v ocaml-agent-graph-client
    return 0
  fi
  return 1
}

find_local_client_runner() {
  find_built_client_runner || find_installed_client_runner
}

ensure_project_buildable() {
  install_prompt=$1
  prepare_local_dependencies || return 1
  if [ "$BULKHEAD_LM_PIN_REFRESH_REQUIRED" = "1" ]; then
    say "bulkhead_lm changed; recompiling from updated source ..."
    ensure_build_log
    if ! "$OPAM_BIN" reinstall bulkhead_lm --yes >"$BUILD_LOG" 2>&1; then
      say_err "bulkhead_lm reinstall failed."
      say_err "See $BUILD_LOG for details."
      return 1
    fi
    if ! install_project_deps; then
      say_err "Automatic dependency installation failed after refreshing bulkhead_lm."
      say_err "See $BUILD_LOG for details."
      return 1
    fi
    BULKHEAD_LM_PIN_REFRESH_REQUIRED=0
  fi
  if build_client; then
    reset_build_log
    return 0
  fi

  if ! command -v ocamlc >/dev/null 2>&1; then
    say_err "ocamlc is not available in the active switch."
  fi
  if ! command -v dune >/dev/null 2>&1; then
    say_err "dune is not available in the active switch."
  fi

  say "The active switch is not coherent for this repository yet."
  if ! prompt_yes_no "$install_prompt" "Y"; then
    return 1
  fi

  if ! install_project_deps; then
    say_err "Automatic dependency installation failed."
    say_err "See $BUILD_LOG for details."
    return 1
  fi

  if ! build_client; then
    say_err "The repository still does not build in the active switch."
    say_err "See $BUILD_LOG for details."
    return 1
  fi

  reset_build_log
  return 0
}

create_local_switch() {
  say "Creating a project-local opam switch in $ROOT_DIR/_opam ..."
  ensure_build_log
  if ! "$OPAM_BIN" switch create "$ROOT_DIR" "$DEFAULT_OCAML_COMPILER" --yes >"$BUILD_LOG" 2>&1; then
    say_err "Local switch creation failed."
    say_err "See $BUILD_LOG for details."
    return 1
  fi
}

ensure_local_switch_requested() {
  if [ -d "$ROOT_DIR/_opam" ]; then
    say "Reusing existing project-local switch in $ROOT_DIR/_opam."
    return 0
  fi

  if [ "$FORCE_LOCAL_SWITCH" = "1" ]; then
    create_local_switch || return 1
    return 0
  fi

  if ! prompt_yes_no "Create a project-local fallback switch in $ROOT_DIR/_opam?" "Y"; then
    return 1
  fi

  create_local_switch || return 1
  return 0
}

run_with_current_switch() {
  apply_current_switch_environment
  describe_active_toolchain
  ensure_project_buildable "Install missing project dependencies in the current switch now?"
}

run_with_local_switch() {
  ensure_local_switch_requested || return 1
  apply_local_switch_environment
  describe_active_toolchain
  ensure_project_buildable "Install missing project dependencies in the project-local fallback switch now?"
}

starter_exec_client() {
  cd "$ROOT_DIR"
  client_runner=$(find_local_client_runner || true)
  if [ -n "$client_runner" ]; then
    exec "$client_runner" ask --client-config "$DEFAULT_CLIENT_CONFIG" "$@"
  fi
  exec dune exec ocaml-agent-graph-client -- ask --client-config "$DEFAULT_CLIENT_CONFIG" "$@"
}

starter_main() {
  ensure_exec_bits
  load_secret_files
  ensure_connector_auth
  trap cleanup_temp_files EXIT INT TERM

  if has_hook platform_validate_host; then
    platform_validate_host || exit 1
  fi

  ensure_opam
  ensure_opam_initialized

  if [ "$FORCE_LOCAL_SWITCH" = "1" ]; then
    if ! run_with_local_switch; then
      manual_setup_commands >&2
      exit 1
    fi
  elif run_with_current_switch; then
    :
  elif [ "$USE_GLOBAL_SWITCH" = "1" ]; then
    say_err "The current switch could not build this repository."
    if [ -n "$BUILD_LOG" ]; then
      say_err "See $BUILD_LOG for details."
    fi
    manual_setup_commands >&2
    exit 1
  elif ! run_with_local_switch; then
    say_err "No working OCaml environment was prepared for this repository."
    if [ -n "$BUILD_LOG" ]; then
      say_err "See $BUILD_LOG for details."
    fi
    manual_setup_commands >&2
    exit 1
  fi

  starter_exec_client "$@"
}
