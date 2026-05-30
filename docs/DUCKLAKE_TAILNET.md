# DuckLake over QuackTail

Goal: serve DuckLake on a QuackTail node via **Quack**, reachable on the **Headscale tailnet**, with discovery similar to `quack_discover()`.

## Status on branch `ducklake`

| Piece | Status |
|-------|--------|
| Server: local DuckLake + `quack_serve` + `tailscale_serve_local` | **Done** (compose bootstrap) |
| Client: `tailscale_quack_forward` + `remote.lake.*` queries | **Done** (compose e2e) |
| `ducklake_discover()` / enriched `quack_discover` | TBD |
| Client `ducklake:quack:` attach with client-side `DATA_PATH` | Documented, not in compose e2e |
| CI DuckLake profile | TBD |

## Architecture

```text
┌─────────────────────┐     tailnet      ┌─────────────────────┐
│  quacktail-client   │ ◄──────────────► │  quacktail-server   │
│  ATTACH quack:…     │                  │  ATTACH ducklake:…  │
│  remote.lake.*      │                  │  quack_serve        │
└─────────────────────┘                  │  Parquet → /work/lake/data
                                         └─────────────────────┘
```

1. **Server** joins tailnet, attaches DuckLake (`lake` catalog, local metadata + Parquet), runs `quack_serve` + `tailscale_serve_local`.
2. **Client** joins tailnet, `tailscale_quack_forward`, `ATTACH`es Quack at `127.0.0.1:19494`, queries `remote.lake.inventory`.

## Constraints

- **Quack streaming-scan limit** — one remote read or write per SQL statement; see [QUACK_STREAMING.md](QUACK_STREAMING.md).
- **Nested catalogs** — `remote.lake.table` works when the server attached `lake` before `quack_serve`. Deep paths may need `quack_query()` until upstream nested-catalog support lands.

## Demo

See [examples/ducklake/README.md](../examples/ducklake/README.md).

## QuackScale changes (not in core `quack`)

| Piece | Owner | Notes |
|-------|--------|------|
| Tailnet join, `tailscale_quack_forward` | quackscale | Done |
| Compose DuckLake server bootstrap | quackscale | Done on `ducklake` branch |
| `ducklake_discover()` or enriched `quack_discover` | quackscale | TBD |
| Quack multi-scan planner | duckdb-quack | Upstream |
