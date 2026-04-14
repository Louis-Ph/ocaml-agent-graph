#!/bin/sh
set -eu

# Start the full messenger stack in one command:
#   1. Build ocaml-agent-graph
#   2. Start the spokesperson HTTP server (background)
#   3. Generate a BulkheadLM gateway config with the swarm-spokesperson route
#      and auto-detected connector tokens
#   4. Start the BulkheadLM gateway server (background)
#   5. Open the interactive human terminal
#
# Usage:
#   ./scripts/start-with-messengers.sh
#   TELEGRAM_BOT_TOKEN=... ./scripts/start-with-messengers.sh

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BULKHEAD_LM_DIR=${AGENT_GRAPH_BULKHEAD_LM_DIR:-$ROOT_DIR/../bulkhead-lm}
SPOKESPERSON_PORT=${AGENT_GRAPH_SPOKESPERSON_PORT:-8087}
GATEWAY_PORT=${AGENT_GRAPH_GATEWAY_PORT:-4100}
CLIENT_CONFIG=${AGENT_GRAPH_CLIENT_CONFIG:-$ROOT_DIR/config/client.json}
GENERATED_GATEWAY_CONFIG="$ROOT_DIR/config/local_only/messenger.gateway.json"
VIRTUAL_KEY_TOKEN=${BULKHEAD_LM_API_KEY:-sk-bulkhead-lm-dev}

say() { printf '%s\n' "$1"; }
say_err() { printf '%s\n' "$1" >&2; }

cleanup_servers() {
  if [ -n "${SPOKESPERSON_PID:-}" ]; then
    kill "$SPOKESPERSON_PID" 2>/dev/null || true
  fi
  if [ -n "${GATEWAY_PID:-}" ]; then
    kill "$GATEWAY_PID" 2>/dev/null || true
  fi
}
trap cleanup_servers EXIT INT TERM

# ── Load secrets ────────────────────────────────────────────────────
for f in \
  "$HOME/.zshrc.secret" "$HOME/.zshrc.secrets" \
  "$HOME/.bashrc.secret" "$HOME/.bashrc.secrets" \
  "$HOME/.profile.secret" "$HOME/.profile.secrets" \
  "$HOME/.config/bulkhead-lm/env" \
  "$HOME/.config/ocaml-agent-graph/env"; do
  if [ -r "$f" ]; then
    set +eu; set -a; . "$f" >/dev/null 2>&1; set +a; set -eu
  fi
done

export BULKHEAD_LM_API_KEY="${BULKHEAD_LM_API_KEY:-$VIRTUAL_KEY_TOKEN}"
export AGENT_GRAPH_MESSENGER_TOKEN="${AGENT_GRAPH_MESSENGER_TOKEN:-$VIRTUAL_KEY_TOKEN}"

# ── Detect connectors ──────────────────────────────────────────────
detected_connectors=""
detect_connector() {
  env_name=$1; label=$2
  eval "val=\${${env_name}:-}"
  if [ -n "$val" ]; then
    detected_connectors="${detected_connectors}${detected_connectors:+, }$label"
    say "  [ok] $label (via $env_name)"
  fi
}

say ""
say "Messenger stack"
say "---------------"
say ""
say "Scanning for chat connector credentials:"
detect_connector TELEGRAM_BOT_TOKEN       "Telegram"
detect_connector WHATSAPP_ACCESS_TOKEN    "WhatsApp"
detect_connector MESSENGER_ACCESS_TOKEN   "Messenger"
detect_connector INSTAGRAM_ACCESS_TOKEN   "Instagram"
detect_connector LINE_ACCESS_TOKEN        "LINE"
detect_connector VIBER_AUTH_TOKEN          "Viber"
detect_connector WECHAT_SIGNATURE_TOKEN   "WeChat"
detect_connector DISCORD_PUBLIC_KEY        "Discord"

if [ -z "$detected_connectors" ]; then
  say "  (none detected)"
  say ""
  say "Set at least one connector token (e.g. TELEGRAM_BOT_TOKEN) in"
  say "~/.bashrc.secrets, then re-run this script."
  exit 1
fi

say ""

# ── Ensure build ────────────────────────────────────────────────────
say "Building ocaml-agent-graph ..."
eval "$(opam env 2>/dev/null || true)"
(cd "$ROOT_DIR" && dune build bin/client.exe 2>/dev/null) || {
  say "First build; running full setup via ./run.sh"
  exec "$ROOT_DIR/run.sh"
}

# ── Generate gateway config ─────────────────────────────────────────
say "Generating messenger gateway config ..."

mkdir -p "$(dirname "$GENERATED_GATEWAY_CONFIG")"

# Build the connector JSON blocks
connector_json() {
  key=$1; label=$2; primary_field=$3; primary_env=$4; webhook=$5
  shift 5
  extra=""
  while [ "$#" -gt 0 ]; do
    extra="${extra}, \"$1\": \"$2\""
    shift 2
  done
  cat <<ENDBLOCK
    "$key": {
      "enabled": true,
      "webhook_path": "$webhook",
      "$primary_field": "$primary_env"${extra},
      "authorization_env": "BULKHEAD_LM_API_KEY",
      "route_model": "swarm-spokesperson",
      "system_prompt": "Reply in a concise, practical tone for chat users."
    }
ENDBLOCK
}

