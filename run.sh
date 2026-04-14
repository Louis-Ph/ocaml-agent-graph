#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

OS_NAME=$(uname -s 2>/dev/null || printf '%s' unknown)
case "$OS_NAME" in
  Darwin)
    STARTER_SCRIPT="$ROOT_DIR/scripts/macos_starter.sh"
    ;;
  Linux)
    STARTER_SCRIPT="$ROOT_DIR/scripts/linux_starter.sh"
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
  "$ROOT_DIR/scripts/linux_starter.sh" \
  "$ROOT_DIR/scripts/ubuntu_starter.sh" \
  "$ROOT_DIR/scripts/freebsd_starter.sh" \
  "$ROOT_DIR/scripts/remote_human_terminal.sh" \
  "$ROOT_DIR/scripts/remote_machine_terminal.sh" \
  "$ROOT_DIR/scripts/remote_install.sh" \
  "$ROOT_DIR/scripts/http_machine_server.sh" \
  "$ROOT_DIR/scripts/http_dist_server.sh" \
  "$ROOT_DIR/start-macos-client.command" >/dev/null 2>&1 || true

exec /bin/sh "$STARTER_SCRIPT" "$@"
