# DuckLake + Quack on QuackTail

Branch **`ducklake`** extends the compose demo: the server attaches a local DuckLake catalog, seeds an `inventory` table, then `quack_serve` exposes it on the tailnet. The client **discovers** Quack endpoints with `quack_discover()`, then queries inventory via the official **`ducklake:quack:`** attach ([DuckDB 1.5.3](https://duckdb.org/2026/05/20/announcing-duckdb-153.html)).

## Architecture

```text
quacktail-server                          quacktail-client
─────────────────                         ─────────────────
tailscale_up                              tailscale_up
ATTACH ducklake:… AS lake (local Parquet)  quack_discover()
  └─ ducklake-lake volume                   tailscale_quack_forward
quack_serve(127.0.0.1:9494)               ATTACH ducklake:quack:127.0.0.1:19494
tailscale_serve_local                       └─ ro ducklake-lake (same DATA_PATH)
                                            SELECT * FROM lake.inventory
```

Parquet + metadata live on a **named Docker volume** (`ducklake-lake` → `/var/lib/ducklake`). The client mounts the same volume **read-only** so `DATA_PATH` resolves to the server's Parquet files.

## Why not `remote.lake.inventory`?

Plain `ATTACH 'quack:…' AS remote` only exposes the server's primary catalog (`remote.e2e_payload` works). The server's attached DuckLake catalog is **not** nested under `remote.lake.*`. Use **`ducklake:quack:`** instead — Quack carries catalog metadata; `DATA_PATH` points at Parquet.

## Persistence

| Action | DuckLake data |
|--------|----------------|
| `docker compose stop` / `start` | **Kept** — same inventory rows |
| `docker compose down` (no `-v`) | **Kept** |
| `docker compose down -v` | **Wiped** — re-seeds on next first boot |

First boot creates metadata + demo rows `(101,50)`, `(102,120)`. Restarts **attach only** — no `DELETE` / re-seed.

## Run the demo

```bash
cd examples
docker compose build quacktail-server quacktail-client
docker compose up -d --force-recreate headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

Expect `PASSED` (Quack e2e) and `LAKE_PASSED` with `inventory_rows = 2`.

Set `QUACKTAIL_ENABLE_DUCKLAKE=0` to run the original Quack-only e2e.

## Environment

| Variable | Default |
|----------|---------|
| `QUACKTAIL_ENABLE_DUCKLAKE` | `1` |
| `QUACKTAIL_LAKE_NAME` | `lake` |
| `QUACKTAIL_LAKE_METADATA` | `/var/lib/ducklake/metadata/inventory.ducklake` |
| `QUACKTAIL_LAKE_DATA_PATH` | `/var/lib/ducklake/data` |
| Docker volume | `ducklake-lake` → `/var/lib/ducklake` (server rw, client ro) |

## Tailnet client SQL

After `tailscale_up` and `tailscale_quack_forward`:

```sql
LOAD quackscale;
FROM quack_discover();

LOAD quack;
LOAD ducklake;
CREATE SECRET (TYPE quack, TOKEN 'quackscale-demo-token', SCOPE 'quack:127.0.0.1:19494');

-- Quack e2e table (primary catalog)
ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);
SELECT * FROM remote.e2e_payload;

-- DuckLake over Quack (catalog via Quack, Parquet via DATA_PATH)
ATTACH 'ducklake:quack:127.0.0.1:19494' AS lake (DATA_PATH '/var/lib/ducklake/data');
SELECT * FROM lake.inventory;
```

For production tailnets without a shared volume, use a remote `DATA_PATH` (`s3://…`, `https://…`) per [DuckLake docs](https://duckdb.org/docs/stable/duckdb/guides/using_a_remote_data_path).

See [local-demo.sql](local-demo.sql) for single-host reference and [docs/DUCKLAKE_TAILNET.md](../docs/DUCKLAKE_TAILNET.md) for roadmap.
