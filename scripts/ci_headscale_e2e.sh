#!/usr/bin/env bash
# Two-node QuackTail e2e: Headscale + server + client DuckDB containers overlap.
# Server stays up (-d); client starts while server is still booting; client polls then ATTACH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
QUACKTAIL_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/quacktail_ci.sh
source "$ROOT/scripts/lib/quacktail_ci.sh"

QUACK_TOKEN="${QUACK_TAILNET_TOKEN:-quackscale-e2e-shared-token}"
SERVER_HOST="${E2E_SERVER_HOST:-quacktail-server}"
CLIENT_HOST="${E2E_CLIENT_HOST:-quacktail-client}"
QUACK_PORT="${E2E_QUACK_PORT:-9494}"
CLIENT_TIMEOUT="${E2E_CLIENT_TIMEOUT_SEC:-180}"
export E2E_SERVER_HOST="$SERVER_HOST"

WORK="${E2E_WORK:-${GITHUB_WORKSPACE:-$ROOT}/.e2e-work}"
mkdir -p "$WORK"
HS_DATA="$WORK/headscale-data"
CLIENT_LOG="$WORK/client.log"

cleanup() {
  quacktail_ci_stop
  if [[ "${HEADSCALE_ALREADY_RUNNING:-}" != "1" ]]; then
    headscale_ci_stop
  fi
}

e2e_dump_logs() {
  quacktail_ci_logs
  quacktail_ci_client_logs
}

trap 'e2e_dump_logs; cleanup' EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at '$DUCKDB'" >&2
  exit 1
fi

echo "Using DuckDB: $DUCKDB"
echo "E2e: Headscale up; server + client DuckDB containers run concurrently"

export DUCKDB_EXTENSION_DIRECTORY="${DUCKDB_EXTENSION_DIRECTORY:-$WORK/duckdb_extensions}"
quacktail_ci_docker_ext_setup
quacktail_ci_ensure_quack "$DUCKDB" "$DUCKDB_EXTENSION_DIRECTORY" install
quacktail_ci_build_image "$ROOT"

mkdir -p "$HS_DATA"
if [[ "${HEADSCALE_ALREADY_RUNNING:-}" == "1" ]]; then
  headscale_ci_wait_ready
else
  headscale_ci_start "$HS_DATA"
fi

if [[ -n "${HEADSCALE_AUTHKEY_FILE:-}" && -f "$HEADSCALE_AUTHKEY_FILE" ]]; then
  AUTHKEY="$(cat "$HEADSCALE_AUTHKEY_FILE")"
elif [[ -n "${HEADSCALE_AUTHKEY:-}" ]]; then
  AUTHKEY="$HEADSCALE_AUTHKEY"
else
  AUTHKEY="$(headscale_ci_create_authkey)"
fi
export QUACK_TAILNET_TOKEN="$QUACK_TOKEN"

CONTAINER_SERVER_STATE="/work/server-tailscale"
CONTAINER_CLIENT_STATE="/work/client-tailscale"

{
  headscale_ci_sql_tailscale_up "$SERVER_HOST" "$CONTAINER_SERVER_STATE" "$AUTHKEY"
  cat <<SQL

CREATE TABLE IF NOT EXISTS e2e_payload (id INTEGER PRIMARY KEY, msg VARCHAR, source VARCHAR);
DELETE FROM e2e_payload;
INSERT INTO e2e_payload VALUES (1, 'seed-from-server', 'server');
SQL
} >"$WORK/server_setup.sql"

{
  headscale_ci_sql_set_extension_directory "$(headscale_ci_container_extension_directory)"
  cat <<SQL

LOAD quack;

SQL
  headscale_ci_sql_quack_serve "$QUACK_PORT"
} >"$WORK/server_quack.sql"

{
  headscale_ci_sql_set_extension_directory "$(headscale_ci_container_extension_directory)"
  cat <<SQL

LOAD quack;

SQL
  headscale_ci_sql_tailscale_up "$CLIENT_HOST" "$CONTAINER_CLIENT_STATE" "$AUTHKEY"
  cat <<SQL

SELECT 'client_tailscale_up|done';
SQL
} >"$WORK/client_init.sql"

# --- Start server (long-lived) then client immediately — both on tailnet together ---
echo "=== Starting server container ($SERVER_HOST) ==="
quacktail_ci_start_server "$DUCKDB" "$WORK" "$SERVER_HOST" "$QUACK_PORT"

echo "=== Resolving server tailnet IP (Headscale node list; server container already running) ==="
SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST" 60)"
echo "Server tailnet IP: ${SERVER_IP}"

SERVER_QUACK_URI="$(headscale_ci_e2e_quack_attach_uri "$SERVER_IP" "$QUACK_PORT")"
SERVER_QUACK_SCOPE="$SERVER_QUACK_URI"
echo "Client will ATTACH: ${SERVER_QUACK_URI}"

{
  headscale_ci_sql_quack_client_attach "$SERVER_QUACK_URI" "$QUACK_TOKEN" "$SERVER_QUACK_SCOPE"
} >"$WORK/client_attach.sql"

{
  cat <<SQL
INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client')
ON CONFLICT DO NOTHING;

SELECT 'row_count|' || COUNT(*)::VARCHAR FROM remote.e2e_payload;
SELECT 'client_msg|' || msg FROM remote.e2e_payload WHERE source = 'client';
SELECT 'server_msg|' || msg FROM remote.e2e_payload WHERE source = 'server';
SQL
} >"$WORK/client_queries.sql"

export E2E_SERVER_IP="$SERVER_IP"

echo "=== Starting client container ($CLIENT_HOST) while server is still running ==="
quacktail_ci_start_client "$DUCKDB" "$WORK" "$QUACK_PORT"

echo "=== Waiting for client (server + client both running; timeout ${CLIENT_TIMEOUT}s) ==="
set +e
quacktail_ci_wait_client "$CLIENT_TIMEOUT"
CLIENT_RC=$?
set -e

docker logs "$QUACKTAIL_CLIENT_CONTAINER" >"$CLIENT_LOG" 2>&1 || true
CLIENT_OUT="$(cat "$CLIENT_LOG")"

if (( CLIENT_RC == 124 )); then
  echo "error: client timed out after ${CLIENT_TIMEOUT}s (server still running)" >&2
  exit 1
fi

if ! quacktail_ci_server_running; then
  echo "error: server container exited before client finished" >&2
  quacktail_ci_logs
  exit 1
fi

if (( CLIENT_RC != 0 )); then
  echo "error: client container exited $CLIENT_RC" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
fi

if echo "$CLIENT_OUT" | grep -qE 'Failed to send message|Timeout was reached|IO Error:.*HTTP POST'; then
  echo "error: Quack HTTP failed" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
fi

echo "$CLIENT_OUT" | grep -q 'quack_query_probe|1' || {
  echo "error: quack_query probe failed (server not reachable via Quack protocol)" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: quack_query probe"

echo "$CLIENT_OUT" | grep -q 'after_attach|ok' || {
  echo "error: ATTACH did not complete" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: ATTACH completed"

echo "$CLIENT_OUT" | grep -q 'insert-from-client' || {
  echo "error: client INSERT not found" >&2
  exit 1
}

echo "$CLIENT_OUT" | grep -q 'seed-from-server' || {
  echo "error: server seed not found" >&2
  exit 1
}

echo "Headscale QuackTail e2e passed (server + client ran concurrently)."
