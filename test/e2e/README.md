# Headscale QuackTail e2e tests

End-to-end validation for **two DuckDB nodes** on a [Headscale](https://github.com/juanfont/headscale) tailnet using the core **`quack`** extension and **`quackscale`**.

## What runs in CI

[`.github/workflows/headscale-e2e.yml`](../.github/workflows/headscale-e2e.yml) executes [`scripts/ci_headscale_e2e.sh`](../scripts/ci_headscale_e2e.sh):

| Step | Node | Validates |
|------|------|-----------|
| Headscale Docker | control plane | Preauth key, node registration |
| Server | `quacktail-server` | `tailscale_up`, `quack_token()`, `quack_serve`, `quack_discover` |
| Client | `quacktail-client` | `tailscale_up`, shared-token `CREATE SECRET`, `quack_discover`, `ATTACH`, `INSERT`, `SELECT` |

Requires **DuckDB v1.5.3+** so `INSTALL quack FROM core` is available (CI pins the `duckdb` submodule to `v1.5.3` for this job only).

## Local run

```sh
cd duckdb && git checkout v1.5.3 && cd ..
GEN=ninja make release
./scripts/ci_headscale_e2e.sh
```

Docker must be running. Set `QUACK_TAILNET_TOKEN` to override the default shared test token.

## Related

- [docs/HEADSCALE.md](../docs/HEADSCALE.md)
- [examples/headscale_quacktail.sql](../examples/headscale_quacktail.sql)
