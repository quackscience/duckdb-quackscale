#!/usr/bin/env bash
# Headscale helpers for CI — official container only, no custom images.
# https://headscale.net/stable/setup/install/container/
#
# Starts docker.io/headscale/headscale on network "quacktail-ci" with hostname alias
# "headscale". Native processes on the runner reach it via /etc/hosts → 127.0.0.1:8080.
# Other containers (Tailscale verify) join quacktail-ci and use http://headscale:8080.
set -euo pipefail

HEADSCALE_IMAGE="${HEADSCALE_IMAGE:-docker.io/headscale/headscale:0.28.0}"
HEADSCALE_CONTAINER="${HEADSCALE_CONTAINER:-headscale}"
HEADSCALE_DOCKER_NETWORK="${HEADSCALE_DOCKER_NETWORK:-quacktail-ci}"
HEADSCALE_HOST="${HEADSCALE_HOST:-headscale}"
HEADSCALE_CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://${HEADSCALE_HOST}:8080}"
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
  docker ps -q --filter "name=^/${HEADSCALE_CONTAINER}$" | head -1
}

headscale_ci_exec() {
  headscale_ci_require_docker
  local id
  id="$(headscale_ci_container_id)" || {
    echo "error: Headscale container '$HEADSCALE_CONTAINER' not running" >&2
    docker ps -a >&2 || true
    return 1
  }
  docker exec "$id" "$@"
}

headscale_ci_logs() {
  echo "::group::Headscale container logs"
  if docker ps -a --filter "name=^/${HEADSCALE_CONTAINER}$" --format '{{.Names}}' | grep -qx "$HEADSCALE_CONTAINER"; then
    docker logs "$HEADSCALE_CONTAINER" 2>&1 | tail -100 || true
  fi
  echo "::endgroup::"
}

# Runner processes use hostname "headscale" → localhost (published port 8080).
headscale_ci_install_runner_hosts() {
  if getent hosts "$HEADSCALE_HOST" >/dev/null 2>&1; then
    echo "Runner resolves ${HEADSCALE_HOST}: $(getent hosts "$HEADSCALE_HOST" | head -1)"
    return 0
  fi
  echo "127.0.0.1 ${HEADSCALE_HOST}" | sudo tee -a /etc/hosts
}

headscale_ci_wait_ready() {
  headscale_ci_install_runner_hosts
  echo "Waiting for Headscale at ${HEADSCALE_CONTROL_URL}/health ..."
  local attempt=0
  while (( attempt < 60 )); do
    attempt=$((attempt + 1))
    if response="$(curl -fsS "${HEADSCALE_CONTROL_URL}/health" 2>/dev/null)"; then
      echo "Headscale health: $response"
      headscale_ci_ensure_user
      echo "Headscale is ready."
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      echo "  attempt $attempt (health check) ..."
      curl -v "${HEADSCALE_CONTROL_URL}/health" || true
      docker inspect --format='health={{.State.Health.Status}}' "$HEADSCALE_CONTAINER" 2>/dev/null || true
    fi
    sleep 2
  done
  echo "error: Headscale did not become healthy" >&2
  headscale_ci_logs
  return 1
}

headscale_ci_start() {
  headscale_ci_require_docker
  local data_dir="${1:?data dir required}"
  mkdir -p "$data_dir"

  docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
  docker network inspect "$HEADSCALE_DOCKER_NETWORK" >/dev/null 2>&1 \
    || docker network create "$HEADSCALE_DOCKER_NETWORK" >/dev/null

  echo "Starting Headscale ($HEADSCALE_IMAGE) as '$HEADSCALE_CONTAINER' on network '$HEADSCALE_DOCKER_NETWORK' ..."
  docker pull -q "$HEADSCALE_IMAGE" >/dev/null

  docker run -d --name "$HEADSCALE_CONTAINER" \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    --network-alias "$HEADSCALE_HOST" \
    --read-only \
    --tmpfs /var/run/headscale \
    -v "$HEADSCALE_CONFIG_DIR/config-ci.yaml:/etc/headscale/config.yaml:ro" \
    -v "$HEADSCALE_CONFIG_DIR/policy.hujson:/etc/headscale/policy.hujson:ro" \
    -v "$data_dir:/var/lib/headscale" \
    -p 127.0.0.1:8080:8080 \
    --health-cmd "headscale health" \
    --health-interval 5s \
    --health-timeout 5s \
    --health-retries 12 \
    --health-start-period 10s \
    "$HEADSCALE_IMAGE" \
    serve

  headscale_ci_wait_ready
}

