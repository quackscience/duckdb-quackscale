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
  quacktail_ci_ensure_demo_extensions "$DUCKDB" "$ext_dir" load_only
}

quacktail_sql_extension_directory() {
  quacktail_ext_sql_set "${DUCKDB_EXTENSION_DIRECTORY:-$(quacktail_ext_container_dir)}"
}

maybe_compose_bootstrap() {
  [[ "${QUACKTAIL_AUTO_BOOTSTRAP:-}" == "1" ]] || return 0
  [[ -f "${WORK}/server_setup.sql" && -f "${WORK}/client_session.sql" && -f "${WORK}/authkey" ]] \
    || /usr/local/bin/quacktail-compose-bootstrap.sh
  if [[ -f "${WORK}/client_session.sql" ]] \
    && ! grep -q 'tailscale_ping' "${WORK}/client_session.sql" 2>/dev/null; then
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

resolve_server_tailnet_ip() {
  headscale_cmd nodes list 2>/dev/null | grep -F "$SERVER_HOST" | grep -oE '100\.64\.[0-9]+\.[0-9]+' | head -1 || true
}

ensure_server_hosts_mapping() {
  # Default off: tailscale_up joins only; CALL tailscale_quack_proxy() before Quack client ops.
  [[ "${QUACKTAIL_MAP_SERVER_HOSTS:-0}" == "1" ]] || return 0
  local ip
  ip="$(resolve_server_tailnet_ip)"
  if [[ -z "$ip" ]]; then
    echo "warn: could not resolve ${SERVER_HOST} tailnet IP for /etc/hosts" >&2
    return 0
  fi
  if [[ "$QUIET" == "1" ]]; then
    echo "→ ${SERVER_HOST} → ${ip} (/etc/hosts — QUACKTAIL_MAP_SERVER_HOSTS=1)"
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
  if [[ -f "${WORK}/authkey" ]] && [[ -x /usr/local/bin/quacktail-compose-bootstrap.sh ]]; then
    COMPOSE_REFRESH_SERVER_QUACK=1 COMPOSE_REFRESH_SERVER_DUCKLAKE=1 QUACKTAIL_AUTO_BOOTSTRAP=1 \
      /usr/local/bin/quacktail-compose-bootstrap.sh
  fi
  ensure_quack
  rm -f "${WORK}/quack_ready"
  {
    cat "${WORK}/server_setup.sql"
    if [[ -f "${WORK}/server_ducklake.sql" ]]; then
      cat "${WORK}/server_ducklake.sql"
    fi
    cat "${WORK}/server_quack.sql"
  } >"$INIT_SQL"
  if [[ "$QUIET" == "1" ]]; then
    echo "→ quacktail-server: tailnet + ducklake + quack_serve(127.0.0.1:${PORT}) + tailscale_serve_local"
    echo "  (libtailscale logs → ${WORK}/server.log)"
  else
    echo "=== server init SQL ==="
    cat "$INIT_SQL"
  fi
  export DUCKDB DB WORK INIT_SQL DUCKDB_EXTENSION_DIRECTORY QUIET PORT QUACK_TAILNET_TOKEN
  exec /usr/local/bin/quacktail-server-run.sh
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
    COMPOSE_REFRESH_CLIENT_SQL=1 QUACKTAIL_MANAGE_CLIENT_SQL=1 QUACKTAIL_AUTO_BOOTSTRAP=1 \
      /usr/local/bin/quacktail-compose-bootstrap.sh
  fi
  if [[ ! -f "${WORK}/client_session.sql" ]]; then
    echo "error: ${WORK}/client_session.sql missing" >&2
    exit 1
  fi
  if grep -q '\\n' "${WORK}/client_session.sql" 2>/dev/null; then
    echo "error: ${WORK}/client_session.sql contains literal \\n (regenerate bootstrap)" >&2
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
  if [[ -f "${WORK}/client_session.sql" ]]; then
    grep -E "^ATTACH '" "${WORK}/client_session.sql" | head -1 | sed -E "s/^ATTACH '([^']+)'.*/\1/"
  fi
}

quacktail_dump_client_failure() {
  local out="${WORK}/client.out"
  if [[ -s "$out" ]]; then
    echo "--- client.out (tail) ---" >&2
    tail -30 "$out" >&2
  fi
}

quacktail_is_signal_rc() {
  case "${1:-0}" in
    130|143) return 0 ;;
  esac
  return 1
}

