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

quacktail_has_quackscale_function() {
  local fn="${1:?function name required}"
  local duckdb_bin="${DUCKDB_BIN:-/usr/local/bin/duckdb}"
  local ext_dir="${DUCKDB_EXTENSION_DIRECTORY:-$(quacktail_ext_container_dir)}"
  local out count
  [[ -x "$duckdb_bin" ]] || return 1
  out="$("$duckdb_bin" :memory: -batch -csv -noheader -c \
    "SET extension_directory='${ext_dir}'; LOAD quackscale; \
     SELECT CAST(COUNT(*) AS VARCHAR) FROM duckdb_functions() WHERE function_name='${fn}';" \
    2>&1)" || true
  count="$(printf '%s\n' "$out" | tail -1 | tr -d '[:space:]')"
  [[ "$count" == "1" ]] && return 0
  out="$("$duckdb_bin" :memory: -batch -csv -noheader -c \
    "LOAD quackscale; SELECT CAST(COUNT(*) AS VARCHAR) FROM duckdb_functions() WHERE function_name='${fn}';" \
    2>&1)" || true
  count="$(printf '%s\n' "$out" | tail -1 | tr -d '[:space:]')"
  [[ "$count" == "1" ]]
}

quacktail_list_quackscale_functions() {
  local duckdb_bin="${DUCKDB_BIN:-/usr/local/bin/duckdb}"
  local ext_dir="${DUCKDB_EXTENSION_DIRECTORY:-$(quacktail_ext_container_dir)}"
  [[ -x "$duckdb_bin" ]] || return 1
  "$duckdb_bin" :memory: -batch -csv -noheader -c \
    "SET extension_directory='${ext_dir}'; LOAD quackscale; \
     SELECT function_name FROM duckdb_functions() \
     WHERE function_name LIKE 'tailscale_%' \
        OR function_name LIKE 'attach_%' \
        OR function_name IN ('quack_uri', 'quack_token', 'quack_discover') \
     ORDER BY 1;"
}

quacktail_ext_verify_artifact() {
  local install_path="${1:?install path}"
  if [[ -f "$install_path" ]]; then
    return 0
  fi
  echo "error: quack extension file missing on disk: $install_path" >&2
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

# Install/load ducklake (core, then core_nightly).
quacktail_ci_ensure_ducklake() {
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
    if ! "$duckdb_bin" :memory: -batch -c "${set_ext} LOAD ducklake; SELECT 1;" >/dev/null; then
      echo "error: ducklake not available at ${ext_dir}" >&2
      return 1
    fi
  elif ! "$duckdb_bin" :memory: -batch -c "${set_ext} LOAD ducklake; SELECT 1;" >/dev/null; then
    echo "Installing ducklake (core, then core_nightly) into ${ext_dir} ..."
    if ! "$duckdb_bin" :memory: -batch -c "${set_ext} INSTALL ducklake FROM core; LOAD ducklake; SELECT 1;"; then
      "$duckdb_bin" :memory: -batch -c "${set_ext} INSTALL ducklake FROM core_nightly; LOAD ducklake; SELECT 1;"
    fi
  fi

  if [[ "${QUACKTAIL_QUIET:-}" == "1" ]]; then
    return 0
  fi

  echo "=== ducklake extension (${mode}) ==="
  "$duckdb_bin" :memory: -batch -echo -c \
    "${set_ext} LOAD ducklake; SELECT extension_name, loaded, install_path FROM duckdb_extensions() WHERE extension_name='ducklake';"
}

quacktail_ci_ensure_demo_extensions() {
  local duckdb_bin="${1:?duckdb binary}"
  local ext_dir="${2:-}"
  local mode="${3:-install}"
  quacktail_ci_ensure_quack "$duckdb_bin" "$ext_dir" "$mode"
  if [[ "${QUACKTAIL_ENABLE_DUCKLAKE:-1}" == "1" ]]; then
    quacktail_ci_ensure_ducklake "$duckdb_bin" "$ext_dir" "$mode"
  fi
}

quacktail_ext_sql_load_demo() {
  local ext_dir="${1:?extension directory required}"
  echo "$(quacktail_ext_sql_set "$ext_dir")"
  echo "LOAD quack;"
  if [[ "${QUACKTAIL_ENABLE_DUCKLAKE:-1}" == "1" ]]; then
    echo "LOAD ducklake;"
  fi
}

# Server init finished: explicit marker and/or quack_serve + tailscale_serve_local output in server.log.
quacktail_server_log_ready() {
  local log="${1:?server.log path required}"
  local port="${2:-${QUACK_PORT:-9494}}"
  local server_host="${3:-${SERVER_HOST:-quacktail-server}}"
  [[ -s "$log" ]] || return 1
  if grep -Fq 'QUACKTAIL_SERVER_READY' "$log" 2>/dev/null; then
    return 0
  fi
  # quack_serve listen_uri + tailscale_serve_local local_forward (no box-drawing dependency).
  grep -Fq "quack:127.0.0.1:${port}" "$log" 2>/dev/null \
    && grep -Fq 'local_forward' "$log" 2>/dev/null \
    && grep -Fq "127.0.0.1:${port}" "$log" 2>/dev/null \
    && grep -Fq "${server_host}" "$log" 2>/dev/null
}
