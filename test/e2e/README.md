# Headscale QuackTail e2e tests

Two DuckDB containers join **Headscale** via `tailscale_up`. Quack listens on **loopback**; **Tailscale Serve** exposes it on the tailnet.

## Flow

1. **Server:** long-running `sleep infinity | duckdb -init` → `tailscale_up` → `quack_serve('quack:127.0.0.1:9494', allow_other_hostname => true, …)` → `CALL tailscale_serve_local(port => 9494)`
2. **Client:** one DuckDB session — `-init` runs `tailscale_up` (process stays alive) → mesh wait → **cross-node curl gate** to server tailnet IP → `ATTACH` + queries on same stdin stream

Quack stays local; quackscale uses libtailscale `SetServeConfig` TCP forward (same idea as `tailscale serve --tcp=9494 localhost:9494`).

Server readiness curl (server → own tailnet IP) is **not** a cross-node check. The client entrypoint curls server IP from the client container while DuckDB/tsnet is still running.

## Env overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_QUACK_ATTACH_HOST` | `hostname` | `hostname` = tailscale name + `--add-host`; `ip`; `magicdns` |
| `E2E_TAILNET_MESH_WAIT_SEC` | `3` | Pause after server ready, before client container starts |
| `E2E_CLIENT_MESH_WAIT_SEC` | `3` | Pause inside client after `tailscale_up`, before curl gate + ATTACH |
| `E2E_CLIENT_TIMEOUT_SEC` | `30` | Hard limit for the client container |

## Run

```sh
eval "$(./scripts/ci_download_release_duckdb.sh latest)"
./scripts/ci_headscale_e2e.sh
```

GitHub Actions: **Headscale QuackTail e2e** (`workflow_dispatch`, `release_tag` defaults to latest). The release must include `tailscale_serve_local`.

Set `DUCKDB_EXTENSION_DIRECTORY` to a shared path on the host (mounted at `/duckdb_extensions` in containers). DuckDB does **not** read that env var — scripts use `SET extension_directory='…'` in SQL and `-cmd` so `LOAD quack` uses the shared install.
