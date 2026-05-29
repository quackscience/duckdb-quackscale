#!/usr/bin/env bash
# Headscale helpers for CI.
#
# GitHub Actions: set HEADSCALE_USE_GHA_SERVICE=1 and declare Headscale as a
# workflow service container (localhost:8080). See headscale-e2e.yml.
# Local dev: leave unset — scripts start test/headscale/Dockerfile.ci via docker.
set -euo pipefail

HEADSCALE_IMAGE="${HEADSCALE_IMAGE:-headscale/headscale:0.28.0}"
HEADSCALE_CI_IMAGE="${HEADSCALE_CI_IMAGE:-headscale-ci:local}"
HEADSCALE_CONTAINER="${HEADSCALE_CONTAINER:-quackscale-headscale-ci}"
HEADSCALE_CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://127.0.0.1:8080}"
HEADSCALE_CI_USER="${HEADSCALE_CI_USER:-quackscale-ci}"
HEADSCALE_CONFIG_DIR="${HEADSCALE_CONFIG_DIR:-${HEADSCALE_CI_ROOT:-.}/test/headscale}"
TAILSCALE_IMAGE="${TAILSCALE_IMAGE:-tailscale/tailscale:stable}"

headscale_ci_require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required" >&2
    exit 1
  fi
}

headscale_ci_container_id() {
  if [[ -n "${HEADSCALE_CONTAINER_ID:-}" ]]; then
    echo "$HEADSCALE_CONTAINER_ID"
    return 0
  fi
  local id=""
  id="$(docker ps -q --filter "name=${HEADSCALE_CONTAINER}" | head -1 || true)"
  if [[ -z "$id" && -n "${HEADSCALE_CI_IMAGE:-}" ]]; then
    id="$(docker ps -q --filter "ancestor=${HEADSCALE_CI_IMAGE}" | head -1 || true)"
  fi
  if [[ -z "$id" ]]; then
    id="$(docker ps -q --filter "publish=8080" | head -1 || true)"
  fi
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi
  return 1
}

headscale_ci_exec() {
  headscale_ci_require_docker
  local id
  id="$(headscale_ci_container_id)" || {
    echo "error: Headscale container not found" >&2
    docker ps -a >&2 || true
    return 1
  }
  docker exec "$id" "$@"
}

headscale_ci_logs() {
  echo "::group::Headscale container logs"
  if id="$(headscale_ci_container_id 2>/dev/null)"; then
    docker logs "$id" 2>&1 | tail -100 || true
  else
    docker ps -a >&2 || true
  fi
  echo "::endgroup::"
}

headscale_ci_wait_ready() {
  echo "Waiting for Headscale at ${HEADSCALE_CONTROL_URL}/health ..."
  local attempt=0
  while (( attempt < 60 )); do
    attempt=$((attempt + 1))
    if curl -fsS "${HEADSCALE_CONTROL_URL}/health" >/dev/null 2>&1; then
      headscale_ci_ensure_user
      echo "Headscale is ready."
      return 0
    fi
    sleep 2
  done
  echo "error: Headscale did not become healthy" >&2
  headscale_ci_logs
  return 1
}

headscale_ci_start_local() {
  headscale_ci_require_docker
  echo "Building local Headscale CI image ..."
  docker build -t "$HEADSCALE_CI_IMAGE" -f "$HEADSCALE_CONFIG_DIR/Dockerfile.ci" "$HEADSCALE_CONFIG_DIR"
  docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
  echo "Starting Headscale container ..."
  docker run -d --name "$HEADSCALE_CONTAINER" \
    -p 127.0.0.1:8080:8080 \
    --health-cmd "headscale health" \
    --health-interval 2s \
    --health-timeout 5s \
    --health-retries 15 \
    --health-start-period 5s \
    "$HEADSCALE_CI_IMAGE" serve >/dev/null
  headscale_ci_wait_ready
}

headscale_ci_start() {
  if [[ "${HEADSCALE_USE_GHA_SERVICE:-}" == "1" ]]; then
    headscale_ci_wait_ready
  else
    headscale_ci_start_local
  fi
}

