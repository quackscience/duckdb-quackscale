#!/usr/bin/env bash
# CI e2e via examples/docker-compose.yml — same flow as the working local demo.
# Uses a release binary (BUILD_FROM_SOURCE=0); no DuckDB compile on the runner.
# Full DuckLake + source build: scripts/ci_compose_e2e.sh (local dev only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLES="$ROOT/examples"
WORK="${E2E_WORK:-${GITHUB_WORKSPACE:-$ROOT}/.e2e-work}"
LOG="$WORK/compose-e2e.log"
mkdir -p "$WORK"

export BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
export QUACKTAIL_RELEASE_TAG="${QUACKTAIL_RELEASE_TAG:-${QUACKTAIL_RELEASE_TAG_DEFAULT:-v1.0.3}}"
export GITHUB_REPO="${GITHUB_REPO:-quackscience/duckdb-quackscale}"
# Basic CI test: Quack over tailnet (matches compose with DuckLake off).
export QUACKTAIL_ENABLE_DUCKLAKE="${QUACKTAIL_ENABLE_DUCKLAKE:-0}"
export QUACKTAIL_REQUIRE_ATTACH_DUCKLAKE="${QUACKTAIL_REQUIRE_ATTACH_DUCKLAKE:-0}"

cd "$EXAMPLES"

cleanup() {
  docker compose logs quacktail-server >"$WORK/server.log" 2>&1 || true
  docker compose down --remove-orphans -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== QuackTail compose e2e (examples/docker-compose.yml) ==="
echo "  commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "  release=${QUACKTAIL_RELEASE_TAG}  BUILD_FROM_SOURCE=${BUILD_FROM_SOURCE}  QUACKTAIL_ENABLE_DUCKLAKE=${QUACKTAIL_ENABLE_DUCKLAKE}"

echo "=== docker compose build quacktail-server quacktail-client ==="
docker compose build quacktail-server quacktail-client

echo "=== docker compose up -d headscale quacktail-server ==="
docker compose up -d --force-recreate headscale quacktail-server

echo "=== docker compose run --rm quacktail-client (waits for server healthy) ==="
: >"$LOG"
set +o pipefail
docker compose --profile test run --rm quacktail-client 2>&1 | tee "$LOG"
CLIENT_RC="${PIPESTATUS[0]}"
set -o pipefail

if (( CLIENT_RC != 0 )); then
  echo "error: quacktail-client exited ${CLIENT_RC}" >&2
  exit 1
fi

grep -q 'PASSED' "$LOG" || {
  echo "error: PASSED row missing from client output" >&2
  exit 1
}
echo "ok: PASSED summary"

grep -qE 'Demo passed|CLIENT_DEMO_DONE' "$LOG" || {
  echo "error: demo completion marker missing from client output" >&2
  exit 1
}
echo "ok: client demo finished cleanly"

if [[ "${QUACKTAIL_ENABLE_DUCKLAKE}" == "1" ]]; then
  grep -q 'LAKE_PASSED' "$LOG" || {
    echo "error: LAKE_PASSED missing (QUACKTAIL_ENABLE_DUCKLAKE=1)" >&2
    exit 1
  }
  grep -q 'attach_ducklake' "$LOG" || {
    echo "error: attach_ducklake path not used" >&2
    exit 1
  }
  echo "ok: DuckLake inventory verified"
else
  grep -q 'seed-from-server' "$LOG" || {
    echo "error: server seed row missing from client output" >&2
    exit 1
  }
  echo "ok: server row via quack ATTACH"
fi

echo "Headscale QuackTail compose e2e passed."
