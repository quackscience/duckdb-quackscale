# Headscale QuackTail e2e

Integration tests for a two-node QuackTail cluster over [Headscale](https://github.com/juanfont/headscale).

## CI e2e (release binary, manual only)

GitHub Actions: [`.github/workflows/headscale-e2e.yml`](../../.github/workflows/headscale-e2e.yml)

- **Trigger:** `workflow_dispatch` only (never on push/PR)
- **Flow:** same as [examples/docker-compose.yml](../../examples/docker-compose.yml) — `up headscale + quacktail-server`, then `compose run quacktail-client`
- **DuckDB:** release binary baked into the image (`BUILD_FROM_SOURCE=0`, default tag `v1.0.3`)
- **Scope:** Quack over tailnet (`QUACKTAIL_ENABLE_DUCKLAKE=0`) — not the full DuckLake demo

```bash
export BUILD_FROM_SOURCE=0
export QUACKTAIL_RELEASE_TAG=v1.0.3
export QUACKTAIL_ENABLE_DUCKLAKE=0
chmod +x scripts/ci_headscale_e2e.sh
./scripts/ci_headscale_e2e.sh
```

Expect `PASSED`, `CLIENT_DEMO_DONE` / `Demo passed`, and `seed-from-server` in client output.

## Local compose e2e (source build — not CI)

For the full DuckLake + `attach_ducklake` demo (builds DuckDB in Docker):

```bash
git submodule update --init --recursive
chmod +x scripts/ci_compose_e2e.sh
./scripts/ci_compose_e2e.sh
```

Same as [examples/README.md](../../examples/README.md). Use this on a dev machine; **do not** wire it to push/PR workflows.

## PR / push CI (not e2e)

| Workflow | Trigger | Builds DuckDB? |
|----------|---------|----------------|
| [headscale-integration.yml](../../.github/workflows/headscale-integration.yml) | PR | Yes — smoke test only |
| [libtailscale-integration.yml](../../.github/workflows/libtailscale-integration.yml) | PR | Go tests |
| [MainDistributionPipeline.yml](../../.github/workflows/MainDistributionPipeline.yml) | PR / release | Extension CI |

## Compose demo client session

See [`scripts/e2e/quacktail-compose-bootstrap.sh`](../../scripts/e2e/quacktail-compose-bootstrap.sh) — bootstrap on the shared `/work` volume; adds DuckLake when `QUACKTAIL_ENABLE_DUCKLAKE=1`.

## Server (`loopback_serve`)

```sql
CALL quack_serve('quack:127.0.0.1:9494', allow_other_hostname => true, token => quack_token());
CALL tailscale_serve_local(port => 9494);
```

## Debug probe

[examples/docker-compose.yml](../../examples/docker-compose.yml) profile `debug`: vanilla `tailscale/tailscale` container.
