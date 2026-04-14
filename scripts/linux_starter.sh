#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STARTER_SCRIPT_PATH="$ROOT_DIR/scripts/linux_starter.sh"

. "$ROOT_DIR/scripts/starter_common.sh"

platform_validate_host() {
  if [ "$(uname -s)" != "Linux" ]; then
    say_err "This starter is for Linux hosts."
    return 1
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt\n'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf\n'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum\n'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'pacman\n'
  elif command -v apk >/dev/null 2>&1; then
    printf 'apk\n'
  elif command -v zypper >/dev/null 2>&1; then
    printf 'zypper\n'
  else
    printf 'unknown\n'
  fi
}

platform_install_opam() {
  pkg_manager=$(detect_package_manager)

  if [ "$pkg_manager" = "unknown" ]; then
    say_err "No supported package manager found (apt, dnf, yum, pacman, apk, zypper)."
    say_err "Install opam manually: https://opam.ocaml.org/doc/Install.html"
    return 1
  fi

  if ! prompt_yes_no "Install opam and build prerequisites with $pkg_manager now?" "Y"; then
    return 1
  fi

  case "$pkg_manager" in
    apt)
      run_privileged apt-get update || true
      if ! run_privileged apt-get install -y opam build-essential m4 pkg-config libsqlite3-dev curl git; then
        say_err "apt installation failed."
        return 1
      fi
      run_privileged apt-get install -y bubblewrap 2>/dev/null || true
      ;;
    dnf)
      if ! run_privileged dnf install -y opam gcc make m4 pkgconfig sqlite-devel diffutils patch unzip curl git; then
        say_err "dnf installation failed."
        return 1
      fi
      run_privileged dnf install -y bubblewrap 2>/dev/null || true
      ;;
    yum)
      if ! run_privileged yum install -y gcc make m4 pkgconfig sqlite-devel diffutils patch unzip curl git; then
        say_err "yum installation failed."
        return 1
      fi
      if ! command -v opam >/dev/null 2>&1; then
        say "opam is not in yum repositories; bootstrapping local binary."
        return 1
      fi
      ;;
    pacman)
      if ! run_privileged pacman -Sy --noconfirm opam base-devel m4 pkgconf sqlite curl git; then
        say_err "pacman installation failed."
        return 1
      fi
      run_privileged pacman -S --noconfirm bubblewrap 2>/dev/null || true
      ;;
    apk)
      if ! run_privileged apk add opam build-base m4 pkgconf sqlite-dev curl git; then
        say_err "apk installation failed."
        return 1
      fi
      ;;
    zypper)
      if ! run_privileged zypper install -y opam gcc make m4 pkg-config sqlite3-devel curl git; then
        say_err "zypper installation failed."
        return 1
      fi
      run_privileged zypper install -y bubblewrap 2>/dev/null || true
      ;;
  esac

  return 0
}

platform_manual_setup_commands() {
  cat <<EOF
Manual setup:
  Install opam: https://opam.ocaml.org/doc/Install.html
  Ensure gcc, make, m4, pkg-config, sqlite dev headers, curl, and git are present.

  Clone the sibling dependency if it is missing:
    git clone "$DEFAULT_BULKHEAD_LM_REPO_URL" "$DEFAULT_BULKHEAD_LM_DIR"

  opam init --yes
  eval "\$(opam env --set-switch)"
  cd "$ROOT_DIR"
  opam pin add bulkhead_lm "$DEFAULT_BULKHEAD_LM_DIR" --yes --no-action
  opam install . --deps-only --yes
  ./run.sh
EOF
}

starter_main "$@"
