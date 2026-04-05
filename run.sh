#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

linux_is_ubuntu() {
  [ -r /etc/os-release ] || return 1
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
  return 1
}

OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
case "$OS_NAME" in
  Darwin)
    STARTER_SCRIPT="$ROOT_DIR/scripts/macos_starter.sh"
    ;;
  Linux)
    if linux_is_ubuntu; then
      STARTER_SCRIPT="$ROOT_DIR/scripts/ubuntu_starter.sh"
    else
      printf '%s\n' "This local starter currently supports Ubuntu on Linux." >&2
      printf '%s\n' "Use an installed opam switch, then run scripts/ubuntu_starter.sh manually on other Linux distributions." >&2
      exit 1
    fi
    ;;
  FreeBSD)
    STARTER_SCRIPT="$ROOT_DIR/scripts/freebsd_starter.sh"
    ;;
  *)
    printf '%s\n' "Unsupported host OS: $OS_NAME" >&2
    printf '%s\n' "Use an installed opam switch, then run _build/default/bin/client.exe ask --client-config config/client.json" >&2
    exit 1
    ;;
esac

chmod +x \
  "$ROOT_DIR/run.sh" \
  "$ROOT_DIR/scripts/starter_common.sh" \
  "$ROOT_DIR/scripts/macos_starter.sh" \
  "$ROOT_DIR/scripts/ubuntu_starter.sh" \
  "$ROOT_DIR/scripts/freebsd_starter.sh" \
  "$ROOT_DIR/scripts/remote_human_terminal.sh" \
  "$ROOT_DIR/scripts/remote_machine_terminal.sh" \
  "$ROOT_DIR/scripts/remote_install.sh" \
  "$ROOT_DIR/scripts/http_machine_server.sh" \
  "$ROOT_DIR/scripts/http_dist_server.sh" \
  "$ROOT_DIR/start-macos-client.command" >/dev/null 2>&1 || true

exec /bin/sh "$STARTER_SCRIPT" "$@"
