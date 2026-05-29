#!/usr/bin/env bash
# Install/load quack once on the host for e2e (shared mount into containers).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB="${DUCKDB:?DUCKDB required}"
EXT_DIR="${DUCKDB_EXTENSION_DIRECTORY:-${RUNNER_TEMP:-/tmp}/duckdb_extensions}"

export DUCKDB_EXTENSION_DIRECTORY="$EXT_DIR"
export QUACKTAIL_CI_ROOT="$ROOT"

# shellcheck source=scripts/lib/quacktail_ci.sh
source "$ROOT/scripts/lib/quacktail_ci.sh"

quacktail_ci_docker_ext_setup
quacktail_ci_ensure_quack "$DUCKDB" "$EXT_DIR" install
