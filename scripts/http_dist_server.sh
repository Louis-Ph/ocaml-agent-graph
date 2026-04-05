#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

PORT=${AGENT_GRAPH_HTTP_DIST_PORT:-8788}
BIND=${AGENT_GRAPH_HTTP_DIST_BIND:-127.0.0.1}
PUBLIC_BASE_URL=${AGENT_GRAPH_HTTP_DIST_PUBLIC_BASE_URL:-}
DIST_DIR=

note() {
  printf '%s\n' "$*" >&2
}

print_help() {
  cat <<EOF
Usage: scripts/http_dist_server.sh [options]

Options:
  --port PORT            HTTP port. Default: ${PORT}
  --bind HOST            Bind host for the local HTTP server. Default: ${BIND}
  --public-base-url URL  Public URL advertised inside install.sh and index.html
  --dist-dir DIR         Reuse an existing dist directory instead of a temp dir
  --help                 Show this help

Examples:
  scripts/http_dist_server.sh --public-base-url http://127.0.0.1:8788
  scripts/http_dist_server.sh --bind 0.0.0.0 --port 8788 --public-base-url http://machine-a.example.net:8788

The server exposes:
  /install.sh
  /ocaml-agent-graph.tar.gz
  /index.html
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --port)
      [ "$#" -ge 2 ] || { note "--port requires a value"; exit 1; }
      PORT=$2
      shift 2
      ;;
    --bind)
      [ "$#" -ge 2 ] || { note "--bind requires a value"; exit 1; }
      BIND=$2
      shift 2
      ;;
    --public-base-url)
      [ "$#" -ge 2 ] || { note "--public-base-url requires a value"; exit 1; }
      PUBLIC_BASE_URL=$2
      shift 2
      ;;
    --dist-dir)
      [ "$#" -ge 2 ] || { note "--dist-dir requires a value"; exit 1; }
      DIST_DIR=$2
      shift 2
      ;;
    *)
      note "Unknown option: $1"
      exit 1
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  note "python3 is required to serve the HTTP distribution directory."
  exit 1
fi

if [ -z "${PUBLIC_BASE_URL}" ]; then
  PUBLIC_BASE_URL="http://${BIND}:${PORT}"
fi

cleanup() {
  if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR}" ]; then
    rm -rf "${TEMP_DIR}"
  fi
}

if [ -n "${DIST_DIR}" ]; then
  mkdir -p "${DIST_DIR}"
else
  TEMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t agent-graph-http-dist)
  DIST_DIR="${TEMP_DIR}"
  trap cleanup EXIT HUP INT TERM
fi

"${ROOT_DIR}/scripts/remote_install.sh" --archive > "${DIST_DIR}/ocaml-agent-graph.tar.gz"
"${ROOT_DIR}/scripts/remote_install.sh" \
  --emit-http-installer \
  --base-url "${PUBLIC_BASE_URL}" \
  > "${DIST_DIR}/install.sh"
chmod +x "${DIST_DIR}/install.sh"

cat > "${DIST_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>ocaml-agent-graph dist</title>
    <style>
      body { font-family: Menlo, Monaco, Consolas, monospace; margin: 2rem; background: #07111f; color: #e7f3ff; }
      h1 { color: #7de2d1; }
      code, pre { background: #0f2238; padding: 0.75rem; border-radius: 8px; display: block; overflow-x: auto; }
      a { color: #9ad1ff; }
      .card { border: 1px solid #21415f; border-radius: 10px; padding: 1rem; margin-bottom: 1rem; }
    </style>
  </head>
  <body>
    <h1>ocaml-agent-graph distribution</h1>
    <div class="card">
      <p>HTTP install:</p>
      <pre>curl -fsSL ${PUBLIC_BASE_URL}/install.sh | sh</pre>
    </div>
    <div class="card">
      <p>Artifacts:</p>
      <pre><a href="${PUBLIC_BASE_URL}/install.sh">${PUBLIC_BASE_URL}/install.sh</a>
<a href="${PUBLIC_BASE_URL}/ocaml-agent-graph.tar.gz">${PUBLIC_BASE_URL}/ocaml-agent-graph.tar.gz</a></pre>
    </div>
    <div class="card">
      <p>Next step after install:</p>
      <pre>cd \$HOME/opt/ocaml-agent-graph
./run.sh</pre>
    </div>
  </body>
</html>
EOF

note "Serving ${DIST_DIR} on ${PUBLIC_BASE_URL}"
note "Install with:"
note "  curl -fsSL ${PUBLIC_BASE_URL}/install.sh | sh"
note "Archive URL:"
note "  ${PUBLIC_BASE_URL}/ocaml-agent-graph.tar.gz"

cd "${DIST_DIR}"
exec python3 -m http.server "${PORT}" --bind "${BIND}"
