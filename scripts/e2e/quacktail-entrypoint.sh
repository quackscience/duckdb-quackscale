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
  [[ -f "${WORK}/server_setup.sql" && -f "${WORK}/client_quack.sql" && -f "${WORK}/client_init.sql" ]] \
    || /usr/local/bin/quacktail-compose-bootstrap.sh
  if [[ -f "${WORK}/client_quack.sql" ]] \
    && grep -q 'NOT EXISTS' "${WORK}/client_quack.sql" 2>/dev/null; then
    /usr/local/bin/quacktail-compose-bootstrap.sh
  fi
}

headscale_cmd() {
  local -a hs=(headscale)
  if [[ -n "${HEADSCALE_CONFIG:-}" ]]; then
    hs+=(-c "$HEADSCALE_CONFIG")
  fi
  "${hs[@]}" "$@"
}

wait_for_tailnet_server() {
  [[ -n "${QUACKTAIL_WAIT_SERVER:-}" ]] || return 0
  local node="$QUACKTAIL_WAIT_SERVER"
  local attempts="${QUACKTAIL_WAIT_ATTEMPTS:-15}"
  local poll_sec="${QUACKTAIL_WAIT_POLL_SEC:-1}"
  if ! command -v headscale >/dev/null 2>&1; then
    [[ "$QUIET" == "1" ]] || echo "warn: headscale CLI missing; skipping tailnet wait for ${node}" >&2
    return 0
  fi
  if [[ "$QUIET" == "1" ]]; then
    echo "→ waiting for ${node} on tailnet ..."
  else
    echo "Waiting for tailnet node ${node} (up to ${attempts}s) ..."
  fi
  local i
  for ((i = 1; i <= attempts; i++)); do
    if headscale_cmd nodes list 2>/dev/null | grep -Fq "$node"; then
      [[ "$QUIET" == "1" ]] && echo "✓ ${node} on tailnet"
      [[ "$QUIET" == "1" ]] || echo "Tailnet node ${node} is registered."
      return 0
    fi
    sleep "$poll_sec"
  done
  echo "error: ${node} not registered on tailnet after ${attempts}s" >&2
  headscale_cmd nodes list >&2 || true
  return 1
}

# Cross-node Quack readiness (caller must already be on the tailnet).
resolve_server_tailnet_ip() {
  headscale_cmd nodes list 2>/dev/null | grep -F "$SERVER_HOST" | grep -oE '100\.64\.[0-9]+\.[0-9]+' | head -1 || true
}

