#!/usr/bin/env bash
# Smoke-test QuackScale against a local Headscale control server (Tailscale-compatible).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
HEADSCALE_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/headscale_ci.sh
source "$ROOT/scripts/lib/headscale_ci.sh"

DATA_DIR="$(mktemp -d)"
STATE_DIR="$(mktemp -d)"

cleanup() {
  headscale_ci_stop
  rm -rf "$DATA_DIR" "$STATE_DIR"
}
trap cleanup EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at $DUCKDB (run: GEN=ninja make release)" >&2
  exit 1
fi

headscale_ci_start "$DATA_DIR"
AUTHKEY="$(headscale_ci_create_authkey)"

echo "Joining Headscale tailnet from DuckDB (control_url=$HEADSCALE_CONTROL_URL)..."
"$DUCKDB" <<SQL
LOAD quackscale;
CALL tailscale_up(
    hostname => 'quackscale-ci',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => true
);
CALL tailscale_status();
SQL

echo "Headscale + QuackScale smoke test passed."
