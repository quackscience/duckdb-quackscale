#!/usr/bin/env bash
# Two-node QuackTail e2e over Headscale.
# QuackTail (quackscale) is built into the release DuckDB — never LOAD quackscale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
HEADSCALE_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/headscale_ci.sh
source "$ROOT/scripts/lib/headscale_ci.sh"

QUACK_TOKEN="${QUACK_TAILNET_TOKEN:-quackscale-e2e-shared-token}"
SERVER_HOST="${E2E_SERVER_HOST:-quacktail-server}"
CLIENT_HOST="${E2E_CLIENT_HOST:-quacktail-client}"
QUACK_PORT="${E2E_QUACK_PORT:-9494}"
CLIENT_TIMEOUT="${E2E_CLIENT_TIMEOUT_SEC:-120}"

WORK="${E2E_WORK:-${GITHUB_WORKSPACE:-$ROOT}/.e2e-work}"
mkdir -p "$WORK"
HS_DATA="$WORK/headscale-data"
SERVER_STATE="$WORK/server-tailscale"
CLIENT_STATE="$WORK/client-tailscale"
SERVER_DB="$WORK/server.duckdb"
SERVER_LOG="$WORK/server.log"
CLIENT_LOG="$WORK/client.log"

e2e_run_duckdb() {
  local label="$1"
  local db="$2"
  local sql_file="$3"
  local log_file="$4"

  echo "=== $label ==="
  echo "--- SQL: $(basename "$sql_file") ---"
  cat "$sql_file"
  echo "--- DuckDB output ---"
  "$DUCKDB" "$db" -batch -echo -f "$sql_file" 2>&1 | tee -a "$log_file"
  local rc=${PIPESTATUS[0]}
  if (( rc != 0 )); then
    echo "error: $label failed (duckdb exit $rc)" >&2
    headscale_ci_logs
    exit 1
  fi
}

e2e_wait_for_quack_server() {
  local wait_host="${E2E_QUACK_ATTACH_HOST:-localhost}"
  if [[ "$wait_host" == "tailnet" ]]; then
    wait_host="${SERVER_IP:?SERVER_IP required for tailnet wait}"
  fi
  local attempt=0
  echo "Waiting for Quack HTTP on ${wait_host}:${QUACK_PORT} (quack_serve blocks the server DuckDB process) ..."
  while (( attempt < 60 )); do
    attempt=$((attempt + 1))
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "error: server DuckDB exited early (quack_serve should block until killed)" >&2
      tail -80 "$SERVER_LOG" >&2 || true
      headscale_ci_logs
      exit 1
    fi
    if grep -q "Failed to bind DuckDB Quack RPC server" "$SERVER_LOG" 2>/dev/null; then
      echo "error: quack_serve failed to bind" >&2
      tail -80 "$SERVER_LOG" >&2 || true
      headscale_ci_logs
      exit 1
    fi
    if headscale_ci_tcp_reachable "$wait_host" "$QUACK_PORT"; then
      echo "Quack is accepting TCP on ${wait_host}:${QUACK_PORT}"
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      echo "  attempt ${attempt} (server pid ${SERVER_PID}) ..."
      tail -5 "$SERVER_LOG" 2>/dev/null || true
    fi
    sleep 2
  done
  echo "error: Quack not reachable on ${wait_host}:${QUACK_PORT}" >&2
  tail -80 "$SERVER_LOG" >&2 || true
  headscale_ci_logs
  exit 1
}

