#!/usr/bin/env bash
# Two-node QuackTail e2e over Headscale:
#   server — tailscale_up, quack_serve (shared token), quack_discover
#   client — tailscale_up, quack_discover, ATTACH, INSERT, SELECT
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

WORK="$(mktemp -d)"
HS_DATA="$(mktemp -d)"
SERVER_STATE="$WORK/server-tailscale"
CLIENT_STATE="$WORK/client-tailscale"
SERVER_DB="$WORK/server.duckdb"
SERVER_LOG="$WORK/server.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  headscale_ci_stop
  rm -rf "$WORK" "$HS_DATA"
}
trap cleanup EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at $DUCKDB (run: GEN=ninja make release)" >&2
  exit 1
fi

echo "Ensuring quack extension is available..."
if ! "$DUCKDB" -c "LOAD quack; SELECT 1;" >/dev/null 2>&1; then
  if ! "$DUCKDB" -c "INSTALL quack FROM core; LOAD quack; SELECT 1;" >/dev/null 2>&1; then
    "$DUCKDB" -c "INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;"
  fi
fi

headscale_ci_start "$HS_DATA"
AUTHKEY="$(headscale_ci_create_authkey)"

cat >"$WORK/server.sql" <<SQL
LOAD quack;
LOAD quackscale;

CALL tailscale_up(
    hostname => '${SERVER_HOST}',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${SERVER_STATE}',
    ephemeral => true
);

CREATE TABLE e2e_payload (id INTEGER PRIMARY KEY, msg VARCHAR, source VARCHAR);
INSERT INTO e2e_payload VALUES (1, 'seed-from-server', 'server');

CALL quack_serve(
    quack_uri(),
    allow_other_hostname => true,
    token => quack_token()
);
SQL

echo "Starting QuackTail server ($SERVER_HOST)..."
export QUACK_TAILNET_TOKEN="$QUACK_TOKEN"
python3 "$ROOT/scripts/lib/run_e2e_server.py" "$DUCKDB" "$SERVER_DB" "$WORK/server.sql" "$SERVER_LOG" &
SERVER_PID=$!

sleep 2
kill -0 "$SERVER_PID" || {
  echo "error: server process exited early" >&2
  cat "$SERVER_LOG" >&2 || true
  exit 1
}

echo "Waiting for server node on tailnet..."
SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST")"
echo "Server tailnet IP: $SERVER_IP"

headscale_ci_wait_tcp "$SERVER_IP" "$QUACK_PORT"

echo "Running QuackTail client ($CLIENT_HOST)..."
CLIENT_OUT="$(
  export QUACK_TAILNET_TOKEN="$QUACK_TOKEN"
  "$DUCKDB" :memory: <<SQL
LOAD quack;
LOAD quackscale;

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

-- Client-side discovery (local endpoints; server reachability verified via ATTACH)
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
)"

echo "$CLIENT_OUT"

echo "$CLIENT_OUT" | grep -q 'discover_count|1' || {
  echo "error: client quack_discover() did not return a local endpoint" >&2
  exit 1
}
echo "$CLIENT_OUT" | grep -q 'row_count|2' || {
  echo "error: expected 2 rows on remote table" >&2
  exit 1
}
echo "$CLIENT_OUT" | grep -q 'client_msg|insert-from-client' || {
  echo "error: client INSERT not visible" >&2
  exit 1
}
echo "$CLIENT_OUT" | grep -q 'server_msg|seed-from-server' || {
  echo "error: server seed row not visible to client" >&2
  exit 1
}

echo "Headscale QuackTail e2e passed."