connectors_block=""
append_connector() {
  env_name=$1; shift
  eval "val=\${${env_name}:-}"
  if [ -n "$val" ]; then
    block=$(connector_json "$@")
    if [ -n "$connectors_block" ]; then
      connectors_block="${connectors_block},
${block}"
    else
      connectors_block="$block"
    fi
  fi
}

append_connector TELEGRAM_BOT_TOKEN     telegram    bot_token_env       TELEGRAM_BOT_TOKEN      /connectors/telegram/webhook
append_connector WHATSAPP_ACCESS_TOKEN  whatsapp    access_token_env    WHATSAPP_ACCESS_TOKEN   /connectors/whatsapp/webhook   verify_token_env WHATSAPP_VERIFY_TOKEN
append_connector MESSENGER_ACCESS_TOKEN messenger   access_token_env    MESSENGER_ACCESS_TOKEN  /connectors/messenger/webhook  verify_token_env MESSENGER_VERIFY_TOKEN
append_connector INSTAGRAM_ACCESS_TOKEN instagram   access_token_env    INSTAGRAM_ACCESS_TOKEN  /connectors/instagram/webhook  verify_token_env INSTAGRAM_VERIFY_TOKEN
append_connector LINE_ACCESS_TOKEN      line        access_token_env    LINE_ACCESS_TOKEN       /connectors/line/webhook       channel_secret_env LINE_CHANNEL_SECRET
append_connector VIBER_AUTH_TOKEN        viber       auth_token_env      VIBER_AUTH_TOKEN         /connectors/viber/webhook
append_connector WECHAT_SIGNATURE_TOKEN wechat      signature_token_env WECHAT_SIGNATURE_TOKEN  /connectors/wechat/webhook
append_connector DISCORD_PUBLIC_KEY     discord     public_key_env      DISCORD_PUBLIC_KEY       /connectors/discord/webhook

# Find BulkheadLM's defaults directory
blm_defaults_dir="$BULKHEAD_LM_DIR/config/defaults"
security_policy_file="$blm_defaults_dir/security_policy.json"
error_catalog_file="$blm_defaults_dir/error_catalog.json"
providers_schema_file="$blm_defaults_dir/providers.schema.json"

cat > "$GENERATED_GATEWAY_CONFIG" <<ENDCONFIG
{
  "security_policy_file": "$security_policy_file",
  "error_catalog_file": "$error_catalog_file",
  "providers_schema_file": "$providers_schema_file",
  "persistence": {
    "sqlite_path": "$ROOT_DIR/var/messenger-gateway.sqlite",
    "busy_timeout_ms": 10000
  },
  "user_connectors": {
${connectors_block}
  },
  "virtual_keys": [
    {
      "name": "messenger-swarm",
      "token_plaintext": "$VIRTUAL_KEY_TOKEN",
      "daily_token_budget": 1000000,
      "requests_per_minute": 300,
      "allowed_routes": ["swarm-spokesperson"]
    }
  ],
  "routes": [
    {
      "public_model": "swarm-spokesperson",
      "backends": [
        {
          "provider_id": "agent-graph-spokesperson",
          "provider_kind": "openai_compat",
          "upstream_model": "swarm-spokesperson",
          "api_base": "http://127.0.0.1:${SPOKESPERSON_PORT}/v1/messenger",
          "api_key_env": "AGENT_GRAPH_MESSENGER_TOKEN"
        }
      ]
    }
  ]
}
ENDCONFIG

say "Gateway config written to $GENERATED_GATEWAY_CONFIG"

# ── Start spokesperson server ───────────────────────────────────────
say "Starting spokesperson server on port $SPOKESPERSON_PORT ..."
(cd "$ROOT_DIR" && dune exec ./bin/client.exe -- serve-http \
  --client-config "$CLIENT_CONFIG" --port "$SPOKESPERSON_PORT" &)
SPOKESPERSON_PID=$!
sleep 1

if ! kill -0 "$SPOKESPERSON_PID" 2>/dev/null; then
  say_err "Spokesperson server failed to start."
  exit 1
fi

# ── Start BulkheadLM gateway ────────────────────────────────────────
say "Starting BulkheadLM gateway on port $GATEWAY_PORT ..."
blm_client=$(find "$BULKHEAD_LM_DIR/_build" -name "main.exe" -type f 2>/dev/null | head -1 || true)
if [ -z "$blm_client" ]; then
  (cd "$BULKHEAD_LM_DIR" && dune build bin/main.exe 2>/dev/null)
  blm_client="$BULKHEAD_LM_DIR/_build/default/bin/main.exe"
fi

"$blm_client" --config "$GENERATED_GATEWAY_CONFIG" --port "$GATEWAY_PORT" &
GATEWAY_PID=$!
sleep 1

if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
  say_err "BulkheadLM gateway failed to start."
  exit 1
fi

say ""
say "Stack running:"
say "  Spokesperson: http://127.0.0.1:$SPOKESPERSON_PORT"
say "  Gateway:      http://127.0.0.1:$GATEWAY_PORT"
say "  Connectors:   $detected_connectors"
say ""
say "Point your platform webhooks to https://your-public-host/connectors/<name>/webhook"
say ""
say "Opening interactive terminal ..."
say ""

# ── Open interactive terminal ───────────────────────────────────────
cd "$ROOT_DIR"
client_runner="$ROOT_DIR/_build/default/bin/client.exe"
"$client_runner" ask --client-config "$CLIENT_CONFIG" || true

say "Shutting down servers ..."
