#!/usr/bin/env bash
# Two-node QuackTail e2e over Headscale — server and client run in Docker on quacktail-ci.
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

WORK="${E2E_WORK:-${GITHUB_WORKSPACE:-$ROOT}/.e2e-work}"
mkdir -p "$WORK"
HS_DATA="$WORK/headscale-data"
SERVER_STATE="$WORK/server-tailscale"
CLIENT_STATE="$WORK/client-tailscale"
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

trap 'e2e_dump_logs; cleanup' EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at '$DUCKDB'" >&2
  exit 1
fi

echo "Using DuckDB: $DUCKDB"
echo "E2e work directory: $WORK"
echo "E2e mode: Docker containers on network ${HEADSCALE_DOCKER_NETWORK}"

quacktail_ci_build_image "$ROOT"

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

# Paths inside the container (/work is bind-mounted from $WORK).
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
  cat <<SQL
LOAD quack;

SQL
  headscale_ci_sql_quack_serve "$QUACK_PORT"
} >"$WORK/server_quack.sql"

echo "=== Starting QuackTail server container ($SERVER_HOST) ==="
echo "--- SQL: server_setup.sql + server_quack.sql → server_init.sql (in container) ---"
cat "$WORK/server_setup.sql"
echo "--- server_quack.sql ---"
cat "$WORK/server_quack.sql"
quacktail_ci_start_server "$DUCKDB" "$WORK" "$SERVER_HOST" "$QUACK_PORT"
quacktail_ci_wait_server "$QUACK_PORT"

echo "Resolving server tailnet IP from Headscale ..."
SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST" 60)"
echo "Server tailnet IP: ${SERVER_IP}"
echo "Server MagicDNS: $(headscale_ci_tailnet_fqdn "$SERVER_HOST")"

SERVER_QUACK_URI="$(headscale_ci_quack_uri_for_ip "$SERVER_IP" "$QUACK_PORT")"
SERVER_QUACK_SCOPE="$SERVER_QUACK_URI"
echo "Client will ATTACH: ${SERVER_QUACK_URI} (SCOPE ${SERVER_QUACK_SCOPE})"

{
  cat <<SQL
LOAD quack;

SQL
  headscale_ci_sql_tailscale_up "$CLIENT_HOST" "$CONTAINER_CLIENT_STATE" "$AUTHKEY"
  headscale_ci_sql_quack_client_attach "$SERVER_QUACK_URI" "$QUACK_TOKEN" "$SERVER_QUACK_SCOPE"
  cat <<SQL

CREATE TEMP TABLE _discover AS SELECT * FROM quack_discover();
SELECT 'discover_count|' || COUNT(*)::VARCHAR;

INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client');

SELECT 'row_count|' || COUNT(*)::VARCHAR FROM remote.e2e_payload;
SELECT 'client_msg|' || msg FROM remote.e2e_payload WHERE source = 'client';
SELECT 'server_msg|' || msg FROM remote.e2e_payload WHERE source = 'server';
SQL
} >"$WORK/client.sql"

echo "=== Running QuackTail client container ($CLIENT_HOST) ==="
set +e
quacktail_ci_run_client "$DUCKDB" "$WORK" "$QUACK_PORT" 2>&1 | tee "$CLIENT_LOG"
CLIENT_RC=${PIPESTATUS[0]}
set -e

CLIENT_OUT="$(cat "$CLIENT_LOG")"
if (( CLIENT_RC != 0 )); then
  echo "error: client container failed (exit $CLIENT_RC)" >&2
  quacktail_ci_client_logs
  headscale_ci_logs
  exit 1
fi

echo "=== Result rows ==="
echo "$CLIENT_OUT" | grep -E 'discover_count|row_count|client_msg|server_msg|insert-from-client|seed-from-server' || true

echo "$CLIENT_OUT" | grep -qE 'discover_count\|(1|2)' || {
  echo "error: client quack_discover failed (expected discover_count|1 or |2)" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: client on tailnet (quack_discover returned endpoints)"

echo "$CLIENT_OUT" | grep -q 'insert-from-client' || {
  echo "error: client INSERT row not found" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: client INSERT visible"

echo "$CLIENT_OUT" | grep -q 'seed-from-server' || {
  echo "error: server seed row not found" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: server seed visible"

echo "$CLIENT_OUT" | grep -qE 'row_count\|2|│ 2 │|count_star\(\)\s*\│\s*2' || {
  echo "error: expected 2 rows in remote.e2e_payload" >&2
  echo "$CLIENT_OUT" >&2
  exit 1
}
echo "ok: remote table has 2 rows"

echo "=== Headscale nodes after e2e ==="
headscale_ci_exec headscale nodes list || true

echo "Headscale QuackTail e2e passed."
