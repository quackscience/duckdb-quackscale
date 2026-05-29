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

Headscale’s control API is published on the host at **`http://127.0.0.1:8080`** so a local DuckDB process can join the same tailnet.

## Connect from local DuckDB (while compose is running)

Use a **second DuckDB + quackscale** on your machine (outside Docker) as another tailnet node. It shares the compose Headscale control plane and the same Quack token as the containers.

**1. Start the stack** (if not already up):

```bash
cd examples
docker compose up -d headscale bootstrap quacktail-server
```

**2. Download the latest release DuckDB** (from the repo root, or clone and run the script):

```bash
eval "$(bash scripts/ci_download_release_duckdb.sh latest)"
export QUACK_TAILNET_TOKEN=quackscale-demo-token   # must match compose default
```

**3. Reuse the bootstrap authkey** (written to the shared volume):

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

SELECT * FROM quack_discover();

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

Pick any unused `hostname` for your local node. Re-running with the same `state_dir` usually skips re-auth.

**Optional — serve Quack from the local instance too** (third node on the same tailnet):

```sql
CALL quack_serve(
    quack_uri(),
    allow_other_hostname => true,
    token => quack_token()
);
CALL quack_discover();
```

Other nodes (containers or local) can then `ATTACH 'quack:local-duckdb:9494' ...` with the same token.

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

This removes volumes (authkey, DuckDB files, Headscale DB). Local `state_dir` on the host is not removed.
