# Headscale QuackTail e2e tests

End-to-end validation for **two DuckDB nodes** on a [Headscale](https://github.com/juanfont/headscale) tailnet using the core **`quack`** extension and **`quackscale`**.

## Architecture

Same pattern as Headscale and Tailscale verify in CI:

| Component | How it runs |
|-----------|-------------|
| Headscale | Official `docker.io/headscale/headscale:0.28.0` on network `quacktail-ci` |
| QuackTail **server** | `quacktail-ci:e2e` container — `sleep infinity \| duckdb -init` ([duckdb-quack-infra](https://github.com/duckdb/duckdb-quack-infra) pattern) |
| QuackTail **client** | `quacktail-ci:e2e` container — `tailscale_up`, `ATTACH` over **tailnet IP**, INSERT/SELECT |

The release DuckDB binary is bind-mounted into both containers. The image only adds Ubuntu, `curl`, `tini`, and the entrypoint script.

## Release binaries (required for CI)

QuackScale is **not** in the community extension repository yet. CI e2e does **not** compile from source.

1. Publish a [GitHub release](https://github.com/quackscience/duckdb-quackscale/releases).
2. The workflow attaches `quacktail-linux-amd64-<tag>.tar.gz` — DuckDB with **quackscale** embedded.
3. Containers run `INSTALL quack FROM core` on first start if needed.

## Manual e2e (GitHub Actions)

[`.github/workflows/headscale-e2e.yml`](../../.github/workflows/headscale-e2e.yml) — **`workflow_dispatch` only**, linux.

**Actions → Headscale QuackTail e2e → Run workflow**

Optional input: **release tag** (default `latest`).

## Local run

With a published release:

```sh
eval "$(./scripts/ci_download_release_duckdb.sh v0.1.0)"   # or latest
./scripts/ci_headscale_e2e.sh
```

Or after a local build:

```sh
export DUCKDB=$PWD/build/release/duckdb
./scripts/ci_headscale_e2e.sh
```

Docker must be running. Set `QUACK_TAILNET_TOKEN` to override the default shared test token.

## What the e2e script validates

| Step | Node | Validates |
|------|------|-----------|
| Headscale Docker | control plane | Preauth key, node registration |
| Server container | `quacktail-server` | `tailscale_up`, `quack_serve` on `0.0.0.0:9494` |
| Client container | `quacktail-client` | `tailscale_up`, shared-token `CREATE SECRET`, `quack_discover`, tailnet `ATTACH`, `INSERT`, `SELECT` |

## Related

- [docs/HEADSCALE.md](../../docs/HEADSCALE.md)
- [examples/headscale_quacktail.sql](../../examples/headscale_quacktail.sql)
