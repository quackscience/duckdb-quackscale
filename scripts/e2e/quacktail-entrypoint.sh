#!/usr/bin/env bash
# QuackTail CI container entrypoint.
# Server lifecycle matches duckdb-quack-infra boot.sh:
#   sleep infinity | duckdb -init /path/to/init.sql
# https://github.com/duckdb/duckdb-quack-infra/blob/main/boot.sh
#
# Client: one long-lived DuckDB (-init tailscale_up), then bash mesh wait + cross-node
# curl gate, then ATTACH/queries on the same stdin stream (tsnet stays up throughout).
set -euo pipefail

DUCKDB="${DUCKDB_BIN:-/usr/local/bin/duckdb}"
ROLE="${QUACKTAIL_ROLE:-${1:-server}}"
PORT="${QUACK_PORT:-9494}"
WORK="${QUACKTAIL_WORK:-/work}"
DB="${WORK}/server.duckdb"
INIT_SQL="${WORK}/server_init.sql"

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found or not executable at $DUCKDB" >&2
  exit 1
fi

ensure_quack() {
  echo "=== ensure quack extension ==="
  if "$DUCKDB" :memory: -batch -c "LOAD quack; SELECT 1;" 2>/dev/null; then
    return 0
  fi
  echo "Installing quack (core_nightly, then core) ..."
  "$DUCKDB" :memory: -batch -c "FORCE INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;" \
    || "$DUCKDB" :memory: -batch -c "INSTALL quack FROM core; LOAD quack; SELECT 1;"
}

quacktail_curl_tailnet_http() {
  local host="${1:?host}"
  local port="${2:?port}"
  curl -fsS -m 3 -o /dev/null "http://${host}:${port}/quack" 2>/dev/null && return 0
  curl -fsS -m 3 -o /dev/null "http://${host}:${port}/" 2>/dev/null && return 0
  local code
  code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://${host}:${port}/" 2>/dev/null || echo 000)"
  [[ "$code" != "000" ]]
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
  export DUCKDB DB WORK INIT_SQL
  exec bash -c 'sleep infinity | "$DUCKDB" "$DB" -init "$INIT_SQL"'
}

run_client() {
  ensure_quack
  local client_db="${WORK}/client.duckdb"
  local server_ip="${E2E_SERVER_IP:?E2E_SERVER_IP required for client}"
  local gate_host="${E2E_SERVER_HOST:-$server_ip}"
  local mesh_wait="${E2E_CLIENT_MESH_WAIT_SEC:-3}"

  if [[ ! -f "${WORK}/client_init.sql" || ! -f "${WORK}/client_attach.sql" ]]; then
    echo "error: missing ${WORK}/client_init.sql or client_attach.sql" >&2
    exit 1
  fi

  echo "=== client init SQL (-init; DuckDB stays running for ATTACH) ==="
  cat "${WORK}/client_init.sql"
  echo "=== client attach SQL (after mesh wait + cross-node curl gate) ==="
  cat "${WORK}/client_attach.sql"

  {
    sleep "$mesh_wait"
    echo "=== tailnet TCP gate: curl http://${gate_host}:${PORT}/ (cross-node) ===" >&2
    if ! quacktail_curl_tailnet_http "$gate_host" "$PORT"; then
      echo "error: cross-node tailnet TCP gate failed (${gate_host}:${PORT})" >&2
      exit 1
    fi
    echo "ok: cross-node tailnet TCP gate passed (${gate_host}:${PORT})" >&2
    cat "${WORK}/client_attach.sql"
  } | "$DUCKDB" "$client_db" -init "${WORK}/client_init.sql" -batch -echo
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  *)
    echo "error: unknown QUACKTAIL_ROLE '$ROLE' (expected server or client)" >&2
    exit 1
    ;;
esac
