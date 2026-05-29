#!/usr/bin/env bash
# Local preflight (optional). In GitHub Actions, use workflow steps instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
HEADSCALE_CI_ROOT="$ROOT"
# shellcheck source=scripts/lib/headscale_ci.sh
source "$ROOT/scripts/lib/headscale_ci.sh"

WORK="${E2E_WORK:-${GITHUB_WORKSPACE:-$ROOT}/.e2e-work}"
mkdir -p "$WORK"

echo "=== DuckDB ==="
"$DUCKDB" -version 2>&1 || "$DUCKDB" --version
"$DUCKDB" :memory: -csv -c \
  "SELECT extension_name, loaded, install_path FROM duckdb_extensions() WHERE extension_name='quackscale';"
"$DUCKDB" :memory: -batch -echo -c "CALL tailscale_status();"

if ! "$DUCKDB" -c "LOAD quack; SELECT 1;"; then
  "$DUCKDB" -c "INSTALL quack FROM core; LOAD quack; SELECT 1;" \
    || "$DUCKDB" -c "INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;"
fi

headscale_ci_start "$WORK/headscale-data"
AUTHKEY="$(headscale_ci_create_authkey)"
headscale_ci_verify_tailscale_client "$AUTHKEY" "headscale-preflight-smoke"

STATE="$WORK/preflight-tailscale"
rm -rf "$STATE"
mkdir -p "$STATE"
cat >"$WORK/preflight_tailscale.sql" <<SQL
CALL tailscale_up(
    hostname => 'headscale-preflight-duckdb',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE}',
    ephemeral => true
);
CALL tailscale_status();
SQL
"$DUCKDB" :memory: -batch -echo -f "$WORK/preflight_tailscale.sql"

headscale_ci_stop
echo "Preflight passed."
