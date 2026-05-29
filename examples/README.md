# QuackTail Docker Compose example

Two-node **Headscale + QuackTail** cluster on Linux — server and client DuckDB nodes on a shared tailnet, client `ATTACH`es the server's Quack endpoint.

The image pulls the **latest** [GitHub release](https://github.com/quackscience/duckdb-quackscale/releases) and installs `quack` at build time.

**Requires:** Linux, Docker Compose v2, `/dev/net/tun`, outbound HTTPS.

## Basic testing

**Compose (local):**

```bash
git pull && cd examples
docker compose build quacktail-server quacktail-client
docker compose up -d --force-recreate headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

Use `--force-recreate` on the server after script/SQL changes (otherwise the old DuckDB process keeps running without `tailscale_serve_local`).

Expect `✓ Demo passed — two-node QuackTail cluster is working`.

**CI (GitHub Actions):** run workflow [Headscale QuackTail e2e](../../.github/workflows/headscale-e2e.yml) (`workflow_dispatch`). Same client SQL path as compose (`client_init.sql` + `client_quack.sql`, `PASSED` row).

**Next:** DuckLake on server + tailnet discovery — see [docs/DUCKLAKE_TAILNET.md](../docs/DUCKLAKE_TAILNET.md).

## Quick start

```bash
git pull
cd examples
docker compose build --no-cache quacktail-server quacktail-client
docker compose up -d headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

You should see one line `→ join tailnet, ATTACH quack:quacktail-server:9494, verify ...` (not two separate join/ATTACH steps). If you still see the old two-step messages, the client image was not rebuilt.

Core services: `headscale`, `quacktail-server`, `quacktail-client` (test profile). Optional `tailscale-probe` (debug profile) uses **vanilla** `tailscale/tailscale` — no DuckDB — to test ping + TCP to `quacktail-server:9494`.

## Expected output

**Server** (`docker compose logs quacktail-server`):

```
✓ Headscale authkey ready — attach URI quack:quacktail-server:9494
→ quacktail-server: join tailnet + quack_serve(127.0.0.1:9494) + tailscale_serve_local
  (libtailscale logs → /work/server.log)
```

**Client** — one DuckDB session: join tailnet, `ATTACH` over server tailnet IP, insert + verify:

```
→ waiting for quacktail-server on tailnet ...
✓ quacktail-server on tailnet
→ quacktail-server → 100.64.x.x (/etc/hosts, matches server quack_uri())
✓ client SQL ready — attach quack:quacktail-server:9494

QuackTail cluster demo
======================
→ join tailnet as quacktail-client, ATTACH quack:quacktail-server:9494, verify read/write ...

(tailscale_status, Success, PASSED summary — typically under 10s)

✓ Demo passed — two-node QuackTail cluster is working
```

If the client step hangs or exceeds ~30s, the demo fails fast with a timeout and tails `/work/client-tsnet.log` (libtailscale detail).

That confirms: tailnet join, `ATTACH`, read from server, write from client.

Re-running the client is safe: insert uses `ON CONFLICT DO NOTHING`. The server clears `e2e_payload` only when the server container starts.

Verbose DuckDB/SQL logging is off by default (`QUACKTAIL_QUIET=1`). Set `QUACKTAIL_QUIET=0` in compose or `.env` to debug.

Headscale control API: **`http://127.0.0.1:8080`**

## Connect from local DuckDB

With the stack running, join the same Headscale tailnet from a host DuckDB:

```bash
# repo root
eval "$(bash scripts/ci_download_release_duckdb.sh latest)"
export QUACK_TAILNET_TOKEN=quackscale-demo-token

cd examples
AUTHKEY=$(docker compose exec -T quacktail-server cat /work/authkey)

STATE_DIR="${HOME}/.local/share/duckdb/quackscale-demo"
mkdir -p "$STATE_DIR"

"$DUCKDB" -batch <<SQL
INSTALL quack FROM core;
LOAD quack;

CALL tailscale_up(
    hostname => 'local-duckdb',
    control_url => 'http://127.0.0.1:8080',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => false
);

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TAILNET_TOKEN}',
    SCOPE 'quack:quacktail-server:9494'
);

ATTACH 'quack:quacktail-server:9494' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

SELECT * FROM remote.e2e_payload;
SQL
```

## Environment

| Variable | Default |
|----------|---------|
| `QUACK_TAILNET_TOKEN` | `quackscale-demo-token` |
| `QUACKTAIL_QUIET` | `1` (clean demo output) |
| `HEADSCALE_USER` | `quackscale-demo` |
| `GITHUB_REPO` | `quackscience/duckdb-quackscale` (build-time) |

## Teardown

```bash
docker compose --profile test down --remove-orphans -v
```

## Troubleshooting

**Is it tailnet or DuckDB?** Run the vanilla Tailscale probe while the server is up:

```bash
docker compose build tailscale-probe
docker compose --profile debug run --rm tailscale-probe
```

- Probe **passes**, client **fails** → tailnet + Quack port work; issue is DuckDB tsnet or Quack `ATTACH`.
- Probe **ping fails** → Headscale / DERP / routing — not DuckDB-specific.
- Probe **ping OK, TCP/HTTP to :9494 fails** → `tailscale_serve_local` / `quack_serve` on the server.

**Stale `bootstrap` / `wait-tailnet` containers** — old compose file; run `git pull`, then `docker compose down --remove-orphans -v` and rebuild.

**Server restart loop** — check `docker compose logs quacktail-server`; for libtailscale detail: `docker compose exec quacktail-server tail -50 /work/server.log`

**Client times out after `CREATE SECRET Success`** — tailnet join succeeded; stall is on `tailscale_ping`, `quack_query`, or `ATTACH`. Recreate the server after script changes:

```bash
docker compose up -d --force-recreate quacktail-server
docker compose --profile test run --rm quacktail-client
```

Readiness uses **only DuckDB** (`tailscale_ping`, `quack_query`) — no curl gates. Client retries the full session until `PASSED`.

**`Multiple streaming scans or streaming scans + CTAS / insert`** — this is a **`quack` extension** planner limit, not QuackScale. It fires when one SQL statement both reads and writes the same attached Quack catalog (e.g. `INSERT … WHERE NOT EXISTS (SELECT … FROM remote.t)`). See [docs/QUACK_STREAMING.md](../docs/QUACK_STREAMING.md).
