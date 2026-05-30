# QuackTail Docker Compose example

Two-node **Headscale + QuackTail** demo on Linux: server joins the tailnet and serves Quack; client `ATTACH`es via `tailscale_quack_forward`.

**DuckLake combo (branch `ducklake`):** [ducklake/README.md](ducklake/README.md)

**Requires:** Linux, Docker Compose v2, `/dev/net/tun`, outbound HTTPS.

## Architecture

```
  quacktail-client                         quacktail-server
  ─────────────────                        ──────────────────
  CALL tailscale_up                        CALL tailscale_up
  CALL tailscale_quack_forward ──tsnet──►  quack_serve(127.0.0.1:9494)
       │                                   tailscale_serve_local(:9494)
       ▼
  ATTACH 'quack:127.0.0.1:19494'
```

Quack HTTP uses **kernel TCP**. Embedded tsnet does not route that traffic. `tailscale_quack_forward` listens on `127.0.0.1:19494` and dials `quacktail-server:9494` via `tailscale_dial` for each connection.

**Two secrets (do not confuse):**

| Variable | Default | Purpose |
|----------|---------|---------|
| `QUACK_TAILNET_TOKEN` | `quackscale-demo-token` | Quack HTTP auth (`CREATE SECRET`, `quack_token()`) |
| Headscale preauth key | generated → `/work/authkey` | `CALL tailscale_up(authkey => ...)` |

## Run the demo

Source build is required for the DuckLake demo (`attach_ducklake`, `tailscale_down`).

```bash
git pull
git submodule update --init --recursive
cd examples
docker compose build --no-cache quacktail-server quacktail-client
docker compose run --rm --entrypoint /usr/local/bin/quacktail-verify-image.sh quacktail-client
docker compose up -d --force-recreate headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

Use **`--force-recreate`** on the server after script or SQL changes (otherwise the old DuckDB process keeps running).

**Refresh stale `/work` SQL without running the client demo** (one container, no DuckDB session):

```bash
docker compose run --rm -e QUACKTAIL_ROLE=bootstrap quacktail-client
docker compose --profile test run --rm quacktail-client
```

Do **not** use `quacktail-client true` — compose sets `QUACKTAIL_ROLE=client`, so that still runs the full demo.

**Release binary instead of source build:**

```bash
BUILD_FROM_SOURCE=0 docker compose build quacktail-server quacktail-client
```

Default `QUACKTAIL_RELEASE_TAG` is `v1.0.2` (must include `tailscale_quack_forward`).

Expect:

```text
✓ Demo passed — two-node QuackTail cluster is working
```

## Expected client output

```text
→ waiting for quacktail-server on tailnet ...
✓ quacktail-server on tailnet

QuackTail cluster demo
======================
→ join tailnet, forward, attach_ducklake, ATTACH quack:127.0.0.1:19494 ...

CALL tailscale_up(...);              → running true
CALL tailscale_quack_forward(...);  → quack:127.0.0.1:19494
CALL tailscale_ping(...);            → reachable true
FROM quack_query(...);               → probe 1
CALL attach_ducklake(...);           → lake.inventory view created
SELECT * FROM lake.inventory ...;
SELECT 'LAKE_PASSED' ...;
ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);
SELECT 'PASSED' ...;
SELECT 'CLIENT_DEMO_DONE' ...;
CALL tailscale_down();

✓ Demo passed — QuackTail cluster + DuckLake over tailnet
```

The client runs one DuckDB session (`duckdb -batch -echo -f /work/client_session.sql`). Compose waits for `quacktail-server` **healthy** (server.log shows `quack_serve` + `tailscale_serve_local`) before starting the client.

Set `QUACKTAIL_QUIET=0` to print full SQL. Server libtailscale logs: `/work/server.log`.

## Services

| Service | Profile | Role |
|---------|---------|------|
| `headscale` | default | Control server (`http://127.0.0.1:8080` on host) |
| `quacktail-server` | default | Long-lived DuckDB + Quack serve |
| `quacktail-client` | `test` | One-shot e2e |
| `tailscale-probe` | `debug` | Vanilla `tailscale/tailscale` — ping + TCP to `:9494` (no DuckDB) |

## Connect from host DuckDB

With the stack running, a host DuckDB can join the same tailnet and use the same forwarder pattern as the client container.

**Option A — helper script** (repo root):

```bash
docker compose exec -T quacktail-server cat /work/authkey > examples/headscale/demo.authkey  # gitignored
export HEADSCALE_CONTROL_URL=http://127.0.0.1:8080
export QUACK_TAILNET_TOKEN=quackscale-demo-token
bash scripts/local_remote_headscale_test.sh   # uses build/release/duckdb or release binary
```

**Option B — manual SQL** (after `eval "$(bash scripts/ci_download_release_duckdb.sh v1.0.2)"`):

```sql
LOAD quackscale;
CALL tailscale_up(hostname => 'local-duckdb', control_url => 'http://127.0.0.1:8080',
    authkey => '…', state_dir => '…', ephemeral => true);
CALL tailscale_quack_forward(host => 'quacktail-server', port => 9494, local_port => 19494);
LOAD quack;
CREATE SECRET (TYPE quack, TOKEN 'quackscale-demo-token', SCOPE 'quack:127.0.0.1:19494');
ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);
SELECT * FROM remote.e2e_payload;
```

## Environment

| Variable | Default |
|----------|---------|
| `QUACK_TAILNET_TOKEN` | `quackscale-demo-token` |
| `QUACK_PORT` | `9494` |
| `QUACK_FORWARD_LOCAL_PORT` | `19494` |
| `QUACKTAIL_QUIET` | `1` |
| `HEADSCALE_USER` | `quackscale-demo` |
| `BUILD_FROM_SOURCE` | `1` (build-time) |
| `QUACKTAIL_RELEASE_TAG` | `v1.0.2` (when `BUILD_FROM_SOURCE=0`) |

Copy [`.env.example`](.env.example) to `.env` to override.

## Teardown

```bash
docker compose --profile test down --remove-orphans -v
```

## Troubleshooting

**Tailnet vs DuckDB?** Run the vanilla probe while the server is up:

```bash
docker compose --profile debug run --rm tailscale-probe
```

| Probe | Client | Likely cause |
|-------|--------|--------------|
| pass | fail | DuckDB tsnet / `tailscale_quack_forward` / Quack `ATTACH` |
| ping fail | — | Headscale / DERP / routing |
| ping OK, TCP :9494 fail | — | Server `quack_serve` / `tailscale_serve_local` |

**Client fails after `quack_query` probe succeeds** — ensure images include `tailscale_quack_forward` and client SQL uses `ATTACH 'quack:127.0.0.1:19494'` (not direct `quack:quacktail-server:9494`). Rebuild and recreate:

```bash
docker compose build quacktail-client
docker compose up -d --force-recreate quacktail-server
docker compose --profile test run --rm quacktail-client
```

**Stale `/work` volume** — reset: `docker compose down --remove-orphans -v`

**Server logs:** `docker compose exec quacktail-server tail -50 /work/server.log`

**Client logs:** `docker compose exec quacktail-server cat /work/client.out` (last run, shared volume)

See also [docs/AUTHENTICATION.md](../docs/AUTHENTICATION.md) (Tailscale + forwarder) and [docs/QUACK_AUTH.md](../docs/QUACK_AUTH.md) (Quack tokens).
