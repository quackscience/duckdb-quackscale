#!/usr/bin/env bash
# QuackTail CI container entrypoint — server (long-lived) or client (one-shot).
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
  quacktail_ci_ensure_quack "$DUCKDB" "$ext_dir" load_only
}

quacktail_sql_extension_directory() {
  quacktail_ext_sql_set "${DUCKDB_EXTENSION_DIRECTORY:-$(quacktail_ext_container_dir)}"
}

maybe_compose_bootstrap() {
  [[ "${QUACKTAIL_AUTO_BOOTSTRAP:-}" == "1" ]] || return 0
  [[ -f "${WORK}/server_setup.sql" ]] && return 0
  /usr/local/bin/quacktail-compose-bootstrap.sh
}

wait_for_tailnet_server() {
  [[ -n "${QUACKTAIL_WAIT_SERVER:-}" ]] || return 0
  local node="$QUACKTAIL_WAIT_SERVER"
  local attempts="${QUACKTAIL_WAIT_ATTEMPTS:-90}"
  if ! command -v headscale >/dev/null 2>&1; then
    echo "warn: headscale CLI missing; skipping tailnet wait for ${node}" >&2
    return 0
  fi
  echo "Waiting for tailnet node ${node} ..."
  local i
  for ((i = 1; i <= attempts; i++)); do
    if headscale nodes list 2>/dev/null | grep -Fq "$node"; then
      echo "Tailnet node ${node} is registered."
      return 0
    fi
    sleep 2
  done
  echo "error: ${node} not registered on tailnet after ${attempts} attempts" >&2
  headscale nodes list >&2 || true
  return 1
}

run_server() {
  maybe_compose_bootstrap
  ensure_quack
  cat "${WORK}/server_setup.sql" "${WORK}/server_quack.sql" >"$INIT_SQL"
  echo "=== server init SQL ==="
  cat "$INIT_SQL"
  export DUCKDB DB WORK INIT_SQL DUCKDB_EXTENSION_DIRECTORY
  exec bash -c 'sleep infinity | stdbuf -oL -eL "$DUCKDB" -cmd "SET extension_directory='"'"'${DUCKDB_EXTENSION_DIRECTORY}'"'"';" "$DB" -init "$INIT_SQL"'
}

run_client() {
  wait_for_tailnet_server
  ensure_quack
  local client_db="${WORK}/client.duckdb"

  echo "=== client init SQL ==="
  cat "${WORK}/client_init.sql"
  echo "=== client attach SQL (quack_query probe + ATTACH) ==="
  cat "${WORK}/client_attach.sql"
  [[ -f "${WORK}/client_queries.sql" ]] && cat "${WORK}/client_queries.sql"

  {
    cat "${WORK}/client_attach.sql"
    [[ -f "${WORK}/client_queries.sql" ]] && cat "${WORK}/client_queries.sql"
  } | "$DUCKDB" -bail -cmd "$(quacktail_sql_extension_directory)" "$client_db" \
    -init "${WORK}/client_init.sql" -batch -echo
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  *) echo "error: unknown QUACKTAIL_ROLE '$ROLE'" >&2; exit 1 ;;
esac