headscale_ci_stop() {
  if [[ "${HEADSCALE_USE_GHA_SERVICE:-}" == "1" ]]; then
    return 0
  fi
  docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
}

headscale_ci_ensure_user() {
  headscale_ci_exec headscale users create "$HEADSCALE_CI_USER" >/dev/null 2>&1 || true
}

headscale_ci_user_id() {
  headscale_ci_ensure_user
  local users_json
  users_json="$(headscale_ci_exec headscale users list -o json)"
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
  authkey_json="$(headscale_ci_exec "${create_cmd[@]}")"
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
    authkey="$(headscale_ci_exec "${plain_cmd[@]}" | awk 'NF {key=$0} END {print key}')"
  fi

  if [[ -z "$authkey" ]]; then
    echo "error: failed to obtain Headscale preauth key" >&2
    headscale_ci_exec headscale users list -o json >&2 || true
    headscale_ci_logs
    return 1
  fi
  printf '%s' "$authkey"
}

headscale_ci_verify_tailscale_client() {
  local authkey="${1:?authkey required}"
  local hostname="${2:-headscale-ci-smoke}"
  local state_dir
  state_dir="$(mktemp -d)"

  echo "Verifying Headscale with Tailscale client ($TAILSCALE_IMAGE) ..."
  docker pull -q "$TAILSCALE_IMAGE" >/dev/null

  set +e
  docker run --rm \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --network=host \
    -v "$state_dir:/var/lib/tailscale" \
    -e TS_AUTHKEY="$authkey" \
    -e TS_STATE_DIR=/var/lib/tailscale \
    -e "TS_EXTRA_ARGS=--login-server=${HEADSCALE_CONTROL_URL} --hostname=${hostname} --reset --accept-routes" \
    "$TAILSCALE_IMAGE" \
    tailscale status
  local rc=$?
  set -e
  rm -rf "$state_dir"

  if (( rc != 0 )); then
    echo "error: Tailscale client could not join Headscale (exit $rc)" >&2
    headscale_ci_logs
    headscale_ci_exec headscale nodes list >&2 || true
    return 1
  fi

  echo "Tailscale client joined Headscale successfully."
  headscale_ci_exec headscale nodes list || true
}

headscale_ci_node_ipv4() {
  local hostname="${1:?node hostname}"
  local attempt=0
  while (( attempt < 90 )); do
    attempt=$((attempt + 1))
    local nodes_json ip
    nodes_json="$(headscale_ci_exec headscale nodes list -o json 2>/dev/null || true)"
    if [[ -z "$nodes_json" || "$nodes_json" == "null" ]]; then
      sleep 2
      continue
    fi
    ip="$(
      TARGET_HOST="$hostname" NODES_JSON="$nodes_json" python3 - <<'PY'
import json, os, sys

def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("nodes", "Nodes"):
            if key in value and isinstance(value[key], list):
                return value[key]
        return [value]
    return []

def field(obj, *names):
    for name in names:
        if isinstance(obj, dict) and name in obj and obj[name] is not None:
            return obj[name]
    return None

def node_names(node):
    names = []
    for key in ("name", "Name", "givenName", "given_name", "hostname", "Hostname"):
        value = field(node, key)
        if value:
            names.append(str(value))
    return names

def node_ipv4(node):
    addrs = field(node, "ipAddresses", "ip_addresses", "addresses", "Addresses") or []
    if isinstance(addrs, str):
        addrs = [addrs]
    for addr in addrs:
        addr = str(addr)
        if addr and ":" not in addr:
            return addr
    return ""

target = os.environ["TARGET_HOST"]
for node in as_list(json.loads(os.environ["NODES_JSON"])):
    names = node_names(node)
    if target in names or any(n.startswith(target + ".") for n in names):
        ip = node_ipv4(node)
        if ip:
            print(ip)
            sys.exit(0)
sys.exit(1)
PY
    )" || true
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    if (( attempt % 10 == 0 )); then
      echo "  still waiting for Headscale node '$hostname' (attempt $attempt)..." >&2
    fi
    sleep 2
  done
  echo "error: no tailnet IPv4 found for node '$hostname'" >&2
  headscale_ci_exec headscale nodes list >&2 || true
  headscale_ci_logs
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
