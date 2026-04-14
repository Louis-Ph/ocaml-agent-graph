#!/bin/sh
set -eu

# OCaml Agent Graph one-line installer
# Usage:  curl -fsSL https://raw.githubusercontent.com/Louis-Ph/ocaml-agent-graph/main/install.sh | sh
#    or:  wget -qO- https://raw.githubusercontent.com/Louis-Ph/ocaml-agent-graph/main/install.sh | sh

REPO_URL="https://github.com/Louis-Ph/ocaml-agent-graph.git"
INSTALL_DIR="${AGENT_GRAPH_DIR:-$HOME/ocaml-agent-graph}"
BRANCH="${AGENT_GRAPH_BRANCH:-main}"

say() { printf '%s\n' "$1"; }
say_err() { printf '%s\n' "$1" >&2; }
fail() { say_err "$1"; exit 1; }

say ""
say "OCaml Agent Graph installer"
say "----------------------------"
say ""

# ── Check for git ───────────────────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
  say "git is not installed. Attempting to install it."
  OS_NAME=$(uname -s 2>/dev/null || printf 'unknown')
  case "$OS_NAME" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install git || fail "Could not install git via Homebrew."
      else
        say "Run: xcode-select --install"
        fail "Install Xcode Command Line Tools, then re-run this script."
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y git || fail "Could not install git."
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git || fail "Could not install git."
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y git || fail "Could not install git."
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm git || fail "Could not install git."
      elif command -v apk >/dev/null 2>&1; then
        sudo apk add git || fail "Could not install git."
      elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y git || fail "Could not install git."
      else
        fail "No supported package manager found. Install git manually, then re-run."
      fi
      ;;
    FreeBSD)
      if command -v pkg >/dev/null 2>&1; then
        sudo pkg install -y git || fail "Could not install git."
      else
        fail "Install git manually: pkg install git"
      fi
      ;;
    *)
      fail "Unsupported OS: $OS_NAME. Install git manually, then re-run."
      ;;
  esac
fi

# ── Clone or update ─────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  say "Updating existing installation in $INSTALL_DIR ..."
  git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
  git -C "$INSTALL_DIR" reset --quiet --hard "origin/$BRANCH"
else
  say "Cloning OCaml Agent Graph into $INSTALL_DIR ..."
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

# ── Launch ──────────────────────────────────────────────────────────
say ""
say "Installation directory: $INSTALL_DIR"
say "Starting OCaml Agent Graph setup ..."
say ""
say "BulkheadLM will be cloned automatically as a sibling dependency"
say "if it is not already present."
say ""

cd "$INSTALL_DIR"
exec ./run.sh "$@"
