#!/usr/bin/env bash
# Local/dev only: full compose e2e with SOURCE-built images (examples/docker-compose.yml).
# CI e2e uses release binaries — see .github/workflows/headscale-e2e.yml (workflow_dispatch).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLES="$ROOT/examples"
LOG="${CI_COMPOSE_E2E_LOG:-${RUNNER_TEMP:-/tmp}/quacktail-compose-e2e.log}"

cd "$EXAMPLES"

echo "=== docker compose build (BUILD_FROM_SOURCE=1 — local dev only) ==="
docker compose build quacktail-server quacktail-client

echo "=== verify image ==="
docker compose run --rm --entrypoint /usr/local/bin/quacktail-verify-image.sh quacktail-client

echo "=== start headscale + quacktail-server ==="
docker compose up -d --force-recreate headscale quacktail-server

echo "=== run quacktail-client (profile test) ==="
: >"$LOG"
docker compose --profile test run --rm quacktail-client 2>&1 | tee "$LOG"

grep -q 'LAKE_PASSED' "$LOG" || { echo "error: LAKE_PASSED missing" >&2; exit 1; }
grep -q 'PASSED' "$LOG" || { echo "error: PASSED missing" >&2; exit 1; }
grep -qE 'Demo passed|CLIENT_DEMO_DONE' "$LOG" || { echo "error: demo completion marker missing" >&2; exit 1; }
grep -q 'attach_ducklake' "$LOG" || { echo "error: attach_ducklake path not used" >&2; exit 1; }

echo "ok: compose e2e passed (source build)"
