# Headscale QuackTail e2e tests

Two DuckDB containers join **Headscale** via `tailscale_up`. Quack listens on **loopback**; **Tailscale Serve** exposes it on the tailnet.

## Flow

1. **Server:** `tailscale_up` → `quack_serve('quack:127.0.0.1:9494', …)` → `CALL tailscale_serve_local(port => 9494)`
2. **Client:** `tailscale_up` → `quack_discover()` → `ATTACH 'quack:<server>.<magicdns>:9494'` with `DISABLE_SSL true`

Quack stays local; quackscale uses libtailscale `SetServeConfig` TCP forward (same idea as `tailscale serve --tcp=9494 localhost:9494`).

## Env overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_QUACK_ATTACH_HOST` | `magicdns` | Client URI (`ip` → tailnet IP) |
| `E2E_TAILNET_MESH_WAIT_SEC` | `15` | Pause after nodes register |

## Run

```sh
eval "$(./scripts/ci_download_release_duckdb.sh latest)"
./scripts/ci_headscale_e2e.sh
```

Requires a **quackscale build** that includes `tailscale_serve_local` (this repo). Release binaries must be rebuilt after upgrading.
