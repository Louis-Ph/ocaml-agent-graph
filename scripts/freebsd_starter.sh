#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STARTER_SCRIPT_PATH="$ROOT_DIR/scripts/freebsd_starter.sh"

. "$ROOT_DIR/scripts/starter_common.sh"

platform_validate_host() {
  if [ "$(uname -s)" != "FreeBSD" ]; then
    say_err "This starter is for FreeBSD hosts."
    return 1
  fi
}

platform_find_opam() {
  if [ -x "/usr/local/bin/opam" ]; then
    printf '%s\n' "/usr/local/bin/opam"
  fi
}

platform_install_opam() {
  if ! command -v pkg >/dev/null 2>&1; then
    say_err "pkg was not found."
    return 1
  fi

  if ! prompt_yes_no "Install opam and build prerequisites with pkg now?" "Y"; then
    return 1
  fi

  if ! run_privileged pkg update; then
    say_err "pkg update failed."
    return 1
  fi

  if ! run_privileged pkg install -y ocaml-opam sqlite3 pkgconf gmake git; then
    say_err "Automatic pkg installation failed."
    return 1
  fi

  return 0
}

platform_manual_setup_commands() {
  cat <<EOF
Manual setup options for FreeBSD:
  Install system prerequisites:
    sudo pkg update
    sudo pkg install -y ocaml-opam sqlite3 pkgconf gmake git

  Clone the sibling dependency if it is missing:
    git clone "$DEFAULT_AEGIS_LM_REPO_URL" "$DEFAULT_AEGIS_LM_DIR"

  Initialize opam once:
    opam init --yes
    eval "\$(opam env --set-switch)"

  Then prepare this repository:
    cd "$ROOT_DIR"
    opam pin add aegis_lm "$DEFAULT_AEGIS_LM_DIR" --yes --no-action
    opam install . --deps-only --yes
    dune build bin/client.exe
    ./run.sh

  Or create a project-local fallback:
    cd "$ROOT_DIR"
    opam switch create . "$DEFAULT_OCAML_COMPILER" --yes
    eval "\$(opam env --switch . --set-switch)"
    opam pin add aegis_lm "$DEFAULT_AEGIS_LM_DIR" --yes --no-action
    opam install . --deps-only --yes
    ./run.sh
EOF
}

starter_main "$@"
