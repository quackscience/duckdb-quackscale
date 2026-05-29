#!/usr/bin/env bash
# Smoke-test QuackTail against Headscale (quackscale linked from source build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
HEADSCALE_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/headscale_ci.sh
source "$ROOT/scripts/lib/headscale_ci.sh"

STATE_DIR="$(mktemp -d)"

cleanup() {
  if [[ "${HEADSCALE_ALREADY_RUNNING:-}" != "1" ]]; then
    headscale_ci_stop
  fi
  rm -rf "$STATE_DIR"
}
trap cleanup EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at $DUCKDB" >&2
  exit 1
fi

if [[ "${HEADSCALE_ALREADY_RUNNING:-}" == "1" ]]; then
  headscale_ci_wait_ready
else
  DATA_DIR="$(mktemp -d)"
  headscale_ci_start "$DATA_DIR"
fi
AUTHKEY="$(headscale_ci_create_authkey)"
headscale_ci_verify_tailscale_client "$AUTHKEY" "quackscale-smoke"

echo "Joining Headscale from DuckDB (control_url=$HEADSCALE_CONTROL_URL) ..."
echo "--- SQL ---"
cat <<SQL
CALL tailscale_up(
    hostname => 'quackscale-ci',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => true
);
CALL tailscale_status();
SQL
echo "--- DuckDB output ---"
"$DUCKDB" :memory: -batch -echo <<SQL
CALL tailscale_up(
    hostname => 'quackscale-ci',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => true
);
CALL tailscale_status();
SQL

echo "=== Headscale nodes after smoke ==="
headscale_ci_exec headscale nodes list || true

echo "Headscale + QuackTail smoke test passed."