e2e_dump_logs() {
  if [[ -z "${WORK:-}" ]]; then
    return 0
  fi
  echo "::group::E2e server log"
  if [[ -f "${SERVER_LOG:-}" ]]; then
    cat "$SERVER_LOG"
  else
    echo "(no server log)"
  fi
  echo "::endgroup::"
  echo "::group::E2e client log"
  if [[ -f "${CLIENT_LOG:-}" ]]; then
    cat "$CLIENT_LOG"
  else
    echo "(no client log)"
  fi
  echo "::endgroup::"
  if [[ -d "$WORK" ]]; then
    echo "::group::E2e work directory ($WORK)"
    ls -la "$WORK" || true
    for sql in "$WORK"/*.sql; do
      [[ -f "$sql" ]] || continue
      echo "--- $(basename "$sql") ---"
      cat "$sql"
    done
    echo "::endgroup::"
  fi
}

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [[ "${HEADSCALE_ALREADY_RUNNING:-}" != "1" ]]; then
    headscale_ci_stop
  fi
}
trap 'e2e_dump_logs; cleanup' EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at '$DUCKDB'" >&2
  exit 1
fi

echo "Using DuckDB: $DUCKDB"
echo "E2e work directory: $WORK"
: >"$SERVER_LOG"
: >"$CLIENT_LOG"

echo "=== ensure quack extension ==="
if ! "$DUCKDB" -c "LOAD quack; SELECT 1;" 2>&1 | tee -a "$SERVER_LOG"; then
  echo "Installing quack from DuckDB core ..."
  "$DUCKDB" -c "INSTALL quack FROM core; LOAD quack; SELECT 1;" 2>&1 | tee -a "$SERVER_LOG" \
    || "$DUCKDB" -c "INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;" 2>&1 | tee -a "$SERVER_LOG"
fi

mkdir -p "$HS_DATA" "$SERVER_STATE" "$CLIENT_STATE"
if [[ "${HEADSCALE_ALREADY_RUNNING:-}" == "1" ]]; then
  headscale_ci_wait_ready
else
  headscale_ci_start "$HS_DATA"
fi

if [[ -n "${HEADSCALE_AUTHKEY_FILE:-}" && -f "$HEADSCALE_AUTHKEY_FILE" ]]; then
  AUTHKEY="$(cat "$HEADSCALE_AUTHKEY_FILE")"
  echo "Using Headscale authkey from $HEADSCALE_AUTHKEY_FILE (len ${#AUTHKEY})"
elif [[ -n "${HEADSCALE_AUTHKEY:-}" ]]; then
  AUTHKEY="$HEADSCALE_AUTHKEY"
  echo "Using Headscale authkey from env (len ${#AUTHKEY})"
else
  AUTHKEY="$(headscale_ci_create_authkey)"
  echo "Headscale authkey prefix: ${AUTHKEY:0:12}... (len ${#AUTHKEY})"
  if [[ "${SKIP_HEADSCALE_VERIFY:-}" != "1" ]]; then
    headscale_ci_verify_tailscale_client "$AUTHKEY" "headscale-e2e-verify"
  fi
fi
export QUACK_TAILNET_TOKEN="$QUACK_TOKEN"

# One long-lived server process: tailscale_up → seed data → quack_serve (blocking on 0.0.0.0).
{
  headscale_ci_sql_tailscale_up "$SERVER_HOST" "$SERVER_STATE" "$AUTHKEY"
  cat <<SQL

CREATE TABLE e2e_payload (id INTEGER PRIMARY KEY, msg VARCHAR, source VARCHAR);
INSERT INTO e2e_payload VALUES (1, 'seed-from-server', 'server');

LOAD quack;

SQL
  headscale_ci_sql_quack_serve "$QUACK_PORT"
} >"$WORK/server_serve.sql"

echo "Resolving server tailnet IP (for logs; same-host CI ATTACH uses localhost) ..."
SERVER_IP=""
if SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST")"; then
  echo "Server tailnet IP (from Headscale): $SERVER_IP"
else
  echo "error: could not determine server tailnet IP" >&2
  headscale_ci_logs
  exit 1
fi
SERVER_DNS="$(headscale_ci_tailnet_fqdn "$SERVER_HOST")"
SERVER_QUACK_URI_DNS="$(headscale_ci_quack_client_uri "$SERVER_HOST" "$QUACK_PORT")"
SERVER_QUACK_URI="$(headscale_ci_e2e_quack_attach_uri "$SERVER_IP" "$QUACK_PORT")"
echo "Server MagicDNS name (Headscale): ${SERVER_DNS}"
echo "Client Quack ATTACH URI: ${SERVER_QUACK_URI}"
echo "  (same-runner CI: localhost + quack on 0.0.0.0; E2E_QUACK_ATTACH_HOST=tailnet when tailscale_listen exists)"
echo "Tailnet ATTACH (needs tailscale_listen bridge): $(headscale_ci_quack_uri_for_ip "$SERVER_IP" "$QUACK_PORT")"

echo "=== Starting Quack listener on server ==="
echo "--- SQL: server_serve.sql ---"
cat "$WORK/server_serve.sql"
echo "--- DuckDB server output (streamed; quack_serve blocks) ---"
python3 "$ROOT/scripts/lib/run_e2e_server.py" "$DUCKDB" "$SERVER_DB" "$WORK/server_serve.sql" "$SERVER_LOG" &
SERVER_PID=$!

sleep 2
e2e_wait_for_quack_server
echo "Client will ATTACH: ${SERVER_QUACK_URI}"

{
  cat <<SQL
LOAD quack;

SQL
  headscale_ci_sql_tailscale_up "$CLIENT_HOST" "$CLIENT_STATE" "$AUTHKEY"
  cat <<SQL

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE '${SERVER_QUACK_URI}'
);

-- Local quack_discover() lists this node's tailnet endpoints (proves tailscale_up on client).
CREATE TEMP TABLE _discover AS SELECT * FROM quack_discover();
SELECT 'discover_count|' || COUNT(*)::VARCHAR;

ATTACH '${SERVER_QUACK_URI}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client');

SELECT 'row_count|' || COUNT(*)::VARCHAR FROM remote.e2e_payload;
SELECT 'client_msg|' || msg FROM remote.e2e_payload WHERE source = 'client';
SELECT 'server_msg|' || msg FROM remote.e2e_payload WHERE source = 'server';
SQL
} >"$WORK/client.sql"

echo "=== Running QuackTail client ($CLIENT_HOST) ==="
echo "--- SQL: client.sql ---"
cat "$WORK/client.sql"
echo "--- DuckDB output ---"
: >"$CLIENT_LOG"
set +e
timeout "$CLIENT_TIMEOUT" "$DUCKDB" :memory: -batch -echo -f "$WORK/client.sql" 2>&1 | tee -a "$CLIENT_LOG"
CLIENT_RC=${PIPESTATUS[0]}
set -e
if (( CLIENT_RC == 124 )); then
  echo "error: client DuckDB timed out after ${CLIENT_TIMEOUT}s (likely ATTACH cannot reach quack_serve)" >&2
  CLIENT_RC=124
fi
CLIENT_OUT="$(cat "$CLIENT_LOG")"
if (( CLIENT_RC != 0 )); then
  echo "error: client DuckDB failed (exit $CLIENT_RC)" >&2
  tail -100 "$CLIENT_LOG" >&2 || true
  headscale_ci_logs
  exit 1
fi

echo "=== Result rows ==="
echo "$CLIENT_OUT" | grep -E 'discover_count|row_count|client_msg|server_msg' || true

assert_client_row() {
  local pattern="$1"
  local label="$2"
  if echo "$CLIENT_OUT" | grep -q "$pattern"; then
    echo "ok: $label"
  else
    echo "error: $label (expected to match: $pattern)" >&2
    echo "full client output:" >&2
    echo "$CLIENT_OUT" >&2
    exit 1
  fi
}

if echo "$CLIENT_OUT" | grep -qE 'discover_count\|(1|2)'; then
  echo "ok: client on tailnet (quack_discover returned endpoints)"
else
  echo "error: client quack_discover failed (expected discover_count|1 or |2)" >&2
  echo "full client output:" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
fi
assert_client_row 'row_count|2' 'remote table has 2 rows'
assert_client_row 'client_msg|insert-from-client' 'client INSERT visible'
assert_client_row 'server_msg|seed-from-server' 'server seed visible'

echo "=== Headscale nodes after e2e ==="
headscale_ci_exec headscale nodes list || true

echo "Headscale QuackTail e2e passed."
