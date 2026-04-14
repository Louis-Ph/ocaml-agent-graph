#!/bin/sh
set -eu
# Run the adaptive webcrawler demo.
# Usage:
#   ./demos/adaptive_webcrawler/run.sh
#   ./demos/adaptive_webcrawler/run.sh "Find sources about Kubernetes multi-agent orchestration"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
eval "$(opam env 2>/dev/null || true)"

OBJECTIVE="${1:-}"
if [ -n "$OBJECTIVE" ]; then
  exec dune exec --root "$ROOT_DIR" ./bin/adaptive_webcrawler_demo.exe -- --objective "$OBJECTIVE"
else
  exec dune exec --root "$ROOT_DIR" ./bin/adaptive_webcrawler_demo.exe
fi
