#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STARTER_SCRIPT_PATH="$ROOT_DIR/scripts/macos_starter.sh"
STARTER_EXTRA_EXECUTABLE="$ROOT_DIR/start-macos-client.command"

. "$ROOT_DIR/scripts/starter_common.sh"

platform_validate_host() {
  if [ "$(uname -s)" != "Darwin" ]; then
    say_err "This starter is for macOS hosts."
    return 1
  fi
}

platform_find_opam() {
  if [ -x "/opt/homebrew/bin/opam" ]; then
    printf '%s\n' "/opt/homebrew/bin/opam"
  fi
}

platform_install_opam() {
  if ! command -v brew >/dev/null 2>&1; then
    say_err "Homebrew was not found."
    return 1
  fi

  if ! prompt_yes_no "Install opam with Homebrew now?" "Y"; then
    return 1
  fi

  if ! brew install opam; then
    say_err "Automatic Homebrew installation failed."
    return 1
  fi

  return 0
}

platform_manual_setup_commands() {
  cat <<EOF
Manual setup options for macOS:
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

starter_main "$@"
