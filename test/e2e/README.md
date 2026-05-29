# Headscale QuackTail e2e

One CI job: **Headscale** stays up; **server** and **client** DuckDB containers run **at the same time**.

## Flow

1. Start Headscale (Docker, `quacktail-ci` network)
2. `docker run -d` **server** — long-lived `duckdb -init` → `tailscale_up` → `quack_serve` → `tailscale_serve_local`
3. Resolve server tailnet IP from Headscale (node list only)
4. `docker run -d` **client** while server is still running → `tailscale_up` → poll `http://<server-ip>:9494/quack` → `ATTACH`
5. `docker wait` client; verify server container still running

No host-side Quack HTTP waits before the client starts. The client polls cross-node while both workers are on the tailnet.

## Run locally

```sh
eval "$(./scripts/ci_download_release_duckdb.sh latest)"
export DUCKDB_EXTENSION_DIRECTORY=/tmp/duckdb_extensions
./scripts/ci_ensure_quack.sh
# start headscale separately or let the script start it
./scripts/ci_headscale_e2e.sh
```

Workflow: **Headscale QuackTail e2e** (`workflow_dispatch`).
