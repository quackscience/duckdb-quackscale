#!/usr/bin/env bash
# Smoke-test QuackScale against a local Headscale control server (Tailscale-compatible).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADSCALE_IMAGE="${HEADSCALE_IMAGE:-headscale/headscale:0.28.0}"
HEADSCALE_CONTAINER="${HEADSCALE_CONTAINER:-quackscale-headscale-ci}"
CONTROL_URL="${HEADSCALE_CONTROL_URL:-http://127.0.0.1:8080}"
DUCKDB="${DUCKDB:-$ROOT/build/release/duckdb}"
CONFIG_DIR="$ROOT/test/headscale"
DATA_DIR="$(mktemp -d)"
STATE_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR" "$STATE_DIR"
}
trap cleanup EXIT

if [[ ! -x "$DUCKDB" ]]; then
  echo "error: DuckDB not found at $DUCKDB (run: GEN=ninja make release)" >&2
  exit 1
fi

echo "Starting Headscale ($HEADSCALE_IMAGE)..."
docker rm -f "$HEADSCALE_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$HEADSCALE_CONTAINER" \
  -p 127.0.0.1:8080:8080 \
  -v "$CONFIG_DIR/config-ci.yaml:/etc/headscale/config.yaml:ro" \
  -v "$CONFIG_DIR/policy.hujson:/etc/headscale/policy.hujson:ro" \
  -v "$DATA_DIR:/var/lib/headscale" \
  "$HEADSCALE_IMAGE" serve >/dev/null

echo "Waiting for Headscale health at $CONTROL_URL/health ..."
for _ in $(seq 1 60); do
  if curl -sf "$CONTROL_URL/health" >/dev/null; then
    break
  fi
  sleep 1
done
curl -sf "$CONTROL_URL/health" >/dev/null || {
  echo "error: Headscale did not become healthy" >&2
  docker logs "$HEADSCALE_CONTAINER" 2>&1 | tail -50 >&2 || true
  exit 1
}

echo "Creating Headscale user and preauth key..."
docker exec "$HEADSCALE_CONTAINER" headscale users create quackscale-ci >/dev/null 2>&1 || true

USER_ID="$(
  docker exec "$HEADSCALE_CONTAINER" headscale users list -o json \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
users = d.get('users', d if isinstance(d, list) else [])
for u in users:
    if u.get('name') == 'quackscale-ci':
        print(u['id'])
        sys.exit(0)
if users:
    print(users[0]['id'])
"
)"

AUTHKEY="$(
  docker exec "$HEADSCALE_CONTAINER" headscale preauthkeys create \
    --user "$USER_ID" --reusable --expiration 1h -o json \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
key = d.get('key') or d.get('preAuthKey', {}).get('key')
if not key and isinstance(d, dict) and 'preAuthKey' in d:
    key = d['preAuthKey'].get('key')
print(key or '')
"
)"

if [[ -z "$AUTHKEY" ]]; then
  AUTHKEY="$(
    docker exec "$HEADSCALE_CONTAINER" headscale preauthkeys create \
      --user "$USER_ID" --reusable --expiration 1h | awk 'NF {key=$0} END {print key}'
  )"
fi

if [[ -z "$AUTHKEY" ]]; then
  echo "error: failed to obtain Headscale preauth key" >&2
  exit 1
fi

echo "Joining Headscale tailnet from DuckDB (control_url=$CONTROL_URL)..."
"$DUCKDB" <<SQL
LOAD quackscale;
CALL tailscale_up(
    hostname => 'quackscale-ci',
    control_url => '${CONTROL_URL}',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => true
);
CALL tailscale_status();
SQL

echo "Headscale + QuackScale smoke test passed."
