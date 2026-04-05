#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STARTER_SCRIPT_PATH="$ROOT_DIR/scripts/ubuntu_starter.sh"

. "$ROOT_DIR/scripts/starter_common.sh"

platform_validate_host() {
  if [ "$(uname -s)" != "Linux" ]; then
    say_err "This starter is for Ubuntu hosts."
    return 1
  fi
  if [ ! -r /etc/os-release ]; then
    say_err "Could not detect an Ubuntu release because /etc/os-release is missing."
    return 1
  fi

  ID=""
  ID_LIKE=""
  . /etc/os-release
  if [ "${ID:-}" = "ubuntu" ]; then
    return 0
  fi
  case "${ID_LIKE:-}" in
    *ubuntu*)
      return 0
      ;;
  esac

  say_err "This Linux starter currently targets Ubuntu."
  say_err "Use an installed opam switch and the same commands manually on other Linux distributions."
  return 1
}

platform_install_opam() {
  if ! command -v apt-get >/dev/null 2>&1; then
    say_err "apt-get was not found."
    return 1
  fi

  if ! prompt_yes_no "Install opam and build prerequisites with apt now?" "Y"; then
    return 1
  fi

  if ! run_privileged apt-get update; then
    say_err "apt-get update failed."
    return 1
  fi

  if ! run_privileged apt-get install -y opam build-essential m4 pkg-config bubblewrap libsqlite3-dev; then
    say_err "Automatic apt installation failed."
    return 1
  fi

  return 0
}

platform_manual_setup_commands() {
  cat <<EOF
Manual setup options for Ubuntu:
  Install system prerequisites:
    sudo apt-get update
    sudo apt-get install -y opam build-essential m4 pkg-config bubblewrap libsqlite3-dev

  Clone the sibling dependency if it is missing:
    git clone "$DEFAULT_BULKHEAD_LM_REPO_URL" "$DEFAULT_BULKHEAD_LM_DIR"

  Initialize opam once:
    opam init --yes
    eval "\$(opam env --set-switch)"

  Then prepare this repository:
    cd "$ROOT_DIR"
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

starter_main "$@"
