# DuckLake + Quack on QuackTail

Branch **`ducklake`** extends the compose demo: the server attaches a local DuckLake catalog, seeds an `inventory` table, then `quack_serve` exposes it on the tailnet. The client queries `remote.lake.inventory` through `tailscale_quack_forward`.

## Architecture

```text
quacktail-server                          quacktail-client
─────────────────                         ─────────────────
tailscale_up                              tailscale_up
ATTACH ducklake:… AS lake (local Parquet)  tailscale_quack_forward
  └─ ducklake-lake volume (/var/lib/ducklake/data/*.parquet)
quack_serve(127.0.0.1:9494)               ATTACH quack:127.0.0.1:19494 AS remote
tailscale_serve_local                     SELECT * FROM remote.lake.inventory
```

Parquet + metadata live on a **named Docker volume** (`ducklake-lake` → `/var/lib/ducklake`). Survives `docker compose stop` / `down` (without `-v`).

## Persistence

| Action | DuckLake data |
|--------|----------------|
| `docker compose stop` / `start` | **Kept** — same inventory rows |
| `docker compose down` (no `-v`) | **Kept** |
| `docker compose down -v` | **Wiped** — re-seeds on next first boot |

First boot creates metadata + demo rows `(101,50)`, `(102,120)`. Restarts **attach only** — no `DELETE` / re-seed.

```bash
# stop stack, start again — data should remain
docker compose stop
docker compose up -d headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

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
| `QUACKTAIL_LAKE_METADATA` | `/var/lib/ducklake/metadata/inventory.ducklake` |
| `QUACKTAIL_LAKE_DATA_PATH` | `/var/lib/ducklake/data` |
| Docker volume | `ducklake-lake` → `/var/lib/ducklake` (server only) |

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
