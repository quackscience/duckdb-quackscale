#!/usr/bin/env bash
# QuackTail Docker helpers for CI — same network pattern as Headscale / Tailscale verify.
set -euo pipefail

QUACKTAIL_IMAGE="${QUACKTAIL_IMAGE:-quacktail-ci:e2e}"
QUACKTAIL_SERVER_CONTAINER="${QUACKTAIL_SERVER_CONTAINER:-quacktail-server}"
QUACKTAIL_CLIENT_CONTAINER="${QUACKTAIL_CLIENT_CONTAINER:-quacktail-client}"

# shellcheck source=scripts/lib/headscale_ci.sh
source "${QUACKTAIL_CI_ROOT:-.}/scripts/lib/headscale_ci.sh"

quacktail_ci_require_docker() {
  headscale_ci_require_docker
}

# Shared extension cache: mount host DUCKDB_EXTENSION_DIRECTORY into containers.
quacktail_ci_docker_ext_setup() {
  QUACKTAIL_DOCKER_EXT_ARGS=()
  if [[ -n "${DUCKDB_EXTENSION_DIRECTORY:-}" ]]; then
    mkdir -p "$DUCKDB_EXTENSION_DIRECTORY"
    QUACKTAIL_DOCKER_EXT_ARGS+=(
      -v "${DUCKDB_EXTENSION_DIRECTORY}:/duckdb_extensions:rw"
      -e DUCKDB_EXTENSION_DIRECTORY=/duckdb_extensions
    )
  fi
}

# Run DuckDB with SET extension_directory when a shared cache dir is configured.
quacktail_ci_duckdb_sql() {
  local duckdb_bin="${1:?duckdb binary}"
  local ext_dir="${2:-}"
  shift 2
  local sql="$*"
  if [[ -n "$ext_dir" ]]; then
    "$duckdb_bin" :memory: -batch -c "SET extension_directory='${ext_dir}'; ${sql}"
  else
    "$duckdb_bin" :memory: -batch -c "$sql"
  fi
}

# Verify/install quack on the host DuckDB before starting containers.
quacktail_ci_verify_duckdb_quack() {
  local duckdb_bin="${1:?duckdb binary}"
  quacktail_ci_docker_ext_setup
  local ext_dir="${DUCKDB_EXTENSION_DIRECTORY:-}"
  local set_ext=""
  if [[ -n "$ext_dir" ]]; then
    mkdir -p "$ext_dir"
    export DUCKDB_EXTENSION_DIRECTORY="$ext_dir"
    set_ext="SET extension_directory='${ext_dir}';"
    echo "Host extension cache (SET extension_directory): $ext_dir"
  fi
  if ! quacktail_ci_duckdb_sql "$duckdb_bin" "$ext_dir" "LOAD quack; SELECT 1;"; then
    echo "Installing quack on host (core, then core_nightly) ..."
    if ! quacktail_ci_duckdb_sql "$duckdb_bin" "$ext_dir" "INSTALL quack FROM core; LOAD quack; SELECT 1;"; then
      quacktail_ci_duckdb_sql "$duckdb_bin" "$ext_dir" "INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;"
    fi
  fi
  local loaded install_path
  loaded="$("$duckdb_bin" :memory: -batch -csv -noheader -c \
    "${set_ext} LOAD quack; SELECT loaded FROM duckdb_extensions() WHERE extension_name='quack';" \
    | tail -1 | tr -d '[:space:]')"
  install_path="$("$duckdb_bin" :memory: -batch -csv -noheader -c \
    "${set_ext} LOAD quack; SELECT install_path FROM duckdb_extensions() WHERE extension_name='quack';" \
    | tail -1 | tr -d '[:space:]')"
  if [[ "$loaded" != "true" ]]; then
    echo "error: quack did not load on host (loaded=$loaded path=$install_path)" >&2
    exit 1
  fi
  if [[ -n "$ext_dir" && "$install_path" != "${ext_dir}"* ]]; then
    echo "error: quack install_path not under extension_directory ($install_path)" >&2
    exit 1
  fi
  echo "=== quack extension ==="
  "$duckdb_bin" :memory: -batch -echo -c \
    "${set_ext} LOAD quack; SELECT extension_name, loaded, install_path FROM duckdb_extensions() WHERE extension_name='quack';"
}

quacktail_ci_build_image() {
  quacktail_ci_require_docker
  local root="${1:?repo root required}"
  echo "Building QuackTail CI image ($QUACKTAIL_IMAGE) ..."
  docker build -f "$root/test/e2e/Dockerfile.quacktail" -t "$QUACKTAIL_IMAGE" "$root"
}

quacktail_ci_logs() {
  echo "::group::QuackTail server container logs"
  if docker ps -a --filter "name=^/${QUACKTAIL_SERVER_CONTAINER}$" --format '{{.Names}}' \
    | grep -qx "$QUACKTAIL_SERVER_CONTAINER"; then
    docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | tail -200 || true
  else
    echo "(no server container)"
  fi
  echo "::endgroup::"
}

quacktail_ci_server_running() {
  docker ps -q --filter "name=^/${QUACKTAIL_SERVER_CONTAINER}$" | grep -q .
}

