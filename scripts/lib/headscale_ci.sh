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
  docker exec "$HEADSCALE_CONTAINER" headscale users list -o json \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
users = d.get('users', d if isinstance(d, list) else [])
for u in users:
    if u.get('name') == '${HEADSCALE_CI_USER}':
        print(u['id'])
        sys.exit(0)
if users:
    print(users[0]['id'])
else:
    sys.exit(1)
"
}

headscale_ci_create_authkey() {
  local user_id
  user_id="$(headscale_ci_user_id)"
  local authkey
  authkey="$(
    docker exec "$HEADSCALE_CONTAINER" headscale preauthkeys create \
      --user "$user_id" --reusable --expiration 1h -o json \
      | python3 -c "
import json, sys
d = json.load(sys.stdin)
key = d.get('key') or d.get('preAuthKey', {}).get('key')
if not key and isinstance(d, dict) and 'preAuthKey' in d:
    key = d['preAuthKey'].get('key')
print(key or '')
"
  )"
  if [[ -z "$authkey" ]]; then
    authkey="$(
      docker exec "$HEADSCALE_CONTAINER" headscale preauthkeys create \
        --user "$user_id" --reusable --expiration 1h | awk 'NF {key=$0} END {print key}'
    )"
  fi
  if [[ -z "$authkey" ]]; then
    echo "error: failed to obtain Headscale preauth key" >&2
    return 1
  fi
  printf '%s' "$authkey"
}

headscale_ci_node_ipv4() {
  local hostname="${1:?node hostname}"
  for _ in $(seq 1 60); do
    local ip
    ip="$(
      docker exec "$HEADSCALE_CONTAINER" headscale nodes list -o json \
        | python3 -c "
import json, sys
hostname = sys.argv[1]
d = json.load(sys.stdin)
nodes = d.get('nodes', d if isinstance(d, list) else [])
for n in nodes:
    name = n.get('givenName') or n.get('given_name') or n.get('name') or ''
    if name == hostname or name.startswith(hostname + '.'):
        addrs = n.get('ipAddresses') or n.get('ip_addresses') or n.get('addresses') or []
        for addr in addrs:
            if ':' not in str(addr):
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
  docker exec "$HEADSCALE_CONTAINER" headscale nodes list >&2 || true
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
