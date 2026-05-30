# DuckLake + Quack on QuackTail

Branch **`ducklake`** extends the compose demo: the server attaches a local DuckLake catalog, seeds an `inventory` table, then `quack_serve` exposes it on the tailnet. The client queries `remote.lake.inventory` through `tailscale_quack_forward`.

## Architecture

```text
quacktail-server                          quacktail-client
─────────────────                         ─────────────────
tailscale_up                              tailscale_up
ATTACH ducklake:… AS lake (local Parquet)  tailscale_quack_forward
  └─ /work/lake/data/*.parquet            ATTACH quack:127.0.0.1:19494 AS remote
quack_serve(127.0.0.1:9494)               SELECT * FROM remote.lake.inventory
tailscale_serve_local
```

Parquet files live on the **server** (`QUACKTAIL_LAKE_DATA_PATH`). Clients reach the catalog over Quack — no direct file sharing.

## Run the demo

Same commands as the base compose demo (on this branch):

```bash
cd examples
docker compose build quacktail-server quacktail-client
docker compose up -d --force-recreate headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

Expect `PASSED` with `inventory_rows = 2` and two inventory rows `(101, 50)`, `(102, 120)`.

Set `QUACKTAIL_ENABLE_DUCKLAKE=0` to run the original Quack-only e2e.

## Environment

| Variable | Default |
|----------|---------|
| `QUACKTAIL_ENABLE_DUCKLAKE` | `1` |
| `QUACKTAIL_LAKE_NAME` | `lake` |
| `QUACKTAIL_LAKE_METADATA` | `/work/lake/metadata/inventory.ducklake` |
| `QUACKTAIL_LAKE_DATA_PATH` | `/work/lake/data` |

## Local SQL reference

See [local-demo.sql](local-demo.sql) for the standalone DuckLake + Quack pattern (single host, no tailnet).

**Tailnet client** (after `tailscale_quack_forward`):

```sql
LOAD quack;
CREATE SECRET (TYPE quack, TOKEN 'quackscale-demo-token', SCOPE 'quack:127.0.0.1:19494');
ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);
SELECT * FROM remote.lake.inventory;
```

**Direct DuckLake-over-Quack attach** (metadata via Quack URI — optional pattern):

```sql
LOAD ducklake;
LOAD quack;
CREATE SECRET (TYPE quack, TOKEN 'your_token', SCOPE 'quack:127.0.0.1:19494');
ATTACH 'ducklake:quack:127.0.0.1:19494' AS my_lake (DATA_PATH '/path/to/local/parquet/');
USE my_lake;
```

Use this when Parquet files are local to the client; the compose demo uses server-side storage and `remote.lake.*` instead.

See [docs/DUCKLAKE_TAILNET.md](../docs/DUCKLAKE_TAILNET.md) for roadmap (discovery, CI profile).
