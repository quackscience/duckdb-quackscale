# Headscale QuackTail e2e tests

Two DuckDB containers join **Headscale** via `tailscale_up`. Quack listens on **loopback**; **Tailscale Serve** exposes it on the tailnet.

## Flow

1. **Server:** `tailscale_up` → `quack_serve('quack:127.0.0.1:9494', allow_other_hostname => true, …)` → `CALL tailscale_serve_local(port => 9494)`
2. **Client:** join tailnet (phase 1) → wait → reconnect → `ATTACH 'quack:<server-tailnet-ip>:9494'` with `DISABLE_SSL true`

Quack stays local; quackscale uses libtailscale `SetServeConfig` TCP forward (same idea as `tailscale serve --tcp=9494 localhost:9494`).

## Env overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_QUACK_ATTACH_HOST` | `ip` | Client URI (`magicdns` when tsnet accepts tailnet DNS) |
| `E2E_CLIENT_MESH_WAIT_SEC` | `15` | Pause after client phase-1 `tailscale_up` before ATTACH |
| `E2E_TAILNET_MESH_WAIT_SEC` | `15` | Pause after nodes register |

## Run

```sh
eval "$(./scripts/ci_download_release_duckdb.sh latest)"
./scripts/ci_headscale_e2e.sh
```

GitHub Actions: **Headscale QuackTail e2e** (`workflow_dispatch`, `release_tag` defaults to latest). The release must include `tailscale_serve_local`.
