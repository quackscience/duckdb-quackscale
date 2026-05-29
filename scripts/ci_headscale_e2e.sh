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

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  headscale_ci_stop
}
trap cleanup EXIT

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
headscale_ci_start

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

# Server bootstrap: tailnet only (quack is loaded later for quack_serve).
cat >"$WORK/server_bootstrap.sql" <<SQL
CALL tailscale_up(
    hostname => '${SERVER_HOST}',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${SERVER_STATE}',
    ephemeral => true
);

CREATE TABLE e2e_payload (id INTEGER PRIMARY KEY, msg VARCHAR, source VARCHAR);
INSERT INTO e2e_payload VALUES (1, 'seed-from-server', 'server');
SQL

e2e_run_duckdb "Joining server to Headscale (blocking)" "$SERVER_DB" "$WORK/server_bootstrap.sql" "$SERVER_LOG"

echo "Resolving server tailnet IP..."
SERVER_IP=""
if SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST")"; then
  echo "Server tailnet IP (from Headscale): $SERVER_IP"
else
  echo "error: could not determine server tailnet IP" >&2
  headscale_ci_logs
  exit 1
fi

cat >"$WORK/server_serve.sql" <<SQL
LOAD quack;

CALL tailscale_up(
    hostname => '${SERVER_HOST}',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${SERVER_STATE}',
    ephemeral => true
);

CALL quack_serve(
    quack_uri(),
    allow_other_hostname => true,
    token => quack_token()
);
SQL

echo "Starting Quack listener on server..."
python3 "$ROOT/scripts/lib/run_e2e_server.py" "$DUCKDB" "$SERVER_DB" "$WORK/server_serve.sql" "$SERVER_LOG" &
SERVER_PID=$!

sleep 2
kill -0 "$SERVER_PID" || {
  echo "error: server process exited early" >&2
  tail -80 "$SERVER_LOG" >&2 || true
  headscale_ci_logs
  exit 1
}

headscale_ci_wait_tcp "$SERVER_IP" "$QUACK_PORT"

cat >"$WORK/client.sql" <<SQL
LOAD quack;

CALL tailscale_up(
    hostname => '${CLIENT_HOST}',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${CLIENT_STATE}',
    ephemeral => true
);

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE 'quack:${SERVER_IP}:${QUACK_PORT}'
);

.mode csv
.separator |

CREATE TEMP TABLE _discover AS SELECT * FROM quack_discover();
SELECT 'discover_count', COUNT(*)::VARCHAR FROM _discover;

ATTACH 'quack:${SERVER_IP}:${QUACK_PORT}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client');

SELECT 'row_count', COUNT(*)::VARCHAR FROM remote.e2e_payload;
SELECT 'client_msg', msg FROM remote.e2e_payload WHERE source = 'client';
SELECT 'server_msg', msg FROM remote.e2e_payload WHERE source = 'server';
SQL

echo "Running QuackTail client ($CLIENT_HOST)..."
CLIENT_OUT=""
CLIENT_OUT="$("$DUCKDB" :memory: -batch -echo -f "$WORK/client.sql" 2>&1 | tee -a "$CLIENT_LOG")"
CLIENT_RC=${PIPESTATUS[0]}
if (( CLIENT_RC != 0 )); then
  echo "error: client DuckDB failed (exit $CLIENT_RC)" >&2
  headscale_ci_logs
  exit 1
fi

echo "$CLIENT_OUT" | grep -q 'discover_count|1' || { echo "error: quack_discover failed" >&2; exit 1; }
echo "$CLIENT_OUT" | grep -q 'row_count|2' || { echo "error: expected 2 rows" >&2; exit 1; }
echo "$CLIENT_OUT" | grep -q 'client_msg|insert-from-client' || { echo "error: client INSERT missing" >&2; exit 1; }
echo "$CLIENT_OUT" | grep -q 'server_msg|seed-from-server' || { echo "error: server seed missing" >&2; exit 1; }

echo "Headscale QuackTail e2e passed."
