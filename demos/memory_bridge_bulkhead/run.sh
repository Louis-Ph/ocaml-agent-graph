#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BULKHEAD_LM_DIR=${AGENT_GRAPH_BULKHEAD_LM_DIR:-$ROOT_DIR/../bulkhead-lm}
DEMO_DIR=${AGENT_GRAPH_MEMORY_DEMO_DIR:-$ROOT_DIR/var/memory-bridge-demo}
GATEWAY_PORT=${AGENT_GRAPH_MEMORY_DEMO_GATEWAY_PORT:-4100}
SESSION_ID=${AGENT_GRAPH_MEMORY_DEMO_SESSION_ID:-memory-bridge-demo}
SESSION_NAMESPACE=${AGENT_GRAPH_MEMORY_DEMO_NAMESPACE:-demo-memory}
VIRTUAL_KEY_TOKEN=${BULKHEAD_LM_API_KEY:-sk-bulkhead-lm-dev}
ADMIN_TOKEN=${BULKHEAD_ADMIN_TOKEN:-bulkhead-admin-demo}

GATEWAY_CONFIG="$DEMO_DIR/gateway.json"
SECURITY_POLICY="$DEMO_DIR/security_policy.json"
RUNTIME_CONFIG="$DEMO_DIR/runtime.json"
CLIENT_CONFIG="$DEMO_DIR/client.json"
MEMORY_POLICY="$DEMO_DIR/memory_policy.json"
CONTROL_BASE="http://127.0.0.1:${GATEWAY_PORT}/_bulkhead/control"
REMOTE_SESSION_KEY="swarm:${SESSION_NAMESPACE}:${SESSION_ID}"

say() { printf '%s\n' "$1"; }
say_err() { printf '%s\n' "$1" >&2; }

