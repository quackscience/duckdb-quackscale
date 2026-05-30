#!/usr/bin/env bash
# Verify required quackscale functions are present in the container image.
set -euo pipefail

DUCKDB_BIN="${DUCKDB_BIN:-/usr/local/bin/duckdb}"
EXT_DIR="${DUCKDB_EXTENSION_DIRECTORY:-/duckdb_extensions}"

# shellcheck source=/dev/null
source /usr/local/lib/quacktail_ext.sh

require_fn() {
  local fn="$1"
  if ! quacktail_has_quackscale_function "$fn"; then
    echo "error: quackscale missing required function: ${fn}" >&2
    echo "extension_directory=${EXT_DIR}" >&2
    ls -la "$EXT_DIR" "$EXT_DIR/quackscale" 2>/dev/null >&2 || true
    echo "registered quackscale functions:" >&2
    quacktail_list_quackscale_functions >&2 || true
    [[ -f /etc/quacktail/build-info ]] && cat /etc/quacktail/build-info >&2
    exit 1
  fi
}

require_fn attach_ducklake
require_fn tailscale_down
require_fn tailscale_quack_forward
echo "ok: quackscale image verify (attach_ducklake, tailscale_down, tailscale_quack_forward)"
