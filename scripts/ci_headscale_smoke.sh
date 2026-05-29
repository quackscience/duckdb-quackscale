#!/usr/bin/env bash
# Smoke-test QuackTail against Headscale (built-in quackscale; no LOAD quackscale).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
HEADSCALE_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/headscale_ci.sh
source "$ROOT/scripts/lib/headscale_ci.sh"

STATE_DIR="$(mktemp -d)"

cleanup() {
  headscale_ci_stop
  rm -rf "$STATE_DIR"
}
trap cleanup EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at $DUCKDB" >&2
  exit 1
fi

headscale_ci_start
AUTHKEY="$(headscale_ci_create_authkey)"
headscale_ci_verify_tailscale_client "$AUTHKEY" "quackscale-smoke"

echo "Joining Headscale from DuckDB (control_url=$HEADSCALE_CONTROL_URL) ..."
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

echo "Headscale + QuackTail smoke test passed."