quacktail_ci_start_server() {
  local duckdb_bin="${1:?duckdb binary path}"
  local work_dir="${2:?work directory}"
  local hostname="${3:?server hostname}"
  local port="${4:-9494}"

  quacktail_ci_require_docker
  docker rm -f "$QUACKTAIL_SERVER_CONTAINER" >/dev/null 2>&1 || true

  quacktail_ci_docker_ext_setup
  echo "Starting QuackTail server container '$QUACKTAIL_SERVER_CONTAINER' on '$HEADSCALE_DOCKER_NETWORK' ..."
  docker run -d --name "$QUACKTAIL_SERVER_CONTAINER" \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    --network-alias "$hostname" \
    -v "${work_dir}:/work" \
    -v "${duckdb_bin}:/usr/local/bin/duckdb:ro" \
    "${QUACKTAIL_DOCKER_EXT_ARGS[@]}" \
    -e QUACKTAIL_ROLE=server \
    -e QUACKTAIL_WORK=/work \
    -e "QUACK_PORT=${port}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

quacktail_ci_wait_server() {
  local port="${1:-9494}"
  local server_ip="${2:-}"
  local attempt=0
  echo "Waiting for Quack server (tailnet; port ${port}) ..."
  while (( attempt < 10 )); do
    attempt=$((attempt + 1))
    if ! quacktail_ci_server_running; then
      echo "error: server container exited early" >&2
      quacktail_ci_logs
      return 1
    fi
    if docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | grep -q "Failed to bind DuckDB Quack RPC server"; then
      echo "error: quack_serve failed to bind inside container" >&2
      quacktail_ci_logs
      return 1
    fi
    if docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | grep -q "listen_url"; then
      if docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | grep -qE "local_forward|127\.0\.0\.1:${port}"; then
        if [[ -n "$server_ip" ]] && quacktail_ci_container_http_open "$QUACKTAIL_SERVER_CONTAINER" "$port" "$server_ip"; then
          echo "Quack reachable on server own tailnet ${server_ip}:${port} (attempt ${attempt}; not cross-node)"
          return 0
        fi
      fi
      if quacktail_ci_container_http_open "$QUACKTAIL_SERVER_CONTAINER" "$port" "127.0.0.1"; then
        echo "Quack listening locally; waiting for tailscale serve on ${server_ip:-tailnet} ..."
      fi
    fi
    if (( attempt % 5 == 0 )); then
      echo "  attempt ${attempt} ..."
      docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | tail -8 || true
    fi
    sleep 1
  done
  echo "error: Quack server did not become ready" >&2
  quacktail_ci_logs
  return 1
}

quacktail_ci_container_http_open() {
  local container="${1:?container}"
  local port="${2:?port}"
  local host="${3:-127.0.0.1}"
  docker exec "$container" curl -fsS -m 3 -o /dev/null "http://${host}:${port}/" 2>/dev/null \
    && return 0
  docker exec "$container" curl -fsS -m 3 -o /dev/null "http://${host}:${port}/quack" 2>/dev/null \
    && return 0
  local code
  code="$(docker exec "$container" curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://${host}:${port}/" 2>/dev/null || echo 000)"
  [[ "$code" != "000" ]]
}

quacktail_ci_run_client() {
  local duckdb_bin="${1:?duckdb binary path}"
  local work_dir="${2:?work directory}"
  local port="${3:-9494}"
  local timeout_sec="${4:-${E2E_CLIENT_TIMEOUT_SEC:-30}}"

  quacktail_ci_require_docker
  docker rm -f "$QUACKTAIL_CLIENT_CONTAINER" >/dev/null 2>&1 || true

  local server_host="${E2E_SERVER_HOST:-quacktail-server}"
  local server_ip="${E2E_SERVER_IP:?E2E_SERVER_IP must be set}"

  quacktail_ci_docker_ext_setup
  echo "Running QuackTail client container (timeout ${timeout_sec}s) ..."
  echo "Client /etc/hosts: ${server_host} -> ${server_ip}"
  timeout "$timeout_sec" docker run --name "$QUACKTAIL_CLIENT_CONTAINER" \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    --add-host "${server_host}:${server_ip}" \
    -v "${work_dir}:/work" \
    -v "${duckdb_bin}:/usr/local/bin/duckdb:ro" \
    "${QUACKTAIL_DOCKER_EXT_ARGS[@]}" \
    -e QUACKTAIL_ROLE=client \
    -e QUACKTAIL_WORK=/work \
    -e "QUACK_PORT=${port}" \
    -e "E2E_SERVER_IP=${server_ip}" \
    -e "E2E_SERVER_HOST=${server_host}" \
    -e "E2E_CLIENT_MESH_WAIT_SEC=${E2E_CLIENT_MESH_WAIT_SEC:-3}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

quacktail_ci_client_logs() {
  echo "::group::QuackTail client container logs"
  if docker ps -a --filter "name=^/${QUACKTAIL_CLIENT_CONTAINER}$" --format '{{.Names}}' \
    | grep -qx "$QUACKTAIL_CLIENT_CONTAINER"; then
    docker logs "$QUACKTAIL_CLIENT_CONTAINER" 2>&1 | tail -200 || true
  else
    echo "(no client container)"
  fi
  echo "::endgroup::"
}

quacktail_ci_stop() {
  docker rm -f "$QUACKTAIL_SERVER_CONTAINER" "$QUACKTAIL_CLIENT_CONTAINER" >/dev/null 2>&1 || true
}
