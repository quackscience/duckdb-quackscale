# DuckLake over QuackTail

Goal: serve DuckLake on a QuackTail node via **Quack**, reachable on the **Headscale tailnet**, with discovery via `quack_discover()` and queries via the official **`ducklake:quack:`** attach pattern.

## Status on branch `ducklake`

| Piece | Status |
|-------|--------|
| Server: local DuckLake + `quack_serve` + `tailscale_serve_local` | **Done** (compose bootstrap) |
| Client: `quack_discover()` + `ducklake:quack:` attach + inventory query | **Done** (compose e2e) |
| `ducklake_discover()` / enriched `quack_discover` | TBD |
| Client `DATA_PATH` on object storage (no shared volume) | TBD (use `s3://…` per DuckLake docs) |
| CI DuckLake profile | TBD |

## Architecture

```text
┌─────────────────────┐     tailnet      ┌─────────────────────┐
│  quacktail-client   │ ◄──────────────► │  quacktail-server   │
│  quack_discover()   │                  │  ATTACH ducklake:…  │
│  ducklake:quack:…   │                  │  quack_serve        │
│  + ro Parquet vol   │                  │  Parquet → ducklake-lake
└─────────────────────┘                  └─────────────────────┘
```

1. **Server** joins tailnet, attaches DuckLake (`lake` catalog, metadata + Parquet on `ducklake-lake`), runs `quack_serve` + `tailscale_serve_local`.
2. **Client** joins tailnet, `CALL quack_discover()` to find Quack URIs, `tailscale_quack_forward`, then **`ATTACH 'ducklake:quack:127.0.0.1:19494' AS lake (DATA_PATH '…')`** and queries `lake.inventory`.

## Why not `remote.lake.*`?

`ATTACH 'quack:…' AS remote` exposes the server's **primary** DuckDB catalog only (`remote.e2e_payload` works). Nested attached databases (the server's local `lake` DuckLake catalog) are **not** visible as `remote.lake.table`.

DuckDB **v1.5.3** added the supported pattern: use the remote Quack server as the DuckLake **catalog database** ([announcement](https://duckdb.org/2026/05/20/announcing-duckdb-153.html)):

```sql
-- Server
CALL quack_serve('quack:127.0.0.1:9494', token => '…');

-- Client
LOAD ducklake;
CREATE SECRET (TYPE quack, TOKEN '…', SCOPE 'quack:127.0.0.1:19494');
ATTACH 'ducklake:quack:127.0.0.1:19494' AS lake (DATA_PATH '/var/lib/ducklake/data');
SELECT * FROM lake.inventory;
```

Catalog metadata flows over Quack; **`DATA_PATH` must still resolve to the Parquet files** (shared volume in compose, or `s3://` / `https://` in production — see [DuckLake remote data path](https://duckdb.org/docs/stable/duckdb/guides/using_a_remote_data_path)).

## Discovery

| What | How |
|------|-----|
| Find Quack servers on tailnet | `FROM quack_discover();` (after `tailscale_up`) |
| Connect | `tailscale_quack_forward` → `ducklake:quack:127.0.0.1:<local_port>` |
| DuckLake-specific discovery | TBD (`ducklake_discover()` enriching `quack_discover`) |

## Constraints

- **Quack streaming-scan limit** — one remote Quack read/write per SQL statement; see [QUACK_STREAMING.md](QUACK_STREAMING.md). DuckLake attach is separate from plain `quack:` attach.
- **Parquet path** — client `DATA_PATH` must match where files live (compose: read-only mount of `ducklake-lake` at the same path as the server).

## Demo

See [examples/ducklake/README.md](../examples/ducklake/README.md).

## QuackScale changes (not in core `quack`)

| Piece | Owner | Notes |
|-------|--------|------|
| Tailnet join, `tailscale_quack_forward` | quackscale | Done |
| Compose DuckLake server bootstrap | quackscale | Done on `ducklake` branch |
| `ducklake_discover()` or enriched `quack_discover` | quackscale | TBD |
| Quack multi-scan planner | duckdb-quack | Upstream |
