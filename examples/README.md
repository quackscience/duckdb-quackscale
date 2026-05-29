# QuackTail Docker Compose example

Two-node **Headscale + QuackTail** cluster on Linux — server and client DuckDB nodes on a shared tailnet, client `ATTACH`es the server's Quack endpoint.

The image pulls the **latest** [GitHub release](https://github.com/quackscience/duckdb-quackscale/releases) and installs `quack` at build time.

**Requires:** Linux, Docker Compose v2, `/dev/net/tun`, outbound HTTPS.

## Quick start

```bash
git pull
cd examples
docker compose build --no-cache quacktail-server quacktail-client
docker compose up -d headscale quacktail-server
docker compose --profile test run --rm quacktail-client
```

You should see one line `→ join tailnet, ATTACH quack:quacktail-server:9494, verify ...` (not two separate join/ATTACH steps). If you still see the old two-step messages, the client image was not rebuilt.

Three services: `headscale`, `quacktail-server`, `quacktail-client` (test profile only).

## Expected output

**Server** (`docker compose logs quacktail-server`):

```
✓ Headscale authkey ready — attach URI quack:quacktail-server:9494
→ quacktail-server: join tailnet + quack_serve on quack:quacktail-server:9494
  (libtailscale logs → /work/server.log)
```

**Client** — one DuckDB session (tailnet join stays up for discover + ATTACH). libtailscale logs stream live via `tee`:

```
→ waiting for quacktail-server on tailnet ...
✓ quacktail-server on tailnet
→ join tailnet as quacktail-client, discover, ATTACH quack:quacktail-server:9494 ...

(tailscale_up table, quack_discover, probe_result, PASSED summary — streamed as they run)

✓ Demo passed — two-node QuackTail cluster is working
```

That table confirms: tailnet join, `quack_query`, `ATTACH`, read from server, write from client.

Verbose DuckDB/SQL logging is off by default (`QUACKTAIL_QUIET=1`). Set `QUACKTAIL_QUIET=0` in compose or `.env` to debug.

Headscale control API: **`http://127.0.0.1:8080`**

## Connect from local DuckDB

With the stack running, join the same Headscale tailnet from a host DuckDB:

```bash
# repo root
eval "$(bash scripts/ci_download_release_duckdb.sh latest)"
export QUACK_TAILNET_TOKEN=quackscale-demo-token

cd examples
AUTHKEY=$(docker compose exec -T quacktail-server cat /work/authkey)

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
| `QUACKTAIL_QUIET` | `1` (clean demo output) |
| `HEADSCALE_USER` | `quackscale-demo` |
| `GITHUB_REPO` | `quackscience/duckdb-quackscale` (build-time) |

## Teardown

```bash
docker compose --profile test down --remove-orphans -v
```

## Troubleshooting

**Stale `bootstrap` / `wait-tailnet` containers** — old compose file; run `git pull`, then `docker compose down --remove-orphans -v` and rebuild.

**Server restart loop** — check `docker compose logs quacktail-server`; for libtailscale detail: `docker compose exec quacktail-server tail -50 /work/server.log`
