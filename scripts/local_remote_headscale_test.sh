#!/usr/bin/env bash
# Local DuckDB (build/release/duckdb) → remote Headscale + remote quacktail-server.
# Uses the same defaults as examples/docker-compose.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
STATE_DIR="${QUACKSCALE_STATE_DIR:-${HOME}/.local/share/duckdb/quackscale-remote-test}"

# examples/docker-compose.yml defaults
export QUACK_TAILNET_TOKEN="${QUACK_TAILNET_TOKEN:-quackscale-demo-token}"
HEADSCALE_CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://127.0.0.1:8080}"
HEADSCALE_USER="${HEADSCALE_USER:-quackscale-demo}"
SERVER_HOST="${SERVER_HOST:-quacktail-server}"
CLIENT_HOST="${CLIENT_HOST:-local-duckdb}"
QUACK_PORT="${QUACK_PORT:-9494}"
QUACK_FORWARD_LOCAL_PORT="${QUACK_FORWARD_LOCAL_PORT:-19494}"
ATTACH_URI="quack:127.0.0.1:${QUACK_FORWARD_LOCAL_PORT}"

# Reusable Headscale preauth key (NOT the Quack token — see QUACK_TAILNET_TOKEN below).
# From remote stack: docker exec quacktail-server cat /work/authkey
# Or: docker exec quacktail-server cat /work/demo.env
AUTHKEY_FILE="${ROOT}/examples/headscale/demo.authkey"
HEADSCALE_AUTHKEY="${HEADSCALE_AUTHKEY:-${TS_AUTHKEY:-}}"
if [[ -z "$HEADSCALE_AUTHKEY" && -f "$AUTHKEY_FILE" ]]; then
  HEADSCALE_AUTHKEY="$(tr -d '[:space:]' <"$AUTHKEY_FILE")"
fi

if [[ -z "$HEADSCALE_AUTHKEY" ]]; then
  echo "error: Headscale preauth key required (this is NOT quackscale-demo-token)." >&2
  echo "  Quack token (compose):  QUACK_TAILNET_TOKEN=quackscale-demo-token" >&2
  echo "  Headscale join key:     docker exec quacktail-server cat /work/authkey" >&2
  echo "  Save locally:           examples/headscale/demo.authkey" >&2
  exit 1
fi

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at $DUCKDB — run: GEN=ninja make release" >&2
  exit 1
fi

echo "=== Local QuackScale → remote Headscale ==="
echo "DuckDB:        $DUCKDB"
echo "Control URL:   $HEADSCALE_CONTROL_URL"
echo "Headscale user: $HEADSCALE_USER"
echo "Server:        ${SERVER_HOST}:${QUACK_PORT}"
echo "Quack token:   ${QUACK_TAILNET_TOKEN}"
echo "State dir:     $STATE_DIR"
echo "Attach URI:    $ATTACH_URI (via tailscale_quack_forward)"
echo ""

curl -sf --connect-timeout 5 "${HEADSCALE_CONTROL_URL%/}/health" >/dev/null \
  || { echo "error: Headscale not reachable at ${HEADSCALE_CONTROL_URL}" >&2; exit 1; }
echo "✓ Headscale health OK"
echo ""

mkdir -p "$STATE_DIR"
EXT_DIR="${DUCKDB_EXTENSION_DIRECTORY:-/tmp/quackscale-remote-ext}"
mkdir -p "$EXT_DIR"

# shellcheck source=scripts/lib/quacktail_ext.sh
source "$ROOT/scripts/lib/quacktail_ext.sh"
quacktail_ci_ensure_quack "$DUCKDB" "$EXT_DIR" install 2>/dev/null || true

SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT

cat >"$SQL_FILE" <<SQL
LOAD quackscale;

CALL tailscale_up(
    hostname => '${CLIENT_HOST}',
    control_url => '${HEADSCALE_CONTROL_URL}',
    authkey => '${HEADSCALE_AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => true
);

CALL tailscale_quack_forward(
    host => '${SERVER_HOST}',
    port => ${QUACK_PORT},
    local_port => ${QUACK_FORWARD_LOCAL_PORT}
);

CALL tailscale_ping(host => '${SERVER_HOST}', port => ${QUACK_PORT});

$(quacktail_ext_sql_set "$EXT_DIR")
LOAD quack;

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TAILNET_TOKEN}',
    SCOPE '${ATTACH_URI}'
);

FROM quack_query(
    '${ATTACH_URI}',
    'SELECT 1 AS probe',
    token => '${QUACK_TAILNET_TOKEN}',
    disable_ssl => true
);

ATTACH '${ATTACH_URI}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

SELECT * FROM remote.e2e_payload LIMIT 5;
SQL

echo "→ join tailnet, forward, ping, quack_query, ATTACH ..."
if ! "$DUCKDB" -batch -echo -f "$SQL_FILE"; then
  echo "error: remote QuackTail test failed" >&2
  exit 1
fi

echo ""
echo "✓ Local DuckDB reached remote quacktail-server over Headscale"
