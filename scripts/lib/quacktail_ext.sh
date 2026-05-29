#!/usr/bin/env bash
# Shared quack extension install/load for CI (host + containers).
# DuckDB ignores DUCKDB_EXTENSION_DIRECTORY; always use SET extension_directory in SQL.
set -euo pipefail

quacktail_ext_sql_set() {
  local ext_dir="${1:?extension directory required}"
  echo "SET extension_directory='${ext_dir}';"
}

quacktail_ext_container_dir() {
  echo "${QUACKTAIL_CONTAINER_EXT_DIR:-/duckdb_extensions}"
}

# True when host:port accepts Quack HTTP POST (same path ATTACH uses).
quacktail_quack_endpoint_ready() {
  local host="${1:?host}"
  local port="${2:?port}"
  local token="${3:-}"
  local curl_args=(-sS -m 5 -o /dev/null -w '%{http_code}' -X POST
    -H 'Content-Type: application/json'
    -d '{}'
    "http://${host}:${port}/quack")
  if [[ -n "$token" ]]; then
    curl_args=(-sS -m 5 -o /dev/null -w '%{http_code}' -X POST
      -H "Authorization: Bearer ${token}"
      -H 'Content-Type: application/json'
      -d '{}'
      "http://${host}:${port}/quack")
  fi
  local code
  code="$(curl "${curl_args[@]}" 2>/dev/null || echo 000)"
  if [[ "$code" != "000" ]]; then
    return 0
  fi
  # Fallback: raw TCP open (Serve forwards all TCP to loopback Quack).
  timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

quacktail_ext_verify_artifact() {
  local install_path="${1:?install path}"
  if [[ -f "$install_path" ]]; then
    return 0
  fi
  echo "error: quack extension file missing on disk: $install_path" >&2
  return 1
}

# Poll until Quack POST/TCP gate passes (cross-node or self-reach). Logs go to stderr.
quacktail_wait_quack_endpoint() {
  local host="${1:?host}"
  local port="${2:?port}"
  local token="${3:-}"
  local label="${4:-Quack endpoint}"
  local attempts="${5:-${E2E_CROSS_NODE_GATE_ATTEMPTS:-60}}"
  local poll_sec="${6:-${E2E_CROSS_NODE_POLL_SEC:-2}}"
  local i

  echo "Waiting for ${label}: http://${host}:${port}/quack (up to ${attempts} attempts) ..." >&2
  for (( i = 1; i <= attempts; i++ )); do
    if quacktail_quack_endpoint_ready "$host" "$port" "$token"; then
      echo "ok: ${label} reachable on attempt ${i} (http://${host}:${port}/quack)" >&2
      return 0
    fi
    echo "  [${i}/${attempts}] ${label} not ready yet" >&2
    sleep "$poll_sec"
  done
  echo "error: ${label} never became reachable: http://${host}:${port}/quack" >&2
  return 1
}

# mode: install (host — install if missing) | load_only (container — reuse mounted cache)
quacktail_ci_ensure_quack() {
  local duckdb_bin="${1:?duckdb binary}"
  local ext_dir="${2:-}"
  local mode="${3:-install}"

  if [[ -z "$ext_dir" ]]; then
    ext_dir="$(quacktail_ext_container_dir)"
  fi
  mkdir -p "$ext_dir"

  local set_ext
  set_ext="$(quacktail_ext_sql_set "$ext_dir")"

  if [[ "$mode" == "load_only" ]]; then
    if ! "$duckdb_bin" :memory: -batch -c "${set_ext} LOAD quack; SELECT 1;" >/dev/null; then
      echo "error: quack not available at ${ext_dir} (host must install before containers start)" >&2
      return 1
    fi
  elif ! "$duckdb_bin" :memory: -batch -c "${set_ext} LOAD quack; SELECT 1;" >/dev/null; then
    echo "Installing quack (core, then core_nightly) into ${ext_dir} ..."
    if ! "$duckdb_bin" :memory: -batch -c "${set_ext} INSTALL quack FROM core; LOAD quack; SELECT 1;"; then
      "$duckdb_bin" :memory: -batch -c "${set_ext} INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;"
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
    echo "error: quack failed to load (loaded=$loaded path=$install_path)" >&2
    return 1
  fi
  if [[ "$install_path" != "${ext_dir}"* ]]; then
    echo "error: quack install_path not under extension_directory ($install_path)" >&2
    return 1
  fi
  quacktail_ext_verify_artifact "$install_path"

  if [[ "${QUACKTAIL_QUIET:-}" == "1" ]]; then
    return 0
  fi

  echo "=== quack extension (${mode}) ==="
  "$duckdb_bin" :memory: -batch -echo -c \
    "${set_ext} LOAD quack; SELECT extension_name, loaded, install_path FROM duckdb_extensions() WHERE extension_name='quack';"
}
