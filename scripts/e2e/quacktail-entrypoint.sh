#!/usr/bin/env bash
# QuackTail CI container entrypoint.
# Server lifecycle matches duckdb-quack-infra boot.sh:
#   sleep infinity | duckdb -init /path/to/init.sql
# https://github.com/duckdb/duckdb-quack-infra/blob/main/boot.sh
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
  local mesh_wait="${E2E_CLIENT_MESH_WAIT_SEC:-15}"
  if [[ ! -f "${WORK}/client_join.sql" || ! -f "${WORK}/client.sql" ]]; then
    echo "error: missing ${WORK}/client_join.sql or client.sql" >&2
    exit 1
  fi
  echo "=== client join SQL ==="
  cat "${WORK}/client_join.sql"
  echo "=== joining tailnet (phase 1) ==="
  "$DUCKDB" :memory: -batch -echo -f "${WORK}/client_join.sql"
  echo "Waiting ${mesh_wait}s for client tailnet data plane ..."
  sleep "$mesh_wait"
  echo "=== client SQL (phase 2) ==="
  cat "${WORK}/client.sql"
  exec "$DUCKDB" :memory: -batch -echo -f "${WORK}/client.sql"
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  *)
    echo "error: unknown QUACKTAIL_ROLE '$ROLE' (expected server or client)" >&2
    exit 1
    ;;
esac
