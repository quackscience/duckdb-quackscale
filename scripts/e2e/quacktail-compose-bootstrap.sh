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
HS_CFG="${HEADSCALE_CONFIG:-/etc/headscale/config.yaml}"
HS=(headscale -c "$HS_CFG")
HS_SOCKET="${HEADSCALE_SOCKET:-/var/run/headscale/headscale.sock}"

if ! command -v headscale >/dev/null 2>&1; then
  echo "error: headscale CLI not found (required for QUACKTAIL_AUTO_BOOTSTRAP)" >&2
  exit 1
fi

mkdir -p "$WORK"

ATTACH_URI="quack:${SERVER_HOST}:${QUACK_PORT}"
CLIENT_STATE_DIR="/tmp/client-tailscale"

write_client_init_sql() {
  local authkey="${1:?authkey required}"
  cat >"$WORK/client_init.sql" <<SQL
SET extension_directory='/duckdb_extensions';
LOAD quack;

CALL tailscale_up(
    hostname => '${CLIENT_HOST}',
    control_url => '${CONTROL_URL}',
    authkey => '${authkey}',
    state_dir => '${CLIENT_STATE_DIR}',
    ephemeral => true
);
SQL
}

write_client_demo_sql() {
  cat >"$WORK/client_demo.sql" <<SQL
CREATE TEMP TABLE _discover AS SELECT * FROM quack_discover();
SELECT * FROM _discover;

SELECT q AS probe_result
FROM quack_query(
    '${ATTACH_URI}',
    'SELECT 1 AS q',
    token => '${QUACK_TOKEN}',
    disable_ssl => true
);

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE '${ATTACH_URI}'
);

ATTACH '${ATTACH_URI}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

DELETE FROM remote.e2e_payload WHERE source = 'client';
INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client');

SELECT
    'PASSED' AS status,
    '${ATTACH_URI}' AS attach_uri,
    (SELECT msg FROM remote.e2e_payload WHERE source = 'server') AS server_row,
    (SELECT msg FROM remote.e2e_payload WHERE source = 'client') AS client_row,
    (SELECT COUNT(*)::INTEGER FROM remote.e2e_payload) AS total_rows;
SQL
}

if [[ -f "$WORK/server_setup.sql" && -f "$WORK/authkey" ]]; then
  AUTHKEY="$(cat "$WORK/authkey")"
  if [[ "${COMPOSE_REFRESH_CLIENT_SQL:-}" == "1" ]] \
    || [[ ! -f "$WORK/client_demo.sql" ]] \
    || ! grep -q '_discover AS' "$WORK/client_demo.sql" 2>/dev/null \
    || ! grep -q "${CLIENT_STATE_DIR}" "$WORK/client_init.sql" 2>/dev/null; then
    write_client_init_sql "$AUTHKEY"
    write_client_demo_sql
    echo "✓ client SQL ready — ${ATTACH_URI}"
  fi
  exit 0
fi

echo "Waiting for Headscale socket ${HS_SOCKET} ..."
for _ in $(seq 1 60); do
  if [[ -S "$HS_SOCKET" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -S "$HS_SOCKET" ]]; then
  echo "error: Headscale socket not found at ${HS_SOCKET}" >&2
  exit 1
fi

"${HS[@]}" users create "$HS_USER" >/dev/null 2>&1 || true

USER_ID=""
users_json="$("${HS[@]}" users list -o json 2>/dev/null || true)"
if [[ -n "$users_json" ]]; then
  USER_ID="$(
    HS_USER="$HS_USER" USERS_JSON="$users_json" python3 - <<'PY'
import json, os, sys

def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("users", "Users"):
            if isinstance(value.get(key), list):
                return value[key]
    return []

def field(obj, *names):
    for name in names:
        if isinstance(obj, dict) and obj.get(name) is not None:
            return obj[name]
    return None

target = os.environ["HS_USER"]
try:
    users = as_list(json.loads(os.environ["USERS_JSON"]))
except json.JSONDecodeError:
    sys.exit(0)
for user in users:
    if field(user, "name", "Name", "username", "Username") == target:
        uid = field(user, "id", "Id", "ID")
        if uid is not None:
            print(uid)
        sys.exit(0)
if users:
    uid = field(users[0], "id", "Id", "ID")
    if uid is not None:
        print(uid)
sys.exit(0)
PY
  )" || true
fi

create_authkey() {
  local -a cmd=(preauthkeys create --reusable --expiration 168h)
  if [[ -n "${USER_ID:-}" ]]; then
    cmd+=(--user "$USER_ID")
  fi
  "${HS[@]}" "${cmd[@]}"
}

AUTHKEY=""
authkey_json="$(create_authkey -o json 2>/dev/null || true)"
if [[ -n "$authkey_json" ]]; then
  AUTHKEY="$(
    AUTHKEY_JSON="$authkey_json" python3 - <<'PY'
import json, os, sys

def field(obj, *names):
    for name in names:
        if isinstance(obj, dict) and obj.get(name):
            return obj[name]
    return None

try:
    data = json.loads(os.environ["AUTHKEY_JSON"])
except json.JSONDecodeError:
    sys.exit(1)
key = field(data, "key", "Key")
if not key and isinstance(data, dict):
    nested = field(data, "preAuthKey", "pre_auth_key", "PreAuthKey")
    if isinstance(nested, dict):
        key = field(nested, "key", "Key")
print(key or "")
PY
  )" || true
fi

if [[ -z "$AUTHKEY" ]]; then
  AUTHKEY="$(create_authkey 2>/dev/null | awk 'NF {k=$0} END {print k}')" || true
fi

if [[ -z "$AUTHKEY" ]]; then
  echo "error: failed to create Headscale authkey" >&2
  echo "headscale users list:" >&2
  "${HS[@]}" users list >&2 || true
  echo "headscale preauthkeys create (debug):" >&2
  create_authkey >&2 || true
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
    state_dir => '${CLIENT_STATE_DIR}',
    ephemeral => true
);
SQL

write_client_demo_sql

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

echo "✓ Headscale authkey ready — attach URI ${ATTACH_URI}"
