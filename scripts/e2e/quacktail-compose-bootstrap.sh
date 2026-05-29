#!/usr/bin/env bash
# Compose demo: create Headscale authkey + DuckDB init SQL in /work (via headscale CLI).
set -euo pipefail

WORK="${QUACKTAIL_WORK:-/work}"
SERVER_HOST="${SERVER_HOST:-quacktail-server}"
CLIENT_HOST="${CLIENT_HOST:-quacktail-client}"
QUACK_PORT="${QUACK_PORT:-9494}"
QUACK_FORWARD_LOCAL_PORT="${QUACK_FORWARD_LOCAL_PORT:-19494}"
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

CLIENT_STATE_DIR="/tmp/client-tailscale"
ATTACH_URI="quack:${SERVER_HOST}:${QUACK_PORT}"

resolve_server_tailnet_ip() {
  "${HS[@]}" nodes list 2>/dev/null | grep -F "$SERVER_HOST" | grep -oE '100\.64\.[0-9]+\.[0-9]+' | head -1 || true
}

resolve_attach_uri() {
  echo "quack:${SERVER_HOST}:${QUACK_PORT}"
}

resolve_client_attach_uri() {
  local ext_dir="/duckdb_extensions"
  if command -v duckdb >/dev/null 2>&1 \
    && duckdb :memory: -batch -csv -noheader -c \
      "SET extension_directory='${ext_dir}'; LOAD quackscale; SELECT COUNT(*) FROM duckdb_functions() WHERE function_name='tailscale_quack_forward';" \
      2>/dev/null | grep -qx '1'; then
    echo "quack:127.0.0.1:${QUACK_FORWARD_LOCAL_PORT}"
  else
    resolve_attach_uri
  fi
}

duckdb_has_quackscale_function() {
  local fn="$1"
  local ext_dir="/duckdb_extensions"
  command -v duckdb >/dev/null 2>&1 \
    && duckdb :memory: -batch -csv -noheader -c \
      "SET extension_directory='${ext_dir}'; LOAD quackscale; SELECT COUNT(*) FROM duckdb_functions() WHERE function_name='${fn}';" \
      2>/dev/null | grep -qx '1'
}

write_server_quack_sql() {
  # Quack on loopback; tailscale_serve_local publishes :9494 on the tailnet (tsnet-in-process).
  # Direct quack:0.0.0.0 bind only hits the host loopback — cross-node ATTACH never reaches it.
  cat >"$WORK/server_quack.sql" <<SQL
SET extension_directory='/duckdb_extensions';
LOAD quack;

CALL quack_serve(
    'quack:127.0.0.1:${QUACK_PORT}',
    allow_other_hostname => true,
    token => quack_token()
);
CALL tailscale_serve_local(port => ${QUACK_PORT});
SQL
}

write_client_init_sql() {
  local authkey="${1:?authkey required}"
  cat >"$WORK/client_init.sql" <<SQL
CALL tailscale_up(
    hostname => '${CLIENT_HOST}',
    control_url => '${CONTROL_URL}',
    authkey => '${authkey}',
    state_dir => '${CLIENT_STATE_DIR}',
    ephemeral => true
);
SQL
}

write_client_session_sql() {
  local authkey="${1:?authkey required}"
  local attach_uri="${2:?attach uri required}"
  local ping_sql=""
  local forward_sql=""
  local ext_dir="/duckdb_extensions"
  if duckdb_has_quackscale_function tailscale_ping; then
    ping_sql="CALL tailscale_ping(host => '${SERVER_HOST}', port => ${QUACK_PORT});"
  fi
  if duckdb_has_quackscale_function tailscale_quack_forward; then
    forward_sql="CALL tailscale_quack_forward(host => '${SERVER_HOST}', port => ${QUACK_PORT}, local_port => ${QUACK_FORWARD_LOCAL_PORT});"
  elif duckdb_has_quackscale_function tailscale_quack_proxy; then
    forward_sql="CALL tailscale_quack_proxy();"
  fi
  cat >"$WORK/client_session.sql" <<SQL
LOAD quackscale;

CALL tailscale_up(
    hostname => '${CLIENT_HOST}',
    control_url => '${CONTROL_URL}',
    authkey => '${authkey}',
    state_dir => '${CLIENT_STATE_DIR}',
    ephemeral => true
);

${forward_sql}

${ping_sql}

SET extension_directory='/duckdb_extensions';
LOAD quack;

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE '${attach_uri}'
);

FROM quack_query(
    '${attach_uri}',
    'SELECT 1 AS probe',
    token => '${QUACK_TOKEN}',
    disable_ssl => true
);

ATTACH '${attach_uri}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client')
ON CONFLICT DO NOTHING;

