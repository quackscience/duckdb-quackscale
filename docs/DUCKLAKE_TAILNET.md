# DuckLake over QuackTail (planned)

Goal: serve DuckLake (or SQLite / Postgres-backed catalogs) on a node via **Quack**, reachable only on the **Headscale tailnet**, with **discovery** similar to `quack_discover()`.

## Target architecture

```text
┌─────────────────────┐     tailnet      ┌─────────────────────┐
│  quacktail-client   │ ◄──────────────► │  quacktail-server   │
│  ATTACH quack:…     │                  │  quack_serve        │
│  quack_discover()   │                  │  ATTACH ducklake:…  │
└─────────────────────┘                  │  (lake catalog)     │
                                         └─────────────────────┘
```

1. **Server** joins tailnet, runs `quack_serve`, attaches local DuckLake (or other catalog) as the served DuckDB session catalog.
2. **Client** joins tailnet, `quack_discover()` finds `quack:<host>:9494`, `ATTACH`es, queries `remote.<lake_schema>.<table>`.
3. **Discovery extension** (future QuackScale work): advertise DuckLake URIs alongside Quack URIs, e.g. columns `listen_uri`, `catalog_type` (`quack`, `ducklake`, `sqlite`), `attach_hint`.

## Constraints (today)

- **Quack streaming-scan limit** — one remote read or write per SQL statement on an attached catalog; see [QUACK_STREAMING.md](QUACK_STREAMING.md). DuckLake workloads often use separate statements or server-side execution, so parallelism is less blocked than multi-scan single statements on ATTACH.
- **Nested catalogs** — Quack ATTACH exposes the server's session catalogs; deep names like `remote.lake.schema.table` may need `quack_query()` until Quack nested-catalog support lands ([duckdb#22605](https://github.com/duckdb/duckdb/issues/22605)).

## Demo recipe (next step after compose e2e)

1. Server bootstrap SQL: `INSTALL ducklake; LOAD ducklake; ATTACH 'ducklake:…' AS lake …;` then `quack_serve`.
2. Client: same compose flow as today; `SELECT * FROM remote.lake.main.my_table LIMIT 5`.
3. CI: extend `scripts/ci_headscale_e2e.sh` with optional DuckLake profile (Postgres or local metadata).

## QuackScale changes (not in core `quack`)

| Piece | Owner | Notes |
|-------|--------|------|
| Tailnet join, `quack_uri`, `quack_discover` | quackscale | Done |
| Compose / Headscale demo | quackscale | Done |
| `ducklake_discover()` or enriched `quack_discover` | quackscale | TBD — metadata from server whoami / config |
| Quack multi-scan planner | duckdb-quack | Upstream |
