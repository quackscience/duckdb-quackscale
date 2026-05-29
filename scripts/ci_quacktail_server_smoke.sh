#!/usr/bin/env bash
# Job B: server container joins Headscale, publishes Quack via tailscale_serve_local,
# then polls until the server can reach its own tailnet-published endpoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
QUACKTAIL_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/quacktail_ci.sh
source "$ROOT/scripts/lib/quacktail_ci.sh"

QUACK_TOKEN="${QUACK_TAILNET_TOKEN:-quackscale-e2e-shared-token}"
SERVER_HOST="${E2E_SERVER_HOST:-quacktail-server-smoke}"
QUACK_PORT="${E2E_QUACK_PORT:-9494}"
WORK="${E2E_WORK:-${GITHUB_WORKSPACE:-$ROOT}/.e2e-work-server-smoke}"
HS_DATA="$WORK/headscale-data"

cleanup() {
  quacktail_ci_stop
  if [[ "${HEADSCALE_ALREADY_RUNNING:-}" != "1" ]]; then
    headscale_ci_stop
  fi
}
trap cleanup EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at '$DUCKDB'" >&2
  exit 1
fi

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
else
  AUTHKEY="$(headscale_ci_create_authkey)"
fi
export QUACK_TAILNET_TOKEN="$QUACK_TOKEN"

CONTAINER_STATE="/work/server-tailscale"
{
  headscale_ci_sql_tailscale_up "$SERVER_HOST" "$CONTAINER_STATE" "$AUTHKEY"
} >"$WORK/server_setup.sql"

{
  headscale_ci_sql_set_extension_directory "$(headscale_ci_container_extension_directory)"
  cat <<SQL

LOAD quack;

SQL
  headscale_ci_sql_quack_serve "$QUACK_PORT"
} >"$WORK/server_quack.sql"

echo "=== Server publish smoke: starting $SERVER_HOST ==="
quacktail_ci_start_server "$DUCKDB" "$WORK" "$SERVER_HOST" "$QUACK_PORT"

echo "Waiting for server node on Headscale ..."
SERVER_IP="$(headscale_ci_node_ipv4 "$SERVER_HOST" 30)"
echo "Server tailnet IP: ${SERVER_IP}"

quacktail_ci_wait_server_local "$QUACK_PORT"
quacktail_ci_wait_server_published "$QUACK_PORT" "$SERVER_IP" "${QUACK_TAILNET_TOKEN:-}"

echo "Server publish smoke passed (loopback bind + tailnet self-reach on ${SERVER_IP}:${QUACK_PORT})."
