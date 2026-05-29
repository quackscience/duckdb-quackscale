#!/usr/bin/env bash
# Join Headscale with vanilla tailscale/tailscale, then ping + TCP/HTTP to quacktail-server:9494.
# Isolates tailnet connectivity from DuckDB tsnet / quack ATTACH.
set -euo pipefail

WORK="${QUACKTAIL_WORK:-/work}"
SERVER_HOST="${SERVER_HOST:-quacktail-server}"
QUACK_PORT="${QUACK_PORT:-9494}"
CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://headscale:8080}"
HOSTNAME="${TAILSCALE_PROBE_HOSTNAME:-tailscale-probe}"
MAGIC_FQDN="${SERVER_HOST}.quackscale.test"
AUTHKEY_WAIT_SEC="${TAILSCALE_PROBE_AUTHKEY_WAIT_SEC:-120}"
JOIN_WAIT_SEC="${TAILSCALE_PROBE_JOIN_WAIT_SEC:-60}"

echo "Vanilla Tailscale connectivity probe"
echo "===================================="
echo "→ login-server ${CONTROL_URL}, probe target ${SERVER_HOST}:${QUACK_PORT}"
echo ""

wait_for_authkey() {
  local i
  for ((i = 1; i <= AUTHKEY_WAIT_SEC; i++)); do
    if [[ -s "${WORK}/authkey" ]]; then
      return 0
    fi
    if (( i == 1 || i % 10 == 0 )); then
      echo "→ waiting for ${WORK}/authkey (${i}/${AUTHKEY_WAIT_SEC}s) ..."
    fi
    sleep 1
  done
  echo "error: ${WORK}/authkey not found (is quacktail-server healthy?)" >&2
  return 1
}

resolve_peer_ip() {
  local peer="$1"
  tailscale status 2>/dev/null | grep -F "$peer" | awk '{print $1}' | grep -E '^100\.' | head -1 || true
}

tcp_reachable() {
  local host="$1"
  local port="$2"
  if command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -s --connect-timeout 3 -o /dev/null -w '%{http_code}' "http://${host}:${port}/" 2>/dev/null || true)"
    if [[ "$code" =~ ^[0-9]+$ ]]; then
      echo "HTTP ${code} from http://${host}:${port}/"
      return 0
    fi
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z -w3 "$host" "$port" 2>/dev/null
    return $?
  fi
  timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

wait_for_authkey

export TS_AUTHKEY
TS_AUTHKEY="$(tr -d '[:space:]' <"${WORK}/authkey")"
export TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
export TS_EXTRA_ARGS="--login-server=${CONTROL_URL} --hostname=${HOSTNAME} --reset --accept-routes --accept-dns=true"
mkdir -p "$TS_STATE_DIR"

CONTAINERBOOT="${TAILSCALEBOOT:-/usr/local/bin/containerboot}"
if [[ ! -x "$CONTAINERBOOT" ]]; then
  echo "error: containerboot not found at ${CONTAINERBOOT}" >&2
  exit 1
fi

echo "→ starting vanilla tailscaled (hostname ${HOSTNAME}) ..."
"$CONTAINERBOOT" &
boot_pid=$!
cleanup() {
  kill "$boot_pid" 2>/dev/null || true
  wait "$boot_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

joined=0
for ((i = 1; i <= JOIN_WAIT_SEC; i++)); do
  if tailscale status >/dev/null 2>&1; then
    joined=1
    break
  fi
  if (( i % 10 == 0 )); then
    echo "→ still waiting for tailnet join (${i}/${JOIN_WAIT_SEC}s) ..."
  fi
  sleep 1
done

if (( joined != 1 )); then
  echo "✗ FAIL: vanilla Tailscale did not join within ${JOIN_WAIT_SEC}s" >&2
  tailscale status 2>&1 || true
  exit 1
fi

echo "✓ vanilla Tailscale joined"
echo ""
tailscale status
echo ""

ping_ok=0
for target in "$SERVER_HOST" "$MAGIC_FQDN"; do
  echo "→ tailscale ping ${target} ..."
  if tailscale ping -c 3 "$target" 2>&1; then
    echo "✓ tailscale ping ${target} OK"
    ping_ok=1
  else
    echo "✗ tailscale ping ${target} FAILED"
  fi
  echo ""
done

server_ip="$(resolve_peer_ip "$SERVER_HOST")"
if [[ -n "$server_ip" ]]; then
  echo "→ server tailnet IP (from tailscale status): ${server_ip}"
else
  echo "warn: could not parse ${SERVER_HOST} tailnet IP from tailscale status" >&2
fi

tcp_ok=0
for target in "$SERVER_HOST" "$MAGIC_FQDN" ${server_ip:+"$server_ip"}; do
  [[ -n "$target" ]] || continue
  echo "→ TCP/HTTP probe ${target}:${QUACK_PORT} ..."
  if tcp_reachable "$target" "$QUACK_PORT"; then
    echo "✓ ${target}:${QUACK_PORT} reachable"
    tcp_ok=1
  else
    echo "✗ ${target}:${QUACK_PORT} not reachable"
  fi
  echo ""
done

echo "Verdict"
echo "-------"
if (( ping_ok == 0 )); then
  echo "✗ Tailnet connectivity to ${SERVER_HOST} failed with vanilla Tailscale."
  echo "  Fix Headscale / routing / DERP before debugging DuckDB tsnet."
  exit 1
fi

if (( tcp_ok == 0 )); then
  echo "✓ Tailnet ping works, but Quack port ${QUACK_PORT} is not reachable."
  echo "  tailscale_serve_local or quack_serve on quacktail-server is likely wrong."
  exit 1
fi

echo "✓ Vanilla Tailscale reaches ${SERVER_HOST}:${QUACK_PORT}."
echo "  If quacktail-client still hangs on tailscale_ping / quack_query / ATTACH,"
echo "  the problem is DuckDB tsnet or Quack — not basic tailnet connectivity."
exit 0
