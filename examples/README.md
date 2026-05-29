# QuackTail Docker Compose example

Two-node **Headscale + QuackTail** stack on Linux. The image always pulls the **latest** [GitHub release](https://github.com/quackscience/duckdb-quackscale/releases) and installs `quack` at build time.

**Requires:** Linux, Docker Compose v2, `/dev/net/tun`, outbound HTTPS.

**Services (exactly three):** `headscale`, `quacktail-server`, `quacktail-client` (test profile). There is **no** `bootstrap` or `wait-tailnet` sidecar — if you see those names, your compose file is stale (see below).

## Run

From the **repo root**, pull latest, then:

```bash
cd examples
docker compose down --remove-orphans -v
docker compose build --no-cache
docker compose up -d headscale quacktail-server
```

**Verify** — `docker compose ps` should show only `headscale` and `quacktail-server` (both running; server healthy once `/work/authkey` exists):

```bash
docker compose ps
docker compose logs quacktail-server | tail -30   # expect: compose bootstrap ok
```

Run the client:

```bash
docker compose --profile test run --rm quacktail-client
```

On first start, **quacktail-server** creates the Headscale authkey and SQL in `/work`, joins the tailnet, and serves Quack. The client waits for the server on the tailnet, then `quack_query` → `ATTACH quack:quacktail-server:9494`.

Headscale’s control API is on the host at **`http://127.0.0.1:8080`**.

### Stale compose / bootstrap errors

If you see errors like `bootstrap-1` or `wait-tailnet-1` and `/bin/sh: no such file or directory`:

```bash
git pull
cd examples
docker compose down --remove-orphans -v
docker compose build --no-cache
docker compose up -d headscale quacktail-server
```

## Connect from local DuckDB (while compose is running)

Use a **second DuckDB + quackscale** on your machine (outside Docker) as another tailnet node.

**1. Start the stack** (see above).

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
docker compose --profile test down --remove-orphans -v
```

Removes compose volumes (authkey, DuckDB files, Headscale DB). Local `state_dir` on the host is kept.