cleanup() {
  if [ -n "${GATEWAY_PID:-}" ]; then
    kill "$GATEWAY_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

load_secrets() {
  for f in \
    "$HOME/.zshrc.secret" "$HOME/.zshrc.secrets" \
    "$HOME/.bashrc.secret" "$HOME/.bashrc.secrets" \
    "$HOME/.profile.secret" "$HOME/.profile.secrets" \
    "$HOME/.config/bulkhead-lm/env" \
    "$HOME/.config/ocaml-agent-graph/env"; do
    if [ -r "$f" ]; then
      set +eu
      set -a
      . "$f" >/dev/null 2>&1
      set +a
      set -eu
    fi
  done
}

detect_provider() {
  if [ -n "${OPEN_ROUTER_KEY:-}" ]; then
    DEMO_ROUTE_MODEL=openrouter-auto
    DEMO_PROVIDER_ID=openrouter-auto
    DEMO_PROVIDER_KIND=openrouter_openai
    DEMO_UPSTREAM_MODEL=openrouter/auto
    DEMO_API_BASE=https://openrouter.ai/api/v1
    DEMO_API_KEY_ENV=OPEN_ROUTER_KEY
    return 0
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    DEMO_ROUTE_MODEL=claude-sonnet
    DEMO_PROVIDER_ID=anthropic-claude-sonnet
    DEMO_PROVIDER_KIND=anthropic
    DEMO_UPSTREAM_MODEL=claude-sonnet-4-5
    DEMO_API_BASE=https://api.anthropic.com/v1
    DEMO_API_KEY_ENV=ANTHROPIC_API_KEY
    return 0
  fi
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    DEMO_ROUTE_MODEL=gpt-5-mini
    DEMO_PROVIDER_ID=openai-gpt-5-mini
    DEMO_PROVIDER_KIND=openai_compat
    DEMO_UPSTREAM_MODEL=gpt-5-mini
    DEMO_API_BASE=https://api.openai.com/v1
    DEMO_API_KEY_ENV=OPENAI_API_KEY
    return 0
  fi
  if [ -n "${GOOGLE_API_KEY:-}" ]; then
    DEMO_ROUTE_MODEL=gemini-2.5-flash
    DEMO_PROVIDER_ID=google-gemini-2-5-flash
    DEMO_PROVIDER_KIND=google_openai
    DEMO_UPSTREAM_MODEL=gemini-2.5-flash
    DEMO_API_BASE=https://generativelanguage.googleapis.com/v1beta/openai/
    DEMO_API_KEY_ENV=GOOGLE_API_KEY
    return 0
  fi
  say_err "No supported provider key detected."
  say_err "Set one of OPEN_ROUTER_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY."
  exit 1
}

write_security_policy() {
  cat > "$SECURITY_POLICY" <<EOF
{
  "server": {
    "listen_host": "127.0.0.1",
    "listen_port": ${GATEWAY_PORT},
    "max_request_body_bytes": 5242880,
    "request_timeout_ms": 120000
  },
  "auth": {
    "header": "authorization",
    "bearer_prefix": "Bearer ",
    "hash_algorithm": "sha256",
    "require_virtual_key": true
  },
  "redaction": {
    "json_keys": ["api_key", "authorization", "x-api-key", "proxy-authorization", "client_secret", "password"],
    "replacement": "[REDACTED]"
  },
  "privacy_filter": {
    "enabled": true,
    "replacement": "[REDACTED]",
    "redact_email_addresses": true,
    "redact_phone_numbers": true,
    "redact_ipv4_addresses": true,
    "redact_national_ids": true,
    "redact_payment_cards": true,
    "secret_prefixes": ["sk-", "rk-", "pk-", "ghp_", "gho_", "github_pat_"],
    "additional_literal_tokens": []
  },
  "threat_detector": {
    "enabled": true,
    "prompt_injection_signals": ["ignore previous instructions", "ignore all prior instructions", "disregard your safety policy", "reveal the system prompt", "show the developer message", "repeat the hidden instructions"],
    "credential_exfiltration_signals": ["reveal api key", "print the bearer token", "show me the secret", "dump credentials"],
    "tool_abuse_signals": ["exfiltrate data", "exfiltrate credentials", "disable the guardrails", "bypass safety", "read /etc/passwd", "fetch metadata from 169.254.169.254"]
  },
  "output_guard": {
    "enabled": true,
    "blocked_substrings": ["-----begin private key-----", "-----begin openssh private key-----", "aws_secret_access_key", "authorization: bearer "],
    "blocked_secret_prefixes": ["ssh-rsa ", "ssh-ed25519 "]
  },
  "egress": {
    "deny_private_ranges": true,
    "allowed_schemes": ["https", "http", "ssh"],
    "blocked_hosts": ["localhost", "127.0.0.1", "::1"]
  },
  "mesh": {
    "enabled": true,
    "max_hops": 1,
    "request_id_header": "x-bulkhead-lm-request-id",
    "hop_count_header": "x-bulkhead-lm-hop-count"
  },
  "control_plane": {
    "enabled": true,
    "path_prefix": "/_bulkhead/control",
    "ui_enabled": true,
    "allow_reload": true,
    "admin_token_env": "BULKHEAD_ADMIN_TOKEN"
  },
  "client_ops": {
    "files": {
      "enabled": false,
      "read_roots": [],
      "write_roots": [],
      "max_read_bytes": 1048576,
      "max_write_bytes": 1048576
    },
    "exec": {
      "enabled": false,
      "working_roots": [],
      "timeout_ms": 10000,
      "max_output_bytes": 65536
    }
  },
  "routing": {
    "max_fallbacks": 5,
    "strategy": "priority",
    "max_inflight": 512,
    "circuit_open_threshold": 5,
    "circuit_cooldown_s": 30
  },
  "rate_limit": {
    "default_requests_per_minute": 300
  },
  "budget": {
    "default_daily_tokens": 1000000
  }
}
EOF
}

write_gateway_config() {
  cat > "$GATEWAY_CONFIG" <<EOF
{
  "security_policy_file": "$SECURITY_POLICY",
  "error_catalog_file": "$BULKHEAD_LM_DIR/config/defaults/error_catalog.json",
  "providers_schema_file": "$BULKHEAD_LM_DIR/config/defaults/providers.schema.json",
  "persistence": {
    "sqlite_path": "$DEMO_DIR/bulkhead-memory-demo.sqlite",
    "busy_timeout_ms": 10000
  },
  "virtual_keys": [
    {
      "name": "memory-demo",
      "token_plaintext": "$VIRTUAL_KEY_TOKEN",
      "daily_token_budget": 1000000,
      "requests_per_minute": 120,
      "allowed_routes": ["$DEMO_ROUTE_MODEL"]
    }
  ],
  "routes": [
    {
      "public_model": "$DEMO_ROUTE_MODEL",
      "backends": [
        {
          "provider_id": "$DEMO_PROVIDER_ID",
          "provider_kind": "$DEMO_PROVIDER_KIND",
          "upstream_model": "$DEMO_UPSTREAM_MODEL",
          "api_base": "$DEMO_API_BASE",
          "api_key_env": "$DEMO_API_KEY_ENV"
        }
      ]
    }
  ]
}
EOF
}

write_memory_policy() {
  cat > "$MEMORY_POLICY" <<EOF
{
  "enabled": true,
  "session_namespace": "${SESSION_NAMESPACE}",
  "session_id_metadata_key": "session_id",
  "storage": {
    "mode": "explicit_sqlite",
    "sqlite_path": "./agent-graph-memory.sqlite"
  },
  "reload": {
    "recent_turn_buffer": 2
  },
  "compression": {
    "policy_name": "fibonacci_memory_bridge_demo_v1",
    "trigger": {
      "mode": "fibonacci",
      "fibonacci_first_reply": 3,
      "fibonacci_second_reply": 5
    },
    "budget": {
      "mode": "fibonacci_decay",
      "base_summary_max_chars": 1200,
      "min_summary_max_chars": 240,
      "base_summary_max_tokens": 180,
      "min_summary_max_tokens": 48
    },
    "value_hierarchy": {
      "keep_verbatim": [
        "project name, stakeholder names, and hard identifiers",
        "fixed deadlines and hard budget ceilings",
        "approved decisions that must remain stable"
      ],
      "keep_strongly": [
        "current goal and success criteria",
        "blocked items, risks, and unresolved decisions",
        "supplier constraints and route eligibility rules"
      ],
      "compress_first": [
        "supporting rationale once the conclusion is stable",
        "discarded alternatives and temporary scaffolding",
        "intermediate wording that does not change execution"
      ],
      "drop_first": [
        "repetition and conversational filler",
        "stylistic phrasing",
        "obsolete low-signal detail"
      ]
    },
    "summary_prompt": "Compress this durable swarm memory into one short factual note. Preserve stable goals, constraints, names, preferences, decisions, blockers, and unresolved items."
  },
  "bulkhead_bridge": {
    "endpoint_url": "http://127.0.0.1:${GATEWAY_PORT}/_bulkhead/control/api/memory/session",
    "session_key_prefix": "swarm",
    "authorization_token_env": "BULKHEAD_ADMIN_TOKEN",
    "timeout_seconds": 5.0
  }
}
EOF
}

write_runtime_config() {
  cat > "$RUNTIME_CONFIG" <<EOF
{
  "engine": {
    "timeout_seconds": 20.0,
    "retry_attempts": 1,
    "retry_backoff_seconds": 0.05,
    "max_steps": 8
  },
  "routing": {
    "long_text_threshold": 9999,
    "short_text_agent": "summarizer",
    "planner_agent": "planner",
    "parallel_agents": ["summarizer", "validator"]
  },
  "llm": {
    "gateway_config_path": "gateway.json",
    "authorization_token_plaintext": "$VIRTUAL_KEY_TOKEN",
    "planner": {
      "route_model": "$DEMO_ROUTE_MODEL",
      "system_prompt": "You are the planning agent inside a typed OCaml orchestration graph. Convert a request into a short, concrete plan.",
      "max_tokens": 220,
      "confidence": 0.91
    },
    "summarizer": {
      "route_model": "$DEMO_ROUTE_MODEL",
      "system_prompt": "You are the summarizer agent inside a typed OCaml orchestration graph. Compress the payload into a short, accurate summary.",
      "max_tokens": 220,
      "confidence": 0.88
    },
    "validator": {
      "route_model": "$DEMO_ROUTE_MODEL",
      "system_prompt": "You are the validator agent inside a typed OCaml orchestration graph. Check whether the payload is coherent and safe to pass forward.",
      "max_tokens": 220,
      "confidence": 0.94
    }
  },
  "discussion": {
    "enabled": false,
    "rounds": 2,
    "max_nesting_depth": 0,
    "final_agent": "summarizer",
    "participants": []
  },
  "memory_policy_path": "memory_policy.json",
  "demo": {
    "task_id": "memory-bridge-demo",
    "input": "Show the memory bridge demo."
  }
}
EOF
}

write_client_config() {
  cat > "$CLIENT_CONFIG" <<EOF
{
  "graph_runtime_path": "runtime.json",
  "assistant": {
    "route_model": "$DEMO_ROUTE_MODEL",
    "system_prompt_file": "$ROOT_DIR/config/prompts/graph_terminal_assistant.md",
    "max_tokens": 400
  },
  "local_ops": {
    "workspace_root": "$ROOT_DIR",
    "max_read_bytes": 32000,
    "max_exec_output_bytes": 12000,
    "command_timeout_ms": 10000
  },
  "human_terminal": {
    "show_routes_on_start": false,
    "conversation_keep_turns": 6
  },
  "machine_terminal": {
    "worker_jobs": 2
  },
  "transport": {
    "ssh": {
      "human_remote_command": "scripts/remote_human_terminal.sh --client-config config/client.json",
      "machine_remote_command": "scripts/remote_machine_terminal.sh --client-config config/client.json --jobs 2",
      "install_emit_command": "scripts/remote_install.sh --emit-installer --origin user@host"
    },
    "http": {
      "workflow": {
        "base_url": "http://127.0.0.1:8087",
        "server_command": "scripts/http_machine_server.sh --client-config config/client.json --port 8087"
      },
      "distribution": {
        "base_url": "http://127.0.0.1:8788",
        "server_command": "scripts/http_dist_server.sh --public-base-url http://127.0.0.1:8788",
        "install_url": "http://127.0.0.1:8788/install.sh",
        "archive_url": "http://127.0.0.1:8788/ocaml-agent-graph.tar.gz"
      }
    }
  }
}
EOF
}

wait_for_control_plane() {
  attempt=0
  until curl -fsS \
      -H "authorization: Bearer $ADMIN_TOKEN" \
      "$CONTROL_BASE/api/status" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      say_err "BulkheadLM control plane did not become ready."
      exit 1
    fi
    sleep 1
  done
}

show_json() {
  path=$1
  if command -v jq >/dev/null 2>&1; then
    jq . "$path"
  else
    cat "$path"
  fi
}

run_turn() {
  turn_no=$1
  prompt=$2
  output_path="$DEMO_DIR/turn-${turn_no}.json"
  printf '{\n  "task_id": "memory-bridge-turn-%s",\n  "session_id": "%s",\n  "input": "%s"\n}\n' \
    "$turn_no" "$SESSION_ID" "$prompt" \
    | (cd "$ROOT_DIR" && dune exec ./bin/client.exe -- call --client-config "$CLIENT_CONFIG" --kind run_graph) \
    > "$output_path"
  say "Turn ${turn_no} written to ${output_path}"
}

load_secrets
detect_provider

mkdir -p "$DEMO_DIR"
rm -f \
  "$DEMO_DIR"/turn-*.json \
  "$DEMO_DIR"/bulkhead-session.json \
  "$DEMO_DIR"/bulkhead-status.json

export BULKHEAD_LM_API_KEY="$VIRTUAL_KEY_TOKEN"
export BULKHEAD_ADMIN_TOKEN="$ADMIN_TOKEN"

write_security_policy
write_gateway_config
write_memory_policy
write_runtime_config
write_client_config

say ""
say "Memory bridge demo"
say "------------------"
say "route_model: $DEMO_ROUTE_MODEL"
say "session_id: $SESSION_ID"
say "remote_session_key: $REMOTE_SESSION_KEY"
say "demo_dir: $DEMO_DIR"
say ""

say "Building binaries ..."
eval "$(opam env 2>/dev/null || true)"
(cd "$ROOT_DIR" && dune build bin/client.exe)
(cd "$BULKHEAD_LM_DIR" && dune build bin/main.exe)

say "Starting BulkheadLM gateway on port $GATEWAY_PORT ..."
(cd "$BULKHEAD_LM_DIR" && dune exec ./bin/main.exe -- --config "$GATEWAY_CONFIG" --port "$GATEWAY_PORT" >/dev/null 2>&1 &)
GATEWAY_PID=$!

wait_for_control_plane

curl -fsS \
  -H "authorization: Bearer $ADMIN_TOKEN" \
  "$CONTROL_BASE/api/status" \
  > "$DEMO_DIR/bulkhead-status.json"

run_turn 1 "Project Atlas must ship before 2026-07-01 and the budget stays under 180000 EUR."
run_turn 2 "Use route B only if supplier lead time stays under 21 days."
run_turn 3 "Keep Nora as the final approver and keep Bruno on vendor negotiations."
run_turn 4 "The steel supplier is preferred but only if the customs delay risk stays below medium."
run_turn 5 "Do not lose the approved decision that warehouse beta stays the fallback site."

curl -fsS \
  -H "authorization: Bearer $ADMIN_TOKEN" \
  "$CONTROL_BASE/api/memory/session?session_key=$REMOTE_SESSION_KEY" \
  > "$DEMO_DIR/bulkhead-session.json"

say ""
say "Control plane status:"
show_json "$DEMO_DIR/bulkhead-status.json"

say ""
say "Final agent-graph turn response:"
show_json "$DEMO_DIR/turn-5.json"

say ""
say "Mirrored BulkheadLM session:"
show_json "$DEMO_DIR/bulkhead-session.json"

if grep -q '"label": "memory.compressed"' "$DEMO_DIR/turn-5.json"; then
  say ""
  say "[ok] memory.compressed event observed in agent-graph output."
else
  say ""
  say_err "[warn] memory.compressed event was not found in turn-5.json."
fi

if grep -q '"session_key":' "$DEMO_DIR/bulkhead-session.json"; then
  say "[ok] mirrored memory session fetched from BulkheadLM control plane."
fi

say ""
say "Files kept in $DEMO_DIR for inspection."
