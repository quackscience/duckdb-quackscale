# QuackTail Docker Compose example

Two-node **Headscale + QuackTail** stack on Linux. The image always pulls the **latest** [GitHub release](https://github.com/quackscience/duckdb-quackscale/releases) and installs `quack` at build time.

**Requires:** Linux, Docker Compose v2, `/dev/net/tun`, outbound HTTPS.

## Run

```bash
cd examples
docker compose up -d headscale bootstrap quacktail-server
docker compose --profile test run --rm quacktail-client
```

Or as one line:

```bash
docker compose up -d headscale bootstrap quacktail-server && \
docker compose --profile test run --rm quacktail-client
```

The client runs while the server stays up: `tailscale_up` → `quack_query` probe → `ATTACH quack:quacktail-server:9494` → cross-node queries.

## Environment

Set in the shell or a `.env` file next to `docker-compose.yml`:

| Variable | Default |
|----------|---------|
| `QUACK_TAILNET_TOKEN` | `quackscale-demo-token` |
| `HEADSCALE_USER` | `quackscale-demo` |
| `GITHUB_REPO` | `quackscience/duckdb-quackscale` (build-time only, for forks) |

## Teardown

```bash
docker compose --profile test down -v
```
