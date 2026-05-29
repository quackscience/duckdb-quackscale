#!/usr/bin/env bash
# Shared helpers for Headscale CI scripts.
set -euo pipefail

HEADSCALE_IMAGE="${HEADSCALE_IMAGE:-headscale/headscale:0.28.0}"
HEADSCALE_CONTAINER="${HEADSCALE_CONTAINER:-quackscale-headscale-ci}"
HEADSCALE_CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://127.0.0.1:8080}"
HEADSCALE_CI_USER="${HEADSCALE_CI_USER:-quackscale-ci}"
HEADSCALE_CONFIG_DIR="${HEADSCALE_CONFIG_DIR:-${HEADSCALE_CI_ROOT:-.}/test/headscale}"

headscale_ci_require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required" >&2
    exit 1
  fi
}

headscale_ci_start() {
  headscale_ci_require_docker
  local data_dir="${1:?data dir required}"
  echo "Starting Headscale ($HEADSCALE_IMAGE)..."
  docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$HEADSCALE_CONTAINER" \
    -p 127.0.0.1:8080:8080 \
    -v "$HEADSCALE_CONFIG_DIR/config-ci.yaml:/etc/headscale/config.yaml:ro" \
    -v "$HEADSCALE_CONFIG_DIR/policy.hujson:/etc/headscale/policy.hujson:ro" \
    -v "$data_dir:/var/lib/headscale" \
    "$HEADSCALE_IMAGE" serve >/dev/null

  echo "Waiting for Headscale health at $HEADSCALE_CONTROL_URL/health ..."
  for _ in $(seq 1 60); do
    if curl -sf "$HEADSCALE_CONTROL_URL/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "error: Headscale did not become healthy" >&2
  docker logs "$HEADSCALE_CONTAINER" 2>&1 | tail -50 >&2 || true
  return 1
}

headscale_ci_stop() {
  docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
}

headscale_ci_ensure_user() {
  docker exec "$HEADSCALE_CONTAINER" headscale users create "$HEADSCALE_CI_USER" >/dev/null 2>&1 || true
}

headscale_ci_user_id() {
  headscale_ci_ensure_user
  local users_json
  users_json="$(docker exec "$HEADSCALE_CONTAINER" headscale users list -o json)"
  HEADSCALE_CI_USER="$HEADSCALE_CI_USER" USERS_JSON="$users_json" python3 - <<'PY'
import json, os, sys

def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("users", "Users", "nodes", "Nodes", "preAuthKeys", "pre_auth_keys"):
            if key in value and isinstance(value[key], list):
                return value[key]
        return [value]
    return []

def field(obj, *names):
    for name in names:
        if name in obj and obj[name] is not None:
            return obj[name]
    return None

target = os.environ["HEADSCALE_CI_USER"]
users = as_list(json.loads(os.environ["USERS_JSON"]))
for user in users:
    name = field(user, "name", "Name", "username", "Username")
    if name == target:
        print(field(user, "id", "Id", "ID"))
        sys.exit(0)
if users:
    print(field(users[0], "id", "Id", "ID"))
    sys.exit(0)
sys.exit(1)
PY
}

headscale_ci_create_authkey() {
  local user_id=""
  user_id="$(headscale_ci_user_id 2>/dev/null || true)"

  local -a create_cmd=(headscale preauthkeys create --reusable --expiration 24h -o json)
  if [[ -n "$user_id" ]]; then
    create_cmd+=(--user "$user_id")
  fi

  local authkey_json authkey
  authkey_json="$(docker exec "$HEADSCALE_CONTAINER" "${create_cmd[@]}")"
  authkey="$(
    AUTHKEY_JSON="$authkey_json" python3 - <<'PY'
import json, os, sys

def field(obj, *names):
    for name in names:
        if isinstance(obj, dict) and name in obj and obj[name]:
            return obj[name]
    return None

raw = os.environ.get("AUTHKEY_JSON", "").strip()
if not raw:
    sys.exit(1)
data = json.loads(raw)
key = field(data, "key", "Key")
if not key and isinstance(data, dict):
    nested = field(data, "preAuthKey", "pre_auth_key", "PreAuthKey")
    if isinstance(nested, dict):
        key = field(nested, "key", "Key")
print(key or "")
PY
  )" || true

  if [[ -z "$authkey" ]]; then
    local -a plain_cmd=(headscale preauthkeys create --reusable --expiration 24h)
    if [[ -n "$user_id" ]]; then
      plain_cmd+=(--user "$user_id")
    fi
    authkey="$(docker exec "$HEADSCALE_CONTAINER" "${plain_cmd[@]}" | awk 'NF {key=$0} END {print key}')"
  fi

  if [[ -z "$authkey" ]]; then
    echo "error: failed to obtain Headscale preauth key" >&2
    docker exec "$HEADSCALE_CONTAINER" headscale users list -o json >&2 || true
    return 1
  fi
  printf '%s' "$authkey"
}

headscale_ci_node_ipv4() {
  local hostname="${1:?node hostname}"
  for _ in $(seq 1 60); do
    local nodes_json ip
    nodes_json="$(docker exec "$HEADSCALE_CONTAINER" headscale nodes list -o json)"
    ip="$(
      NODES_JSON="$nodes_json" python3 -c "
import json, os, sys

def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ('nodes', 'Nodes'):
            if key in value and isinstance(value[key], list):
                return value[key]
        return [value]
    return []

def field(obj, *names):
    for name in names:
        if name in obj and obj[name] is not None:
            return obj[name]
    return None

hostname = sys.argv[1]
for node in as_list(json.loads(os.environ['NODES_JSON'])):
    name = field(node, 'givenName', 'given_name', 'name', 'Name') or ''
    if name == hostname or name.startswith(hostname + '.'):
        addrs = field(node, 'ipAddresses', 'ip_addresses', 'addresses', 'Addresses') or []
        if isinstance(addrs, str):
            addrs = [addrs]
        for addr in addrs:
            addr = str(addr)
            if ':' not in addr:
                print(addr)
                sys.exit(0)
sys.exit(1)
" "$hostname" 2>/dev/null || true
    )"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    sleep 2
  done
  echo "error: no tailnet IPv4 found for node '$hostname'" >&2
  docker exec "$HEADSCALE_CONTAINER" headscale nodes list -o json >&2 || true
  return 1
}

headscale_ci_wait_tcp() {
  local host="${1:?host}"
  local port="${2:?port}"
  for _ in $(seq 1 60); do
    if python3 - "$host" "$port" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(2)
try:
    s.connect((host, port))
except OSError:
    sys.exit(1)
else:
    sys.exit(0)
finally:
    s.close()
PY
    then
      return 0
    fi
    sleep 2
  done
  echo "error: $host:$port did not become reachable" >&2
  return 1
}
