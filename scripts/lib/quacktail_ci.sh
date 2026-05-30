#!/usr/bin/env bash
# QuackTail Docker helpers for CI — same network pattern as Headscale / Tailscale verify.
set -euo pipefail

QUACKTAIL_IMAGE="${QUACKTAIL_IMAGE:-quacktail-ci:e2e}"
QUACKTAIL_SERVER_CONTAINER="${QUACKTAIL_SERVER_CONTAINER:-quacktail-server}"
QUACKTAIL_CLIENT_CONTAINER="${QUACKTAIL_CLIENT_CONTAINER:-quacktail-client}"

# shellcheck source=scripts/lib/headscale_ci.sh
source "${QUACKTAIL_CI_ROOT:-.}/scripts/lib/headscale_ci.sh"
# shellcheck source=scripts/lib/quacktail_ext.sh
source "${QUACKTAIL_CI_ROOT:-.}/scripts/lib/quacktail_ext.sh"

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
    "$duckdb_bin" :memory: -batch -c "$(quacktail_ext_sql_set "$ext_dir") ${sql}"
  else
    "$duckdb_bin" :memory: -batch -c "$sql"
  fi
}

# Host-only: install quack into DUCKDB_EXTENSION_DIRECTORY (containers use load_only).
quacktail_ci_verify_duckdb_quack() {
  local duckdb_bin="${1:?duckdb binary}"
  quacktail_ci_docker_ext_setup
  local ext_dir="${DUCKDB_EXTENSION_DIRECTORY:-}"
  if [[ -n "$ext_dir" ]]; then
    mkdir -p "$ext_dir"
    export DUCKDB_EXTENSION_DIRECTORY="$ext_dir"
    echo "Host extension cache: $ext_dir"
  fi
  quacktail_ci_ensure_quack "$duckdb_bin" "${ext_dir:-$(quacktail_ext_container_dir)}" install
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
    docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | tail -500 || true
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
    -e QUACKTAIL_QUIET=1 \
    -e QUACKTAIL_ENABLE_DUCKLAKE="${QUACKTAIL_ENABLE_DUCKLAKE:-1}" \
    -e "SERVER_HOST=${hostname}" \
    -e "HEADSCALE_CONTROL_URL=${HEADSCALE_CONTROL_URL:-http://headscale:8080}" \
    -e "QUACKTAIL_LAKE_NAME=${QUACKTAIL_LAKE_NAME:-lake}" \
    -e "QUACKTAIL_LAKE_METADATA=${QUACKTAIL_LAKE_METADATA:-/work/ducklake/metadata/inventory.ducklake}" \
    -e "QUACKTAIL_LAKE_DATA_PATH=${QUACKTAIL_LAKE_DATA_PATH:-/work/ducklake/data}" \
    -e "QUACK_PORT=${port}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

# Local readiness: server container alive and /work/quack_ready present (no curl).
quacktail_ci_wait_server_local() {
  local attempt=0
  echo "Waiting for server quack_ready marker ..."
  while (( attempt < 120 )); do
    attempt=$((attempt + 1))
    if ! quacktail_ci_server_running; then
      echo "error: server container exited early" >&2
      quacktail_ci_logs
      return 1
    fi
    if docker exec "$QUACKTAIL_SERVER_CONTAINER" test -f /work/quack_ready 2>/dev/null; then
      echo "Server quack_ready (attempt ${attempt})"
      return 0
    fi
    if docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | grep -qE 'IOException|Invalid Input|Failed to bind'; then
      echo "error: server init failed (see container logs)" >&2
      quacktail_ci_logs
      return 1
    fi
    if (( attempt % 10 == 0 )); then
      echo "  attempt ${attempt} ..."
    fi
    sleep 1
  done
  echo "error: server quack_ready not set" >&2
  quacktail_ci_logs
  return 1
}

quacktail_ci_wait_server() {
  quacktail_ci_wait_server_local "${1:-9494}"
}

quacktail_ci_start_client() {
  local duckdb_bin="${1:?duckdb binary path}"
  local work_dir="${2:?work directory}"
  local port="${3:-9494}"

  quacktail_ci_require_docker
  docker rm -f "$QUACKTAIL_CLIENT_CONTAINER" >/dev/null 2>&1 || true

  local server_host="${E2E_SERVER_HOST:-quacktail-server}"
  local server_ip="${E2E_SERVER_IP:?E2E_SERVER_IP must be set}"
  local attach_host="${E2E_QUACK_ATTACH_HOST:-hostname}"
  local docker_host_args=()

  if [[ "$attach_host" == "hostname" || "$attach_host" == "magicdns" ]]; then
    docker_host_args=(--add-host "${server_host}:${server_ip}")
    echo "Client /etc/hosts: ${server_host} -> ${server_ip}"
  else
    echo "Client ATTACH via tailnet IP ${server_ip}"
  fi

  quacktail_ci_docker_ext_setup
  echo "Starting client container '$QUACKTAIL_CLIENT_CONTAINER' (server still running) ..."
  docker run -d --name "$QUACKTAIL_CLIENT_CONTAINER" \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    "${docker_host_args[@]}" \
    -v "${work_dir}:/work" \
    -v "${duckdb_bin}:/usr/local/bin/duckdb:ro" \
    "${QUACKTAIL_DOCKER_EXT_ARGS[@]}" \
    -e QUACKTAIL_ROLE=client \
    -e QUACKTAIL_WORK=/work \
    -e QUACKTAIL_QUIET=1 \
    -e QUACKTAIL_ENABLE_DUCKLAKE="${QUACKTAIL_ENABLE_DUCKLAKE:-1}" \
    -e QUACKTAIL_REQUIRE_ATTACH_DUCKLAKE="${QUACKTAIL_REQUIRE_ATTACH_DUCKLAKE:-1}" \
    -e "SERVER_HOST=${server_host}" \
    -e "CLIENT_HOST=${E2E_CLIENT_HOST:-quacktail-client}" \
    -e "HEADSCALE_CONTROL_URL=${HEADSCALE_CONTROL_URL:-http://headscale:8080}" \
    -e "QUACK_FORWARD_LOCAL_PORT=${E2E_FORWARD_LOCAL_PORT:-19494}" \
    -e "QUACK_PORT=${port}" \
    -e "E2E_SERVER_IP=${server_ip}" \
    -e "E2E_SERVER_HOST=${server_host}" \
    -e "QUACKTAIL_ATTACH_URI=${QUACKTAIL_ATTACH_URI:-quack:${server_ip}:${port}}" \
    -e "QUACKTAIL_CLIENT_ATTEMPTS=${QUACKTAIL_CLIENT_ATTEMPTS:-15}" \
    -e "QUACKTAIL_CLIENT_POLL_SEC=${QUACKTAIL_CLIENT_POLL_SEC:-2}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    -e "QUACK_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

quacktail_ci_wait_client() {
  local timeout_sec="${1:-${E2E_CLIENT_TIMEOUT_SEC:-60}}"
  local exit_code=0
  if ! exit_code="$(timeout "$timeout_sec" docker wait "$QUACKTAIL_CLIENT_CONTAINER" 2>/dev/null)"; then
    local rc=$?
    if (( rc == 124 )); then
      docker rm -f "$QUACKTAIL_CLIENT_CONTAINER" >/dev/null 2>&1 || true
      return 124
    fi
    return "$rc"
  fi
  return "$exit_code"
}

# Foreground client (local debugging).
quacktail_ci_run_client() {
  local duckdb_bin="${1:?duckdb binary path}"
  local work_dir="${2:?work directory}"
  local port="${3:-9494}"
  local timeout_sec="${4:-${E2E_CLIENT_TIMEOUT_SEC:-180}}"
  quacktail_ci_start_client "$duckdb_bin" "$work_dir" "$port"
  quacktail_ci_wait_client "$timeout_sec"
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