quacktail_client_on_signal() {
  echo "Interrupted — stopping client demo" >&2
  exit 130
}

quacktail_client_has_fatal_sql_error() {
  local out="${1:?client out file}"
  grep -qE 'Parser Error:|Catalog Error:|Binder Error:|Syntax Error:' "$out" 2>/dev/null
}

quacktail_client_session_succeeded() {
  local out="${1:?client out file}"
  grep -q "CLIENT_DEMO_DONE" "$out" 2>/dev/null || return 1
  grep -q "PASSED" "$out" 2>/dev/null || return 1
  if [[ "${QUACKTAIL_ENABLE_DUCKLAKE:-0}" == "1" ]]; then
    grep -q "LAKE_PASSED" "$out" 2>/dev/null || return 1
  fi
  return 0
}

quacktail_stop_process() {
  local pid="${1:?pid}"
  local wait_ms="${2:-1500}"
  local elapsed=0
  kill -0 "$pid" 2>/dev/null || return 0
  while (( elapsed < wait_ms )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

quacktail_show_client_demo_output() {
  local out="${1:-${WORK}/client.out}"
  [[ -s "$out" ]] || return 0
  quacktail_filter_demo_stream <"$out"
}

run_duckdb_client_session() {
  local session_sql="${1:?session sql file}"
  local out="${2:?out file}"
  local demo_timeout="${3:?timeout}"
  local ext_cmd duckdb_rc=0
  local timeout_cmd=(timeout --foreground --kill-after=3 "$demo_timeout")
  local duck_pid=0
  local deadline=0

  ext_cmd="$(quacktail_sql_extension_directory)"
  : >"$out"

  # Background duckdb → client.out; monitor client.out for CLIENT_DEMO_DONE then SIGTERM/KILL.
  # CLIENT_DEMO_DONE is emitted before tailscale_down (tsnet close can block).
  set +o pipefail
  if [[ "$QUIET" == "1" ]]; then
    "${timeout_cmd[@]}" stdbuf -oL -eL "$DUCKDB" -batch -echo \
      -cmd "$ext_cmd" -f "$session_sql" \
      >"$out" 2>&1 &
  else
    "${timeout_cmd[@]}" stdbuf -oL -eL "$DUCKDB" -batch -echo \
      -cmd "$ext_cmd" -f "$session_sql" \
      2>&1 | tee "$out" &
  fi
  duck_pid=$!
  deadline=$((SECONDS + demo_timeout + 5))

  while kill -0 "$duck_pid" 2>/dev/null; do
    if quacktail_client_session_succeeded "$out"; then
      quacktail_stop_process "$duck_pid" 500
      set -o pipefail
      return 0
    fi
    if quacktail_client_has_fatal_sql_error "$out"; then
      quacktail_stop_process "$duck_pid" 500
      set -o pipefail
      return 1
    fi
    if (( SECONDS >= deadline )); then
      quacktail_stop_process "$duck_pid" 500
      set -o pipefail
      echo "error: client demo timed out after ${demo_timeout}s" >&2
      quacktail_dump_client_failure
      return 124
    fi
    sleep 0.1
  done

  wait "$duck_pid" || duckdb_rc=$?
  set -o pipefail

  if [[ "$duckdb_rc" -eq 124 ]]; then
    echo "error: client demo timed out after ${demo_timeout}s" >&2
    quacktail_dump_client_failure
    return 124
  fi
  if quacktail_is_signal_rc "$duckdb_rc"; then
    return "$duckdb_rc"
  fi
  return "$duckdb_rc"
}

run_bootstrap() {
  if [[ ! -f "${WORK}/authkey" ]]; then
    echo "error: ${WORK}/authkey missing — start headscale + quacktail-server first" >&2
    exit 1
  fi
  if [[ "$QUIET" == "1" ]]; then
    echo "→ refreshing /work SQL on volume (no client demo) ..."
  fi
  COMPOSE_REFRESH_CLIENT_SQL=1 COMPOSE_REFRESH_SERVER_QUACK=1 \
    QUACKTAIL_MANAGE_CLIENT_SQL=1 QUACKTAIL_AUTO_BOOTSTRAP=1 /usr/local/bin/quacktail-compose-bootstrap.sh
  if [[ "$QUIET" == "1" ]]; then
    echo "✓ bootstrap complete — run: docker compose --profile test run --rm quacktail-client"
  else
    echo "ok: bootstrap complete"
  fi
}

client_demo_banner() {
  local session_sql="${1:?session sql}"
  local attach_uri="${2:?attach uri}"
  if [[ "${QUACKTAIL_ENABLE_DUCKLAKE:-0}" == "1" ]] \
    && grep -q 'attach_ducklake' "$session_sql" 2>/dev/null; then
    echo "→ join tailnet, forward, attach_ducklake, ATTACH ${attach_uri} ..."
  else
    echo "→ join tailnet, tailscale_ping ${SERVER_HOST}:${PORT}, quack_query, ATTACH ${attach_uri} ..."
  fi
}

quacktail_require_attach_ducklake() {
  [[ "${QUACKTAIL_REQUIRE_ATTACH_DUCKLAKE:-0}" == "1" ]] || return 0
  [[ "${QUACKTAIL_ENABLE_DUCKLAKE:-0}" == "1" ]] || return 0
  quacktail_has_quackscale_function attach_ducklake && return 0
  echo "error: attach_ducklake required but not in this image" >&2
  echo "Rebuild: cd examples && docker compose build --no-cache quacktail-client" >&2
  exit 1
}

run_client() {
  local session_sql="${WORK}/client_session.sql"
  local out="${WORK}/client.out"
  local demo_timeout="${QUACKTAIL_DEMO_TIMEOUT_SEC:-60}"
  local max_attempts="${QUACKTAIL_CLIENT_ATTEMPTS:-3}"
  local poll_sec="${QUACKTAIL_CLIENT_POLL_SEC:-2}"
  local attach_uri
  local duckdb_rc=0
  local attempt

  trap 'quacktail_client_on_signal INT' INT
  trap 'quacktail_client_on_signal TERM' TERM

  if [[ "$QUIET" == "1" ]]; then
    echo "→ preparing client (tailnet wait, extensions, session SQL) ..."
  fi

  wait_for_tailnet_server
  ensure_quack
  quacktail_require_attach_ducklake
  ensure_server_hosts_mapping
  ensure_client_sql
  attach_uri="$(client_attach_uri)"
  if [[ -z "$attach_uri" ]]; then
    echo "error: could not determine Quack ATTACH URI" >&2
    exit 1
  fi

  if [[ "$QUIET" == "1" ]]; then
    echo ""
    echo "QuackTail cluster demo"
    echo "======================"
    client_demo_banner "$session_sql" "$attach_uri"
    echo ""
  else
    echo "=== client session SQL (-f) ==="
    cat "$session_sql"
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    duckdb_rc=0
    run_duckdb_client_session "$session_sql" "$out" "$demo_timeout" \
      || duckdb_rc=$?
    if quacktail_is_signal_rc "$duckdb_rc"; then
      exit "$duckdb_rc"
    fi
    if quacktail_client_has_fatal_sql_error "$out"; then
      echo "error: non-retryable SQL failure in client session" >&2
      quacktail_dump_client_failure
      exit 1
    fi
    if quacktail_client_session_succeeded "$out"; then
      duckdb_rc=0
      break
    fi
    if (( attempt < max_attempts )); then
      [[ "$QUIET" == "1" ]] && echo "→ retry ${attempt}/${max_attempts} ..."
      quacktail_dump_client_failure
      sleep "$poll_sec" || exit 130
    fi
  done

  if ! quacktail_client_session_succeeded "$out"; then
    echo "error: client demo failed after ${max_attempts} attempt(s) (exit ${duckdb_rc})" >&2
    quacktail_dump_client_failure
    exit 1
  fi

  if [[ "$QUIET" == "1" ]]; then
    quacktail_show_client_demo_output "$out"
    echo ""
    if [[ "${QUACKTAIL_ENABLE_DUCKLAKE:-0}" == "1" ]]; then
      echo "✓ Demo passed — QuackTail cluster + DuckLake over tailnet"
    else
      echo "✓ Demo passed — two-node QuackTail cluster is working"
    fi
  else
    echo "ok: client e2e passed (CLIENT_DEMO_DONE)"
  fi
}

case "$ROLE" in
  server) run_server ;;
  client) run_client ;;
  bootstrap) run_bootstrap ;;
  *) echo "error: unknown QUACKTAIL_ROLE '$ROLE' (use server, client, or bootstrap)" >&2; exit 1 ;;
esac