ensure_server_hosts_mapping() {
  local ip
  ip="$(resolve_server_tailnet_ip)"
  if [[ -z "$ip" ]]; then
    echo "warn: could not resolve ${SERVER_HOST} tailnet IP for /etc/hosts" >&2
    return 0
  fi
  if [[ "$QUIET" == "1" ]]; then
    echo "→ ${SERVER_HOST} → ${ip} (/etc/hosts, matches server quack_uri())"
  else
    echo "Mapping ${SERVER_HOST} -> ${ip} in /etc/hosts"
  fi
  if grep -qE "[[:space:]]${SERVER_HOST}$" /etc/hosts 2>/dev/null; then
    grep -vE "[[:space:]]${SERVER_HOST}$" /etc/hosts > /etc/hosts.quacktail || true
    cat /etc/hosts.quacktail > /etc/hosts
    rm -f /etc/hosts.quacktail
  fi
  echo "${ip} ${SERVER_HOST}" >> /etc/hosts
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

quacktail_filter_demo_stream() {
  if [[ "${QUACKTAIL_QUIET:-0}" != "1" ]]; then
    cat
    return
  fi
  grep -v -E '^-- Loading resources from |^20[0-9]{2}/[0-9]{2}/[0-9]{2} '
}

ensure_client_sql() {
  if [[ -f "${WORK}/authkey" ]] && [[ -x /usr/local/bin/quacktail-compose-bootstrap.sh ]]; then
    COMPOSE_REFRESH_CLIENT_SQL=1 QUACKTAIL_AUTO_BOOTSTRAP=1 /usr/local/bin/quacktail-compose-bootstrap.sh
  fi
  if [[ ! -f "${WORK}/client_init.sql" ]]; then
    echo "error: ${WORK}/client_init.sql missing" >&2
    exit 1
  fi
  if [[ ! -f "${WORK}/client_quack.sql" ]] && [[ ! -f "${WORK}/client_attach.sql" ]]; then
    echo "error: need ${WORK}/client_quack.sql or ${WORK}/client_attach.sql" >&2
    exit 1
  fi
}

client_attach_uri() {
  if [[ -n "${QUACKTAIL_ATTACH_URI:-}" ]]; then
    echo "$QUACKTAIL_ATTACH_URI"
    return
  fi
  if [[ -f "${WORK}/attach_uri" ]]; then
    cat "${WORK}/attach_uri"
    return
  fi
  if [[ -f "${WORK}/client_quack.sql" ]]; then
    grep -E "^ATTACH '" "${WORK}/client_quack.sql" | head -1 | sed -E "s/^ATTACH '([^']+)'.*/\1/"
  fi
}

write_client_session_sql() {
  local dest="${1:?dest path}"
  {
    cat "${WORK}/client_init.sql"
    if [[ -f "${WORK}/client_quack.sql" ]]; then
      cat "${WORK}/client_quack.sql"
    else
      cat "${WORK}/client_attach.sql"
      [[ -f "${WORK}/client_queries.sql" ]] && cat "${WORK}/client_queries.sql"
    fi
  } >"$dest"
}

quacktail_dump_client_failure() {
  local out="${WORK}/client.out"
  local tsnet_log="${WORK}/client-tsnet.log"
  if [[ -s "$out" ]]; then
    echo "--- client.out (tail) ---" >&2
    tail -30 "$out" >&2
  fi
  if [[ -s "$tsnet_log" ]]; then
    echo "--- client-tsnet.log (tail) ---" >&2
    tail -30 "$tsnet_log" >&2
  fi
}

run_duckdb_client_session() {
  local client_db="${1:?db}"
  local session_sql="${2:?session sql}"
  local out="${3:?out file}"
  local demo_timeout="${4:?timeout}"
  shift 4
  local -a duckdb_extra=("$@")
  local tsnet_log="${WORK}/client-tsnet.log"
  local ext_cmd duckdb_rc=0

  ext_cmd="$(quacktail_sql_extension_directory)"
  : >"$tsnet_log"

  # One DuckDB session: tailscale_up then quack ATTACH/DML via -init (no stdin pipe).
  set +o pipefail
  if [[ "$QUIET" == "1" ]]; then
    timeout "$demo_timeout" stdbuf -oL -eL "$DUCKDB" -bail -batch \
      -cmd "$ext_cmd" "${duckdb_extra[@]}" "$client_db" -init "$session_sql" \
      2>>"$tsnet_log" | quacktail_filter_demo_stream | tee "$out"
  else
    timeout "$demo_timeout" stdbuf -oL -eL "$DUCKDB" -bail -batch \
      -cmd "$ext_cmd" "${duckdb_extra[@]}" "$client_db" -init "$session_sql" \
      2>&1 | quacktail_filter_demo_stream | tee "$out"
  fi
  duckdb_rc=${PIPESTATUS[0]}
  set -o pipefail

  if [[ "$duckdb_rc" -eq 124 ]]; then
    echo "error: client demo timed out after ${demo_timeout}s (tailscale join + ATTACH should finish in seconds)" >&2
    quacktail_dump_client_failure
    return 124
  fi
  return "$duckdb_rc"
}

run_client() {
  local client_db="${WORK}/client.duckdb"
  local attach_uri
  local session_sql="${WORK}/client_session.sql"
  local out="${WORK}/client.out"
  local demo_timeout="${QUACKTAIL_DEMO_TIMEOUT_SEC:-30}"
  local duckdb_rc=0
  local -a duckdb_extra=()

  wait_for_tailnet_server
  ensure_quack
  ensure_server_hosts_mapping
  ensure_client_sql
  attach_uri="$(client_attach_uri)"
  if [[ -z "$attach_uri" ]]; then
    echo "error: could not determine Quack ATTACH URI" >&2
    exit 1
  fi

  write_client_session_sql "$session_sql"

  if [[ "$QUIET" == "1" ]]; then
    echo ""
    echo "QuackTail cluster demo"
    echo "======================"
    echo "→ join tailnet as ${CLIENT_HOST}, ATTACH ${attach_uri}, verify read/write ..."
    echo ""
  else
    echo "=== client session SQL (-init) ==="
    cat "$session_sql"
    duckdb_extra=(-echo)
  fi

  duckdb_rc=0
  run_duckdb_client_session "$client_db" "$session_sql" "$out" "$demo_timeout" \
    "${duckdb_extra[@]}" || duckdb_rc=$?

  if [[ "$duckdb_rc" -ne 0 ]]; then
    echo "error: client demo failed (exit ${duckdb_rc})" >&2
    quacktail_dump_client_failure
    exit 1
  fi

  if ! grep -q "PASSED" "$out" 2>/dev/null; then
    echo "error: expected PASSED row missing" >&2
    exit 1
  fi

  if [[ "$QUIET" == "1" ]]; then
    echo "✓ Demo passed — two-node QuackTail cluster is working"
  else
    echo "ok: client e2e passed (PASSED row present)"
  fi
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  *) echo "error: unknown QUACKTAIL_ROLE '$ROLE'" >&2; exit 1 ;;
esac
