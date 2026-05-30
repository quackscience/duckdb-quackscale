# Development

This document is for **extension contributors** — building QuackScale, updating DuckDB, and CI. Integrators should read [GUIDE.md](GUIDE.md) and [AUTHENTICATION.md](AUTHENTICATION.md).

## What QuackScale is

QuackScale is a DuckDB community extension embedding [libtailscale](https://github.com/tailscale/libtailscale) so a DuckDB process can join a tailnet and reach the [Quack](https://duckdb.org/docs/current/quack/overview) HTTP protocol on tailnet addresses.

QuackScale does **not** reimplement Quack. It provides tailnet lifecycle SQL, a localhost forwarder for Quack clients, and helpers such as `attach_ducklake`.

```text
DuckDB + quackscale + libtailscale
  → tailscale_up, tailscale_quack_forward, quack_uri, attach_ducklake
DuckDB + quack (core)
  → quack_serve, ATTACH, quack_query
```

## Build

Prerequisites: C++17, cmake, ninja or make, Go 1.25+ (CGO), git submodules.

```sh
git clone --recurse-submodules https://github.com/quackscience/duckdb-quackscale.git
cd duckdb-quackscale
GEN=ninja make release
```

Artifacts:

- `build/release/duckdb`
- `build/release/extension/quackscale/quackscale.duckdb_extension`

Disable libtailscale (stub build):

```sh
make CMAKE_VARS="-DQUACKSCALE_WITH_TAILSCALE=OFF"
```

Docker Compose images build from source by default — see [examples/Dockerfile](../examples/Dockerfile) and `.dockerignore`.

## Repository layout

```text
cmake/Libtailscale.cmake     Go c-archive build + Go 1.25.5 bootstrap
third_party/libtailscale/     git submodule
src/                          C++ extension (bridge, forwarder, attach_ducklake)
scripts/e2e/                  Compose entrypoint, bootstrap, verify-image
examples/                     Docker Compose two-node demo
duckdb/                       DuckDB submodule
extension-ci-tools/             Extension build makefile submodule
```

## libtailscale integration

- Built with `go build -buildmode=c-archive` → `libtailscale.a`
- C API: `tailscale_up`, `tailscale_dial`, `tailscale_close`, etc.
- CMake option `QUACKSCALE_WITH_TAILSCALE` (default ON)
- Ubuntu Docker builder needs `build-essential` and `patch` for the libtailscale patch step

## Updating DuckDB

When bumping the DuckDB target:

1. Update `./duckdb` submodule to the latest stable tag  
2. Update `./extension-ci-tools` to the branch matching that DuckDB version (e.g. `v1.5.3`)  
3. Update `duckdb_version` in [MainDistributionPipeline.yml](../.github/workflows/MainDistributionPipeline.yml)  
4. Rebuild — the DuckDB C++ API is not stable; fix compile breaks using [release notes](https://github.com/duckdb/duckdb/releases) and core extension patches  

## CI workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| [headscale-e2e.yml](../.github/workflows/headscale-e2e.yml) | **Manual only** | Release-binary two-node e2e (no source build) |
| [headscale-integration.yml](../.github/workflows/headscale-integration.yml) | PR | Source build + Headscale smoke |
| [Release.yml](../.github/workflows/Release.yml) | Release published | Build linux release tarball |
| [libtailscale-integration.yml](../.github/workflows/libtailscale-integration.yml) | PR | libtailscale `go test` |
| [MainDistributionPipeline.yml](../.github/workflows/MainDistributionPipeline.yml) | PR | Extension distribution CI |

**E2e never runs on push/PR** and never compiles DuckDB in CI — use `workflow_dispatch` on `headscale-e2e` with a release tag. Full DuckLake compose demo is local dev only (`scripts/ci_compose_e2e.sh`).

## Roadmap (selected)

| Item | Status |
|------|--------|
| `tailscale_up`, `tailscale_quack_forward`, `tailscale_down` | Done |
| `attach_ducklake` (Tier 2 remote lake views) | Done |
| Headscale + Compose e2e | Done |
| `ATTACH … TYPE quacktail_lake` (Tier 3 native catalog) | Planned |
| `ducklake_discover()` enriched discovery | Planned |
| `quackscale_serve()` one-call server bootstrap | Planned |
| Community extension descriptor publish | Planned |

## Risks

| Risk | Mitigation |
|------|------------|
| Large binary (Go runtime) | Document size; `QUACKSCALE_WITH_TAILSCALE=OFF` stub |
| Quack API churn | Pin DuckDB; integration tests against pinned quack |
| Secrets in SQL | Env / orchestrator secrets — see [AUTHENTICATION.md](AUTHENTICATION.md) |

## Tests

```sh
make test
```

SQL unit tests do not require a live tailnet. E2e: [test/e2e/README.md](../test/e2e/README.md), [examples/README.md](../examples/README.md).

## License

MIT (extension template). libtailscale is [BSD-3-Clause](https://github.com/tailscale/libtailscale/blob/main/LICENSE).
