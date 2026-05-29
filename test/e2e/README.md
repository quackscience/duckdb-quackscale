# Headscale QuackTail e2e tests

Three **isolated CI jobs** (see `.github/workflows/headscale-e2e.yml`):

| Job | Script | Proves |
|-----|--------|--------|
| **A — Headscale smoke** | workflow steps + release binary | Control plane health, authkey, one `tailscale_up` join |
| **B — Server publish smoke** | `scripts/ci_quacktail_server_smoke.sh` | Server container: loopback `quack_serve` + `tailscale_serve_local`, self-reach on tailnet IP |
| **C — Cross-node e2e** | `scripts/ci_headscale_e2e.sh` | Client polls cross-node HTTP, then `ATTACH` + queries |

Job C depends on A and B passing (sanity gates) but starts its own Headscale stack on a fresh runner.

## Cross-node flow (job C)

1. **Server:** `sleep infinity | duckdb -init` → `tailscale_up` → `quack_serve('quack:127.0.0.1:9494', …)` → `tailscale_serve_local(port => 9494)`
2. **Client:** one DuckDB session — `-init` runs `tailscale_up` → **poll cross-node HTTP** to server tailnet IP (60×2s) → `ATTACH` on same stdin stream

Server **local** readiness (loopback bind) is not cross-node proof. The client entrypoint polls until the server tailnet IP responds.

## Quack extension (single install path)

Host installs once via `scripts/ci_ensure_quack.sh` → `scripts/lib/quacktail_ext.sh`. Containers **load only** from the mounted cache (`/duckdb_extensions`); they never `INSTALL`.

DuckDB ignores `DUCKDB_EXTENSION_DIRECTORY` env — scripts use `SET extension_directory='…'` in SQL and `-cmd`.

## Env overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_QUACK_ATTACH_HOST` | `ip` | `ip` = tailnet IP ATTACH; `hostname` / `magicdns` for DNS tests |
| `E2E_TAILNET_MESH_WAIT_SEC` | `0` | Optional fixed pause before client container (prefer client poll) |
| `E2E_CLIENT_MESH_WAIT_SEC` | `0` | Optional fixed pause inside client before cross-node poll |
| `E2E_CROSS_NODE_GATE_ATTEMPTS` | `60` | Client cross-node curl attempts |
| `E2E_CROSS_NODE_POLL_SEC` | `2` | Seconds between cross-node curl attempts |
| `E2E_CLIENT_TIMEOUT_SEC` | `180` | Client container hard limit (fits 60×2s poll + init/ATTACH) |
| `E2E_SERVER_PUBLISH_ATTEMPTS` | `60` | Job B: server self-reach poll attempts |

## Run locally

```sh
eval "$(./scripts/ci_download_release_duckdb.sh latest)"
export DUCKDB_EXTENSION_DIRECTORY=/tmp/duckdb_extensions
./scripts/ci_ensure_quack.sh
./scripts/ci_quacktail_server_smoke.sh   # job B
./scripts/ci_headscale_e2e.sh            # job C
```

GitHub Actions: **Headscale QuackTail e2e** (`workflow_dispatch`, `release_tag` defaults to latest). Release must include `tailscale_serve_local`.
