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
    -e "QUACK_PORT=${port}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

# Local readiness: container alive, Quack bound on loopback. Not cross-node proof.
quacktail_ci_wait_server_local() {
  local port="${1:-9494}"
  local attempt=0
  echo "Waiting for Quack loopback bind (port ${port}) ..."
  while (( attempt < 30 )); do
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
      if quacktail_ci_container_http_open "$QUACKTAIL_SERVER_CONTAINER" "$port" "127.0.0.1"; then
        echo "Quack listening on loopback (attempt ${attempt})"
        return 0
      fi
    fi
    if (( attempt % 5 == 0 )); then
      echo "  attempt ${attempt} ..."
      docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | tail -8 || true
    fi
    sleep 1
  done
  echo "error: Quack server did not bind on loopback" >&2
  quacktail_ci_logs
  return 1
}

# Poll from inside the server container until its own tailnet IP:port accepts Quack POST.
quacktail_ci_wait_server_published() {
  local port="${1:-9494}"
  local server_ip="${2:?server tailnet IP required}"
  local token="${3:-${QUACK_TAILNET_TOKEN:-}}"
  local attempts="${4:-${E2E_SERVER_PUBLISH_ATTEMPTS:-60}}"
  local poll_sec="${5:-${E2E_SERVER_PUBLISH_POLL_SEC:-2}}"
  local i

  echo "Polling server Quack POST on tailnet ${server_ip}:${port} (up to ${attempts} attempts) ..."
  for (( i = 1; i <= attempts; i++ )); do
    if quacktail_ci_container_http_open "$QUACKTAIL_SERVER_CONTAINER" "$port" "$server_ip" "$token"; then
      echo "ok: server published Quack endpoint at ${server_ip}:${port} (attempt ${i})"
      return 0
    fi
    echo "  publish attempt ${i}/${attempts} ..."
    sleep "$poll_sec"
  done
  echo "error: server Quack endpoint not reachable at ${server_ip}:${port}" >&2
  quacktail_ci_logs
  return 1
}

# Back-compat alias: local bind only (cross-node gate runs in client).
quacktail_ci_wait_server() {
  local port="${1:-9494}"
  local server_ip="${2:-}"
  quacktail_ci_wait_server_local "$port"
  if [[ -n "$server_ip" ]]; then
    echo "  (server tailnet IP ${server_ip} — cross-node proof is client-side only)"
  fi
}

quacktail_ci_container_http_open() {
  local container="${1:?container}"
  local port="${2:?port}"
  local host="${3:-127.0.0.1}"
  local token="${4:-}"
  local code
  if [[ -n "$token" ]]; then
    code="$(docker exec "$container" curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' \
      -d '{}' \
      "http://${host}:${port}/quack" 2>/dev/null || echo 000)"
  else
    code="$(docker exec "$container" curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' \
      -d '{}' \
      "http://${host}:${port}/quack" 2>/dev/null || echo 000)"
  fi
  [[ "$code" != "000" ]]
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
    -e "QUACK_PORT=${port}" \
    -e "E2E_SERVER_IP=${server_ip}" \
    -e "E2E_SERVER_HOST=${server_host}" \
    -e "QUACKTAIL_ATTACH_URI=${QUACKTAIL_ATTACH_URI:-quack:${server_ip}:${port}}" \
    -e "E2E_CROSS_NODE_GATE_ATTEMPTS=${E2E_CROSS_NODE_GATE_ATTEMPTS:-60}" \
    -e "E2E_CROSS_NODE_POLL_SEC=${E2E_CROSS_NODE_POLL_SEC:-2}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    -e "QUACK_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

quacktail_ci_wait_client() {
  local timeout_sec="${1:-${E2E_CLIENT_TIMEOUT_SEC:-180}}"
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
