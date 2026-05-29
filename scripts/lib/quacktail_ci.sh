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

  echo "Starting QuackTail server container '$QUACKTAIL_SERVER_CONTAINER' on '$HEADSCALE_DOCKER_NETWORK' ..."
  docker run -d --name "$QUACKTAIL_SERVER_CONTAINER" \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    --network-alias "$hostname" \
    -v "${work_dir}:/work" \
    -v "${duckdb_bin}:/usr/local/bin/duckdb:ro" \
    -e QUACKTAIL_ROLE=server \
    -e QUACKTAIL_WORK=/work \
    -e "QUACK_PORT=${port}" \
    -e "QUACK_TAILNET_TOKEN=${QUACK_TAILNET_TOKEN:-}" \
    "$QUACKTAIL_IMAGE"
}

quacktail_ci_wait_server() {
  local port="${1:-9494}"
  local attempt=0
  echo "Waiting for Quack server in container (port ${port}) ..."
  while (( attempt < 60 )); do
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
      if quacktail_ci_container_http_open "$QUACKTAIL_SERVER_CONTAINER" "$port"; then
        echo "Quack server is ready in container (attempt ${attempt})"
        return 0
      fi
    fi
    if (( attempt % 5 == 0 )); then
      echo "  attempt ${attempt} ..."
      docker logs "$QUACKTAIL_SERVER_CONTAINER" 2>&1 | tail -8 || true
    fi
    sleep 2
  done
  echo "error: Quack server did not become ready" >&2
  quacktail_ci_logs
  return 1
}

quacktail_ci_container_http_open() {
  local container="${1:?container}"
  local port="${2:?port}"
  docker exec "$container" curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null \
    && return 0
  docker exec "$container" curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${port}/quack" 2>/dev/null \
    && return 0
  local code
  code="$(docker exec "$container" curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
  [[ "$code" != "000" ]]
}

# Verify Quack is reachable on the Docker network before client ATTACH.
quacktail_ci_preflight_attach_host() {
  local attach_host="${1:?attach host}"
  local port="${2:?port}"
  echo "Preflight: HTTP to http://${attach_host}:${port}/ from network ${HEADSCALE_DOCKER_NETWORK} ..."
  local code
  code="$(docker run --rm --network "$HEADSCALE_DOCKER_NETWORK" "$QUACKTAIL_IMAGE" \
    curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${attach_host}:${port}/" 2>/dev/null || echo 000)"
  if [[ "$code" == "000" ]]; then
    echo "error: cannot reach Quack at ${attach_host}:${port} on Docker network" >&2
    return 1
  fi
  echo "Preflight ok: HTTP ${code} from ${attach_host}:${port}"
}

quacktail_ci_run_client() {
  local duckdb_bin="${1:?duckdb binary path}"
  local work_dir="${2:?work directory}"
  local port="${3:-9494}"
  local timeout_sec="${4:-${E2E_CLIENT_TIMEOUT_SEC:-120}}"

  quacktail_ci_require_docker
  docker rm -f "$QUACKTAIL_CLIENT_CONTAINER" >/dev/null 2>&1 || true

  echo "Running QuackTail client container (timeout ${timeout_sec}s) ..."
  timeout "$timeout_sec" docker run --name "$QUACKTAIL_CLIENT_CONTAINER" \
    --network "$HEADSCALE_DOCKER_NETWORK" \
    -v "${work_dir}:/work" \
    -v "${duckdb_bin}:/usr/local/bin/duckdb:ro" \
    -e QUACKTAIL_ROLE=client \
    -e QUACKTAIL_WORK=/work \
    -e "QUACK_PORT=${port}" \
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
