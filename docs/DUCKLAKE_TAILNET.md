# DuckLake over QuackTail

Goal: serve DuckLake on a QuackTail node via **Quack**, reachable on the **Headscale tailnet** — **find** endpoints and **query** tables from any tailnet client.

## Status on branch `ducklake`

| Piece | Status |
|-------|--------|
| Server: local DuckLake + `quack_serve` + `tailscale_serve_local` | **Done** |
| Client: tailscale forward + `quack_query` lake probe/query | **Done** |
| Client `ducklake:quack:` attach (client-side `DATA_PATH`) | Documented — use when Parquet is local/shared |
| `ducklake_discover()` / enriched `quack_discover` | TBD |

## Find + query on tailnet

### 1) Find the server and its DuckLake catalog

On the client, **tailnet routing** finds the server; **`quack_discover()` must run locally** (do not invoke it via `quack_query` on the server — that hangs over Quack):

```sql
CALL tailscale_quack_forward(host => 'quacktail-server', port => 9494, local_port => 19494);
CALL tailscale_ping(host => 'quacktail-server', port => 9494);

CREATE SECRET (TYPE quack, TOKEN '…', SCOPE 'quack:127.0.0.1:19494');

-- Confirm the lake catalog exists on the server
FROM quack_query(
    'quack:127.0.0.1:19494',
    'SELECT database_name FROM duckdb_databases() WHERE database_name = ''lake''',
    token => '…',
    disable_ssl => true
);
```

Run `FROM quack_discover()` **on the server node** (or locally to list this host's Quack URIs).

### 2) Query DuckLake tables

When the server owns DuckLake metadata + Parquet (compose demo), run lake SQL **on the server** through `quack_query`:

```sql
FROM quack_query(
    'quack:127.0.0.1:19494',
    'SELECT * FROM lake.inventory ORDER BY item_id',
    token => '…',
    disable_ssl => true
);
```

**Why not `remote.lake.inventory`?** Plain `ATTACH 'quack:…' AS remote` exposes the primary catalog only — not nested attached DuckLake catalogs.

**Why not `ducklake:quack:` in compose?** That pattern ([DuckDB 1.5.3](https://duckdb.org/2026/05/20/announcing-duckdb-153.html)) uses Quack as the catalog DB and requires client `DATA_PATH` to resolve Parquet. Our demo stores Parquet on the **server volume** only; `ducklake:quack:` attach can block when paths don't align. Use it when the client has a local or object-store `DATA_PATH` (`s3://…`).

## Architecture

```text
┌─────────────────────┐     tailnet      ┌─────────────────────┐
│  quacktail-client   │ ◄──────────────► │  quacktail-server   │
│  quack_query(…)     │                  │  ATTACH ducklake:…  │
│  (find + lake SQL)  │                  │  quack_serve        │
└─────────────────────┘                  │  ducklake-lake vol  │
                                         └─────────────────────┘
```

## Constraints

- **Quack streaming-scan limit** — one remote Quack read/write per SQL statement; see [QUACK_STREAMING.md](QUACK_STREAMING.md). Each `quack_query` call is one statement.
- **Discovery** — client uses `tailscale_quack_forward` + `tailscale_ping`; probe lake with `quack_query(..., duckdb_databases())`. Do **not** `quack_query(..., 'FROM quack_discover()')`.

## Demo

[examples/ducklake/README.md](../examples/ducklake/README.md)
