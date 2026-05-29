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
headscale_ci_sql_tailscale_up "quackscale-ci" "$STATE_DIR" "$AUTHKEY"
echo "CALL tailscale_status();"
echo "--- DuckDB output ---"
{
  headscale_ci_sql_tailscale_up "quackscale-ci" "$STATE_DIR" "$AUTHKEY"
  echo "CALL tailscale_status();"
} | "$DUCKDB" :memory: -batch -echo -f /dev/stdin

echo "=== Headscale nodes after smoke ==="
headscale_ci_exec headscale nodes list || true

echo "Headscale + QuackTail smoke test passed."
