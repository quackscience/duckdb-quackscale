#!/usr/bin/env bash
# QuackTail CI container entrypoint — server (long-lived) or client (one-shot).
set -euo pipefail

DUCKDB="${DUCKDB_BIN:-/usr/local/bin/duckdb}"
ROLE="${QUACKTAIL_ROLE:-${1:-server}}"
PORT="${QUACK_PORT:-9494}"
WORK="${QUACKTAIL_WORK:-/work}"
DB="${WORK}/server.duckdb"
INIT_SQL="${WORK}/server_init.sql"
QUIET="${QUACKTAIL_QUIET:-0}"
SERVER_HOST="${SERVER_HOST:-quacktail-server}"
CLIENT_HOST="${CLIENT_HOST:-quacktail-client}"

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
  [[ -f "${WORK}/server_setup.sql" && -f "${WORK}/client_demo.sql" ]] && return 0
  /usr/local/bin/quacktail-compose-bootstrap.sh
}

wait_for_tailnet_server() {
  [[ -n "${QUACKTAIL_WAIT_SERVER:-}" ]] || return 0
  local node="$QUACKTAIL_WAIT_SERVER"
  local attempts="${QUACKTAIL_WAIT_ATTEMPTS:-90}"
  local -a hs_cmd=(headscale)
  if [[ -n "${HEADSCALE_CONFIG:-}" ]]; then
    hs_cmd+=(-c "$HEADSCALE_CONFIG")
  fi
  if ! command -v headscale >/dev/null 2>&1; then
    [[ "$QUIET" == "1" ]] || echo "warn: headscale CLI missing; skipping tailnet wait for ${node}" >&2
    return 0
  fi
  if [[ "$QUIET" == "1" ]]; then
    echo "→ waiting for ${node} on tailnet ..."
  else
    echo "Waiting for tailnet node ${node} ..."
  fi
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "${hs_cmd[@]}" nodes list 2>/dev/null | grep -Fq "$node"; then
      [[ "$QUIET" == "1" ]] && echo "✓ ${node} on tailnet"
      [[ "$QUIET" == "1" ]] || echo "Tailnet node ${node} is registered."
      return 0
    fi
    sleep 2
  done
  echo "error: ${node} not registered on tailnet after ${attempts} attempts" >&2
  "${hs_cmd[@]}" nodes list >&2 || true
  return 1
}

run_server() {
  maybe_compose_bootstrap
  ensure_quack
  cat "${WORK}/server_setup.sql" "${WORK}/server_quack.sql" >"$INIT_SQL"
  if [[ "$QUIET" == "1" ]]; then
    echo "→ quacktail-server: join tailnet + quack_serve on quack:${SERVER_HOST}:${PORT}"
    echo "  (libtailscale logs → ${WORK}/server.log)"
  else
    echo "=== server init SQL ==="
    cat "$INIT_SQL"
  fi
  export DUCKDB DB WORK INIT_SQL DUCKDB_EXTENSION_DIRECTORY QUIET
  if [[ "$QUIET" == "1" ]]; then
    exec bash -c 'sleep infinity | stdbuf -oL -eL "$DUCKDB" -cmd "SET extension_directory='"'"'${DUCKDB_EXTENSION_DIRECTORY}'"'"';" "$DB" -init "$INIT_SQL" 2>>"${WORK}/server.log"'
  else
    exec bash -c 'sleep infinity | stdbuf -oL -eL "$DUCKDB" -cmd "SET extension_directory='"'"'${DUCKDB_EXTENSION_DIRECTORY}'"'"';" "$DB" -init "$INIT_SQL"'
  fi
}

run_client_verbose() {
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

maybe_compose_bootstrap() {
  [[ "${QUACKTAIL_AUTO_BOOTSTRAP:-}" == "1" ]] || return 0
  [[ -f "${WORK}/server_setup.sql" && -f "${WORK}/client_run.sql" ]] && return 0
  /usr/local/bin/quacktail-compose-bootstrap.sh
}

# Print the last DuckDB ASCII result table from captured output.
print_last_duckdb_table() {
  local out="${1:?output file}"
  awk '
    /^┌/ { table = $0 ORS; in_table = 1; next }
    in_table {
      table = table $0 ORS
      if (/^└/) {
        last = table
        in_table = 0
        table = ""
      }
    }
    END {
      if (last != "") {
        printf "%s", last
      }
    }
  ' "$out"
}

run_client_demo() {
  local client_db="${WORK}/client.duckdb"
  local attach_uri="quack:${SERVER_HOST}:${PORT}"
  local run_sql="${WORK}/client_run.sql"
  local out="${WORK}/client.out"
  local log="${WORK}/client.log"

  if [[ ! -f "$run_sql" ]]; then
    if [[ -f "${WORK}/client_init.sql" && -f "${WORK}/client_demo.sql" ]]; then
      cat "${WORK}/client_init.sql" "${WORK}/client_demo.sql" >"$run_sql"
    else
      echo "error: ${run_sql} missing (docker compose down -v && up to re-bootstrap)" >&2
      exit 1
    fi
  fi

  echo ""
  echo "QuackTail cluster demo"
  echo "======================"

  ensure_quack

  echo "→ join tailnet, ATTACH ${attach_uri}, verify cross-node queries ..."
  echo ""

  if ! "$DUCKDB" -bail -batch -cmd "$(quacktail_sql_extension_directory)" "$client_db" \
    -f "$run_sql" >"$out" 2>"$log"; then
    echo "error: client demo failed" >&2
    if [[ -s "$log" ]]; then
      echo "--- log ---" >&2
      tail -40 "$log" >&2
    fi
    if [[ -s "$out" ]]; then
      echo "--- output ---" >&2
      tail -40 "$out" >&2
    fi
    exit 1
  fi

  if grep -q "PASSED" "$out" 2>/dev/null; then
    print_last_duckdb_table "$out"
  else
    echo "warn: expected PASSED row missing; raw tail of output:" >&2
    tail -20 "$out"
  fi
  echo ""
  echo "✓ Demo passed — two-node QuackTail cluster is working"
}

run_client() {
  wait_for_tailnet_server
  if [[ "$QUIET" == "1" ]]; then
    run_client_demo
  else
    run_client_verbose
  fi
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  *) echo "error: unknown QUACKTAIL_ROLE '$ROLE'" >&2; exit 1 ;;
esac
