#!/usr/bin/env bash
# Compose demo: create Headscale authkey + DuckDB init SQL in /work (via headscale CLI).
set -euo pipefail

WORK="${QUACKTAIL_WORK:-/work}"
SERVER_HOST="${SERVER_HOST:-quacktail-server}"
CLIENT_HOST="${CLIENT_HOST:-quacktail-client}"
QUACK_PORT="${QUACK_PORT:-9494}"
QUACK_TOKEN="${QUACK_TAILNET_TOKEN:-quackscale-demo-token}"
CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://headscale:8080}"
HS_USER="${HEADSCALE_USER:-quackscale-demo}"

if ! command -v headscale >/dev/null 2>&1; then
  echo "error: headscale CLI not found (required for QUACKTAIL_AUTO_BOOTSTRAP)" >&2
  exit 1
fi

mkdir -p "$WORK"

headscale users create "$HS_USER" >/dev/null 2>&1 || true

USER_ID="$(
  HS_USER="$HS_USER" headscale users list -o json | HS_USER="$HS_USER" python3 - <<'PY'
import json, os, sys

def field(obj, *names):
    for name in names:
        if isinstance(obj, dict) and obj.get(name) is not None:
            return obj[name]
    return None

def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("users", "Users"):
            if isinstance(value.get(key), list):
                return value[key]
    return []

target = os.environ["HS_USER"]
for user in as_list(json.load(sys.stdin)):
    if field(user, "name", "Name") == target:
        uid = field(user, "id", "Id", "ID")
        if uid is not None:
            print(uid)
        sys.exit(0)
sys.exit(0)
PY
)" || true

create_authkey() {
  local -a cmd=(headscale preauthkeys create --reusable --expiration 168h)
  if [[ -n "${USER_ID:-}" ]]; then
    cmd+=(--user "$USER_ID")
  fi
  "${cmd[@]}"
}

AUTHKEY="$(create_authkey 2>/dev/null | awk 'NF {k=$0} END {print k}')"
if [[ -z "$AUTHKEY" ]]; then
  AUTHKEY="$(create_authkey -o json 2>/dev/null | python3 - <<'PY'
import json, sys

def field(obj, *names):
    for name in names:
        if isinstance(obj, dict) and obj.get(name):
            return obj[name]
    return None

raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
data = json.loads(raw)
key = field(data, "key", "Key")
if not key and isinstance(data, dict):
    nested = field(data, "preAuthKey", "pre_auth_key")
    if isinstance(nested, dict):
        key = field(nested, "key", "Key")
print(key or "")
PY
  )" || true
fi

if [[ -z "$AUTHKEY" ]]; then
  echo "error: failed to create Headscale authkey" >&2
  headscale users list >&2 || true
  exit 1
fi

printf '%s' "$AUTHKEY" >"$WORK/authkey"
chmod 600 "$WORK/authkey"

cat >"$WORK/server_setup.sql" <<SQL
CALL tailscale_up(
    hostname => '${SERVER_HOST}',
    control_url => '${CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '/work/server-tailscale',
    ephemeral => true
);

CREATE TABLE IF NOT EXISTS e2e_payload (id INTEGER PRIMARY KEY, msg VARCHAR, source VARCHAR);
DELETE FROM e2e_payload;
INSERT INTO e2e_payload VALUES (1, 'seed-from-server', 'server');
SQL

cat >"$WORK/server_quack.sql" <<SQL
SET extension_directory='/duckdb_extensions';
LOAD quack;

CALL quack_serve(
    quack_uri(),
    allow_other_hostname => true,
    token => quack_token()
);
SQL

cat >"$WORK/client_init.sql" <<SQL
SET extension_directory='/duckdb_extensions';
LOAD quack;

CALL tailscale_up(
    hostname => '${CLIENT_HOST}',
    control_url => '${CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '/work/client-tailscale',
    ephemeral => true
);

SELECT 'client_tailscale_up|done';
SQL

ATTACH_URI="quack:${SERVER_HOST}:${QUACK_PORT}"

cat >"$WORK/client_attach.sql" <<SQL
CREATE TEMP TABLE _discover AS SELECT * FROM quack_discover();
SELECT 'discover_count|' || COUNT(*)::VARCHAR;

SELECT 'before_quack_query|${ATTACH_URI}';

SELECT 'quack_query_probe|' || CAST(q AS VARCHAR)
FROM quack_query(
    '${ATTACH_URI}',
    'SELECT 1 AS q',
    token => '${QUACK_TOKEN}',
    disable_ssl => true
);

SELECT 'before_attach|${ATTACH_URI}';

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE '${ATTACH_URI}'
);

ATTACH '${ATTACH_URI}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

SELECT 'after_attach|ok';
SQL

cat >"$WORK/client_queries.sql" <<SQL
INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client');

SELECT 'row_count|' || COUNT(*)::VARCHAR FROM remote.e2e_payload;
SELECT 'client_msg|' || msg FROM remote.e2e_payload WHERE source = 'client';
SELECT 'server_msg|' || msg FROM remote.e2e_payload WHERE source = 'server';
SQL

echo "compose bootstrap ok — ATTACH ${ATTACH_URI}"