SELECT
    'PASSED' AS status,
    '${attach_uri}' AS attach_uri,
    MAX(CASE WHEN source = 'server' THEN msg END) AS server_row,
    MAX(CASE WHEN source = 'client' THEN msg END) AS client_row,
    COUNT(*)::INTEGER AS total_rows
FROM remote.e2e_payload;
SQL
  write_client_init_sql "$authkey"
  cp "$WORK/client_session.sql" "$WORK/client_demo.sql"
}

write_client_quack_sql() {
  local attach_uri="${1:?attach uri required}"
  cat >"$WORK/client_quack.sql" <<SQL
SET extension_directory='/duckdb_extensions';
LOAD quack;

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE '${attach_uri}'
);

ATTACH '${attach_uri}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client')
ON CONFLICT DO NOTHING;

SELECT
    'PASSED' AS status,
    '${attach_uri}' AS attach_uri,
    MAX(CASE WHEN source = 'server' THEN msg END) AS server_row,
    MAX(CASE WHEN source = 'client' THEN msg END) AS client_row,
    COUNT(*)::INTEGER AS total_rows
FROM remote.e2e_payload;
SQL
}

write_client_attach_sql() {
  local attach_uri="${1:?attach uri required}"
  cat >"$WORK/client_attach.sql" <<SQL
SET extension_directory='/duckdb_extensions';
LOAD quack;

SELECT 'before_attach|${attach_uri}';

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TOKEN}',
    SCOPE '${attach_uri}'
);

ATTACH '${attach_uri}' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

SELECT 'after_attach|ok';
SQL
}

write_client_queries_sql() {
  cat >"$WORK/client_queries.sql" <<SQL
INSERT INTO remote.e2e_payload VALUES (2, 'insert-from-client', 'client')
ON CONFLICT DO NOTHING;

SELECT 'row_count|' || COUNT(*)::VARCHAR FROM remote.e2e_payload;
SELECT 'client_msg|' || msg FROM remote.e2e_payload WHERE source = 'client';
SELECT 'server_msg|' || msg FROM remote.e2e_payload WHERE source = 'server';
SQL
}

refresh_client_sql() {
  local authkey="${1:?authkey required}"
  local attach_uri
  attach_uri="$(resolve_client_attach_uri)"
  ATTACH_URI="$attach_uri"
  write_client_session_sql "$authkey" "$attach_uri"
  write_client_quack_sql "$attach_uri"
  write_client_attach_sql "$attach_uri"
  write_client_queries_sql
  printf '%s' "$attach_uri" >"$WORK/attach_uri"
}

if [[ -f "$WORK/server_setup.sql" && -f "$WORK/authkey" ]]; then
  AUTHKEY="$(cat "$WORK/authkey")"
  if [[ "${COMPOSE_REFRESH_SERVER_QUACK:-}" == "1" ]] \
    || [[ ! -f "$WORK/server_quack.sql" ]] \
    || grep -q 'quack_uri()' "$WORK/server_quack.sql" 2>/dev/null \
    || grep -q '0\.0\.0\.0' "$WORK/server_quack.sql" 2>/dev/null \
    || ! grep -q 'tailscale_serve_local' "$WORK/server_quack.sql" 2>/dev/null; then
    write_server_quack_sql
    echo "✓ server quack SQL ready — loopback + tailscale_serve_local(:${QUACK_PORT})"
  fi
  if [[ "${COMPOSE_REFRESH_CLIENT_SQL:-}" == "1" ]] \
    || [[ ! -f "$WORK/client_session.sql" ]] \
    || [[ ! -f "$WORK/client_init.sql" ]] \
    || [[ -f "$WORK/client_demo.sql" && ! -f "$WORK/client_quack.sql" ]] \
    || { [[ -f "$WORK/client_quack.sql" ]] && grep -q 'NOT EXISTS' "$WORK/client_quack.sql"; } \
    || { [[ -f "$WORK/client_init.sql" ]] && ! grep -q "${CLIENT_STATE_DIR}" "$WORK/client_init.sql"; } \
    || { [[ -f "$WORK/client_quack.sql" ]] && grep -qE "quack:100\.64\." "$WORK/client_quack.sql"; } \
    || { [[ -f "$WORK/client_session.sql" ]] && ! grep -q 'tailscale_ping' "$WORK/client_session.sql"; } \
    || { [[ -f "$WORK/client_session.sql" ]] && ! grep -q 'quack_query' "$WORK/client_session.sql"; } \
    || { [[ -f "$WORK/client_session.sql" ]] && ! grep -q 'tailscale_quack_proxy' "$WORK/client_session.sql"; }; then
    refresh_client_sql "$AUTHKEY"
    echo "✓ client SQL ready — attach ${ATTACH_URI}"
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

write_server_quack_sql

refresh_client_sql "$AUTHKEY"

echo "✓ Headscale authkey ready — attach URI ${ATTACH_URI}"
