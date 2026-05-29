# QuackTail Docker Compose example

Two-node **Headscale + QuackTail** stack on Linux. The image always pulls the **latest** [GitHub release](https://github.com/quackscience/duckdb-quackscale/releases) and installs `quack` at build time.

**Requires:** Linux, Docker Compose v2, `/dev/net/tun`, outbound HTTPS.

## Run

```bash
cd examples
docker compose up -d headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

Or as one line:

```bash
docker compose up -d headscale quacktail-server && \
docker compose --profile test run --rm quacktail-client
```

On first start, **quacktail-server** creates the Headscale authkey and SQL files in the shared `/work` volume, joins the tailnet, and serves Quack. The **client** waits for the server on the tailnet, then runs `quack_query` → `ATTACH quack:quacktail-server:9494` → cross-node queries.

Headscale’s control API is on the host at **`http://127.0.0.1:8080`**.

## Connect from local DuckDB (while compose is running)

Use a **second DuckDB + quackscale** on your machine (outside Docker) as another tailnet node.

**1. Start the stack:**

```bash
cd examples
docker compose up -d headscale quacktail-server
```

**2. Download the latest release DuckDB** (from the repo root):

```bash
eval "$(bash scripts/ci_download_release_duckdb.sh latest)"
export QUACK_TAILNET_TOKEN=quackscale-demo-token
```

**3. Reuse the authkey** (created on server first boot):

```bash
cd examples
AUTHKEY=$(docker compose exec -T quacktail-server cat /work/authkey)
```

**4. Join the tailnet and ATTACH the container server:**

```bash
STATE_DIR="${HOME}/.local/share/duckdb/quackscale-demo"
mkdir -p "$STATE_DIR"

"$DUCKDB" -batch <<SQL
INSTALL quack FROM core;
LOAD quack;

CALL tailscale_up(
    hostname => 'local-duckdb',
    control_url => 'http://127.0.0.1:8080',
    authkey => '${AUTHKEY}',
    state_dir => '${STATE_DIR}',
    ephemeral => false
);

CREATE SECRET (
    TYPE quack,
    TOKEN '${QUACK_TAILNET_TOKEN}',
    SCOPE 'quack:quacktail-server:9494'
);

ATTACH 'quack:quacktail-server:9494' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

SELECT * FROM remote.e2e_payload;
SQL
```

## Environment

| Variable | Default |
|----------|---------|
| `QUACK_TAILNET_TOKEN` | `quackscale-demo-token` |
| `HEADSCALE_USER` | `quackscale-demo` |
| `GITHUB_REPO` | `quackscience/duckdb-quackscale` (build-time only) |

## Teardown

```bash
docker compose --profile test down -v
```

Removes compose volumes (authkey, DuckDB files, Headscale DB). Local `state_dir` on the host is kept.
