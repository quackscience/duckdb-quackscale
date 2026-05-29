#!/usr/bin/env bash
# QuackTail CI container entrypoint.
# Server lifecycle matches duckdb-quack-infra boot.sh:
#   sleep infinity | duckdb -init /path/to/init.sql
# https://github.com/duckdb/duckdb-quack-infra/blob/main/boot.sh
#
# Client: one long-lived DuckDB (-init tailscale_up), poll cross-node Quack POST until
# the server is reachable, then ATTACH/queries on the same stdin stream (-bail on error).
set -euo pipefail

DUCKDB="${DUCKDB_BIN:-/usr/local/bin/duckdb}"
ROLE="${QUACKTAIL_ROLE:-${1:-server}}"
PORT="${QUACK_PORT:-9494}"
WORK="${QUACKTAIL_WORK:-/work}"
DB="${WORK}/server.duckdb"
INIT_SQL="${WORK}/server_init.sql"

# shellcheck source=/dev/null
source /usr/local/lib/quacktail_ext.sh

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found or not executable at $DUCKDB" >&2
  exit 1
fi

ensure_quack() {
  local ext_dir="${DUCKDB_EXTENSION_DIRECTORY:-$(quacktail_ext_container_dir)}"
  export DUCKDB_EXTENSION_DIRECTORY="$ext_dir"
  echo "=== extension_directory=${ext_dir} (load from host cache) ==="
  quacktail_ci_ensure_quack "$DUCKDB" "$ext_dir" load_only
}

quacktail_sql_extension_directory() {
  local ext_dir="${DUCKDB_EXTENSION_DIRECTORY:-$(quacktail_ext_container_dir)}"
  quacktail_ext_sql_set "$ext_dir"
}

wait_for_cross_node_quack() {
  local host="${1:?host}"
  local port="${2:?port}"
  local attempts="${3:-${E2E_CROSS_NODE_GATE_ATTEMPTS:-60}}"
  local token="${QUACK_TAILNET_TOKEN:-${QUACK_TOKEN:-}}"
  quacktail_wait_quack_endpoint "$host" "$port" "$token" "cross-node Quack" "$attempts" "${E2E_CROSS_NODE_POLL_SEC:-2}"
}

run_server() {
  ensure_quack
  if [[ ! -f "${WORK}/server_setup.sql" || ! -f "${WORK}/server_quack.sql" ]]; then
    echo "error: missing ${WORK}/server_setup.sql or server_quack.sql" >&2
    exit 1
  fi
  cat "${WORK}/server_setup.sql" "${WORK}/server_quack.sql" >"$INIT_SQL"
  echo "=== server init SQL (duckdb -init) ==="
  cat "$INIT_SQL"
  echo "=== starting Quack server: sleep infinity | duckdb -init ==="
  export DUCKDB DB WORK INIT_SQL DUCKDB_EXTENSION_DIRECTORY
  exec bash -c 'sleep infinity | "$DUCKDB" -cmd "SET extension_directory='"'"'${DUCKDB_EXTENSION_DIRECTORY}'"'"';" "$DB" -init "$INIT_SQL"'
}

run_client() {
  ensure_quack
  local client_db="${WORK}/client.duckdb"
  local server_ip="${E2E_SERVER_IP:?E2E_SERVER_IP required for client}"
  local gate_host="${E2E_CROSS_NODE_GATE_HOST:-$server_ip}"
  local mesh_wait="${E2E_CLIENT_MESH_WAIT_SEC:-0}"
  local gate_attempts="${E2E_CROSS_NODE_GATE_ATTEMPTS:-60}"

  if [[ ! -f "${WORK}/client_init.sql" || ! -f "${WORK}/client_attach.sql" ]]; then
    echo "error: missing ${WORK}/client_init.sql or client_attach.sql" >&2
    exit 1
  fi

  echo "=== client init SQL (-init; DuckDB stays running for ATTACH) ==="
  cat "${WORK}/client_init.sql"
  echo "=== client attach SQL (after cross-node Quack POST gate) ==="
  echo "Cross-node gate target: http://${gate_host}:${PORT}/quack (attempts=${gate_attempts})" >&2
  cat "${WORK}/client_attach.sql"
  if [[ -f "${WORK}/client_queries.sql" ]]; then
    echo "=== client queries SQL (after successful ATTACH; -bail stops on attach failure) ==="
    cat "${WORK}/client_queries.sql"
  fi

  {
    if (( mesh_wait > 0 )); then
      sleep "$mesh_wait"
    fi
    wait_for_cross_node_quack "$gate_host" "$PORT" "$gate_attempts"
    cat "${WORK}/client_attach.sql"
    if [[ -f "${WORK}/client_queries.sql" ]]; then
      cat "${WORK}/client_queries.sql"
    fi
  } | "$DUCKDB" -bail -cmd "$(quacktail_sql_extension_directory)" "$client_db" \
    -init "${WORK}/client_init.sql" -batch -echo
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  *)
    echo "error: unknown QUACKTAIL_ROLE '$ROLE' (expected server or client)" >&2
    exit 1
    ;;
esac