headscale_ci_stop() {
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
    headscale_ci_logs
    return 1
  fi
  printf '%s' "$authkey"
}

headscale_ci_verify_tailscale_client() {
  local authkey="${1:?authkey required}"
  local hostname="${2:-headscale-ci-smoke}"
  local state_dir container attempt rc=1
  state_dir="$(mktemp -d)"
  container="tailscale-verify-$$"

  echo "Verifying Headscale with Tailscale client on network '$HEADSCALE_DOCKER_NETWORK' ..."
  docker pull -q "$TAILSCALE_IMAGE" >/dev/null

  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run -d --name "$container" \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    -v "$state_dir:/var/lib/tailscale" \
    -e TS_AUTHKEY="$authkey" \
    -e TS_STATE_DIR=/var/lib/tailscale \
    -e "TS_EXTRA_ARGS=--login-server=${HEADSCALE_CONTROL_URL} --hostname=${hostname} --reset --accept-routes" \
    "$TAILSCALE_IMAGE" >/dev/null

  set +e
  for attempt in $(seq 1 30); do
    echo "--- tailscale status (attempt $attempt) ---"
    if docker exec "$container" tailscale status; then
      rc=0
      break
    fi
    if (( attempt % 5 == 0 )); then
      echo "  waiting for Tailscale client (attempt $attempt) ..."
      echo "--- tailscale container logs ---"
      docker logs "$container" 2>&1 | tail -20 || true
    fi
    sleep 2
  done
  set -e

  if (( rc != 0 )); then
    echo "error: Tailscale client could not join at ${HEADSCALE_CONTROL_URL}" >&2
    echo "--- tailscale container logs (failure) ---" >&2
    docker logs "$container" 2>&1 | tail -50 >&2 || true
    headscale_ci_logs
    headscale_ci_exec headscale nodes list >&2 || true
  else
    echo "--- tailscale container logs (success) ---"
    docker logs "$container" 2>&1 | tail -30 || true
  fi

  docker rm -f "$container" >/dev/null 2>&1 || true
  # Container runs as root; bind-mounted state files are not owned by the runner user.
  rm -rf "$state_dir" 2>/dev/null || sudo rm -rf "$state_dir" 2>/dev/null || true

  if (( rc != 0 )); then
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
      echo "  still waiting for node '$hostname' (attempt $attempt)..." >&2
    fi
    sleep 2
  done
  echo "error: no tailnet IPv4 for node '$hostname'" >&2
  headscale_ci_exec headscale nodes list >&2 || true
  headscale_ci_logs
  return 1
}

headscale_ci_wait_tcp() {
  local host="${1:?host}"
  local port="${2:?port}"
  local attempt=0
  for _ in $(seq 1 60); do
    attempt=$((attempt + 1))
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
      echo "TCP connect ok: ${host}:${port} (attempt ${attempt})"
      return 0
    fi
    if (( attempt % 10 == 0 )); then
      echo "  still waiting for ${host}:${port} (attempt ${attempt}) ..."
    fi
    sleep 2
  done
  echo "error: $host:$port not reachable" >&2
  return 1
}

# Emit CALL tailscale_up(...) for DuckDB.
# Release binaries built before quackscale 2026-05 require hostname as the first positional
# VARCHAR; set QUACKSCALE_TAILSCALE_UP_NAMED=1 when using a build with named-only hostname.
headscale_ci_sql_tailscale_up() {
  local hostname="$1"
  local state_dir="$2"
  local authkey="$3"
  local control_url="${4:-$HEADSCALE_CONTROL_URL}"

  if [[ "${QUACKSCALE_TAILSCALE_UP_NAMED:-}" == "1" ]]; then
    cat <<SQL
CALL tailscale_up(
    hostname => '${hostname}',
    control_url => '${control_url}',
    authkey => '${authkey}',
    state_dir => '${state_dir}',
    ephemeral => true
);
SQL
  else
    cat <<SQL
CALL tailscale_up(
    '${hostname}',
    control_url => '${control_url}',
    authkey => '${authkey}',
    state_dir => '${state_dir}',
    ephemeral => true
);
SQL
  fi
}
