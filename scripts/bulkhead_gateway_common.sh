AGENT_GRAPH_BULKHEAD_GATEWAY_AUTOSTART=${AGENT_GRAPH_BULKHEAD_GATEWAY_AUTOSTART:-1}

agent_graph_json_string_field() {
  json_file=$1
  field_name=$2
  [ -r "$json_file" ] || return 1
  sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$json_file" | head -n 1
}

agent_graph_resolve_path() {
  base_dir=$1
  candidate=$2
  [ -n "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *) printf '%s\n' "$base_dir/$candidate" ;;
  esac
}

agent_graph_is_loopback_endpoint() {
  endpoint_url=$1
  case "$endpoint_url" in
    http://127.0.0.1:*|http://localhost:*|http://[::1]:*|https://127.0.0.1:*|https://localhost:*|https://[::1]:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

agent_graph_bulkhead_binary() {
  bulkhead_dir=$1
  if [ -x "$bulkhead_dir/_build/default/bin/main.exe" ]; then
    printf '%s\n' "$bulkhead_dir/_build/default/bin/main.exe"
    return 0
  fi
  if ! command -v dune >/dev/null 2>&1; then
    return 1
  fi
  if ! (cd "$bulkhead_dir" && dune build bin/main.exe >/dev/null 2>&1); then
    return 1
  fi
  if [ -x "$bulkhead_dir/_build/default/bin/main.exe" ]; then
    printf '%s\n' "$bulkhead_dir/_build/default/bin/main.exe"
    return 0
  fi
  return 1
}

agent_graph_gateway_expected_routes() {
  gateway_config=$1
  [ -r "$gateway_config" ] || return 1
  sed -n 's/.*"public_model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$gateway_config"
}

agent_graph_gateway_matches_expected_routes() {
  gateway_endpoint_url=$1
  gateway_config=$2

  models_json=$(curl -fsS "${gateway_endpoint_url%/}/v1/models" 2>/dev/null || true)
  [ -n "$models_json" ] || return 1

  expected_routes=$(agent_graph_gateway_expected_routes "$gateway_config" || true)
  [ -n "$expected_routes" ] || return 1

  old_ifs=$IFS
  IFS='
'
  for route_model in $expected_routes; do
    if ! printf '%s' "$models_json" | grep -F "\"$route_model\"" >/dev/null 2>&1; then
      IFS=$old_ifs
      return 1
    fi
  done
  IFS=$old_ifs
  return 0
}

agent_graph_endpoint_port() {
  endpoint_url=$1
  printf '%s\n' "$endpoint_url" | sed -n 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^:/]*:\([0-9][0-9]*\)\(/.*\)\{0,1\}$#\1#p'
}

agent_graph_listener_pids() {
  port=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
    return 0
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser "$port/tcp" 2>/dev/null || true
    return 0
  fi
  if command -v sockstat >/dev/null 2>&1; then
    sockstat -4 -6 -l 2>/dev/null | awk -v port=":$port" '$6 ~ port { print $3 }' || true
    return 0
  fi
  return 1
}

agent_graph_stop_listener() {
  port=$1
  pids=$(agent_graph_listener_pids "$port" || true)
  [ -n "$pids" ] || return 1

  old_ifs=$IFS
  IFS=' 	
'
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  IFS=$old_ifs
  sleep 0.5
  return 0
}

agent_graph_ensure_external_bulkhead_gateway() {
  root_dir=$1
  bulkhead_dir=$2
  client_config=$3

  [ "${AGENT_GRAPH_BULKHEAD_GATEWAY_AUTOSTART}" = "1" ] || return 0
  [ -r "$client_config" ] || return 0

  client_config_dir=$(dirname "$client_config")
  runtime_rel=$(agent_graph_json_string_field "$client_config" "graph_runtime_path" || true)
  [ -n "$runtime_rel" ] || return 0
  runtime_config=$(agent_graph_resolve_path "$client_config_dir" "$runtime_rel" || true)
  [ -n "$runtime_config" ] || return 0
  [ -r "$runtime_config" ] || return 0

  runtime_config_dir=$(dirname "$runtime_config")
  gateway_endpoint_url=$(agent_graph_json_string_field "$runtime_config" "gateway_endpoint_url" || true)
  if [ -z "$gateway_endpoint_url" ]; then
    gateway_endpoint_url="http://127.0.0.1:4140"
  fi

  agent_graph_is_loopback_endpoint "$gateway_endpoint_url" || return 0

  gateway_rel=$(agent_graph_json_string_field "$runtime_config" "gateway_config_path" || true)
  [ -n "$gateway_rel" ] || return 0
  gateway_config=$(agent_graph_resolve_path "$runtime_config_dir" "$gateway_rel" || true)
  [ -n "$gateway_config" ] || return 0
  [ -r "$gateway_config" ] || return 1

  health_url="${gateway_endpoint_url%/}/health"
  if curl -fsS "$health_url" >/dev/null 2>&1; then
    if agent_graph_gateway_matches_expected_routes "$gateway_endpoint_url" "$gateway_config"; then
      return 0
    fi

    gateway_port=$(agent_graph_endpoint_port "$gateway_endpoint_url" || true)
    if [ -z "$gateway_port" ]; then
      printf '%s\n' "BulkheadLM is healthy at $gateway_endpoint_url but exposes the wrong routes, and the port could not be determined for a restart." >&2
      return 1
    fi

    printf '%s\n' "BulkheadLM is healthy at $gateway_endpoint_url but does not match $gateway_config; restarting the loopback listener." >&2
    if ! agent_graph_stop_listener "$gateway_port"; then
      printf '%s\n' "Unable to stop the existing BulkheadLM listener on port $gateway_port." >&2
      return 1
    fi

    attempt=0
    while [ "$attempt" -lt 12 ]; do
      if ! curl -fsS "$health_url" >/dev/null 2>&1; then
        break
      fi
      attempt=$((attempt + 1))
      sleep 0.25
    done

    if curl -fsS "$health_url" >/dev/null 2>&1; then
      printf '%s\n' "BulkheadLM is still responding at $gateway_endpoint_url after the restart request." >&2
      return 1
    fi
  fi

  bulkhead_bin=$(agent_graph_bulkhead_binary "$bulkhead_dir" || true)
  if [ -z "$bulkhead_bin" ]; then
    printf '%s\n' "Unable to build or locate the BulkheadLM server binary in $bulkhead_dir." >&2
    return 1
  fi

  log_dir="$root_dir/var/log"
  mkdir -p "$log_dir"
  log_file="$log_dir/bulkhead-lm-gateway.log"

  printf '%s\n' "Starting external BulkheadLM gateway at $gateway_endpoint_url using $gateway_config" >&2
  if command -v nohup >/dev/null 2>&1; then
    (
      cd "$bulkhead_dir" &&
      nohup "$bulkhead_bin" --config "$gateway_config" >>"$log_file" 2>&1 &
    )
  else
    (
      cd "$bulkhead_dir" &&
      "$bulkhead_bin" --config "$gateway_config" >>"$log_file" 2>&1 &
    )
  fi

  attempt=0
  while [ "$attempt" -lt 40 ]; do
    if curl -fsS "$health_url" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.25
  done

  printf '%s\n' "BulkheadLM did not become healthy at $gateway_endpoint_url. Check $log_file." >&2
  return 1
}
