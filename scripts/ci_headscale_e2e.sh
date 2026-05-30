#!/usr/bin/env bash
# CI e2e: release duckdb bind-mounted into minimal containers (no DuckDB compile).
# For source-built compose demo locally, use scripts/ci_compose_e2e.sh instead.
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
CLIENT_TIMEOUT="${E2E_CLIENT_TIMEOUT_SEC:-60}"
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
CONTAINER_CLIENT_STATE="/tmp/client-tailscale"

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

headscale_ci_sql_tailscale_up "$CLIENT_HOST" "$CONTAINER_CLIENT_STATE" "$AUTHKEY" \
  >"$WORK/client_init.sql"

echo "=== Starting server container ($SERVER_HOST) ==="
quacktail_ci_start_server "$DUCKDB" "$WORK" "$SERVER_HOST" "$QUACK_PORT"

echo "=== Resolving server tailnet IP ==="
SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST" 60)"
echo "Server tailnet IP: ${SERVER_IP}"

SERVER_QUACK_URI="$(headscale_ci_quack_forward_local_uri "${E2E_FORWARD_LOCAL_PORT:-19494}")"
echo "Client will ATTACH via forwarder: ${SERVER_QUACK_URI} → ${SERVER_HOST}:${QUACK_PORT}"
printf '%s' "$SERVER_QUACK_URI" >"$WORK/attach_uri"

headscale_ci_sql_client_session "$CLIENT_HOST" "$CONTAINER_CLIENT_STATE" "$AUTHKEY" \
  "$SERVER_HOST" "$QUACK_PORT" "$SERVER_QUACK_URI" "$QUACK_TOKEN" \
  >"$WORK/client_session.sql"

headscale_ci_sql_quack_client_demo "$SERVER_QUACK_URI" "$QUACK_TOKEN" "$SERVER_QUACK_URI" \
  >"$WORK/client_quack.sql"

export E2E_SERVER_IP="$SERVER_IP"
export QUACKTAIL_ATTACH_URI="$SERVER_QUACK_URI"

echo "=== Starting client container ($CLIENT_HOST) ==="
quacktail_ci_start_client "$DUCKDB" "$WORK" "$QUACK_PORT"

echo "=== Waiting for client (timeout ${CLIENT_TIMEOUT}s) ==="
set +e
quacktail_ci_wait_client "$CLIENT_TIMEOUT"
CLIENT_RC=$?
set -e

docker logs "$QUACKTAIL_CLIENT_CONTAINER" >"$CLIENT_LOG" 2>&1 || true
CLIENT_OUT="$(cat "$CLIENT_LOG")"

if (( CLIENT_RC == 124 )); then
  echo "error: client timed out after ${CLIENT_TIMEOUT}s" >&2
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

echo "$CLIENT_OUT" | grep -q 'PASSED' || {
  echo "error: PASSED row missing from client output" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: PASSED summary"

echo "$CLIENT_OUT" | grep -q 'insert-from-client' || {
  echo "error: client INSERT not found" >&2
  exit 1
}
echo "ok: client row"

echo "$CLIENT_OUT" | grep -q 'seed-from-server' || {
  echo "error: server seed not found" >&2
  exit 1
}
echo "ok: server row"

echo "Headscale QuackTail e2e passed (server + client ran concurrently)."
