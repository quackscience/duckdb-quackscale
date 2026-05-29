# QuackScale

DuckDB community extension that joins a [Tailscale](https://tailscale.com) tailnet and exposes the [Quack](https://duckdb.org/docs/current/quack/overview) remote protocol on tailnet addresses — so DuckDB peers can `ATTACH` and query each other over easily and securely.

**QuackTail** = DuckDB + `quack` (core) + `quackscale` (this extension) on the same tailnet.

QuackScale does **not** replace the core `quack` extension. Load both:

```sql
LOAD quack;       -- HTTP server, quack_serve, ATTACH quack:...
LOAD quackscale;  -- tailscale_up, quack_uri, quack_token, ...
```

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/PLAN.md](docs/PLAN.md) | Architecture, roadmap, risks |
| [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md) | **Tailscale** — auth keys, browser login, `TS_AUTHKEY` |
| [docs/HEADSCALE.md](docs/HEADSCALE.md) | **Headscale** — self-hosted control plane (`control_url`, preauth keys) |
| [docs/QUACK_AUTH.md](docs/QUACK_AUTH.md) | **Quack** — shared tokens, env provisioning, overriding `quack_authentication_function` |

## Authentication (two layers)

QuackTail uses **two separate** credential systems. Both are required in production unless you deliberately relax Quack auth on a locked-down tailnet.

| Layer | Question | Provisioned via | QuackScale / Quack |
|-------|----------|-----------------|-------------------|
| **Tailscale** | Is this process on our tailnet? | `TS_AUTHKEY`, `CALL tailscale_up`, or browser login | `tailscale_*` SQL — [AUTHENTICATION.md](docs/AUTHENTICATION.md) |
| **Headscale** (optional) | Same, self-hosted control server | `control_url` + Headscale preauth key | Same SQL — [HEADSCALE.md](docs/HEADSCALE.md) |
| **Quack** | May this caller run SQL on this server? | Shared env token, DuckDB secrets, or custom auth macro | `quack_token()`, `quack_serve(token => ...)`, `CREATE SECRET` — see [QUACK_AUTH.md](docs/QUACK_AUTH.md) |

**Do not** copy the random `auth_token` column from each `CALL quack_serve` by hand. For a fleet of servers and clients, use a **network-wide shared token** (or allowlist) as described in [Quack security — Overriding authentication](https://duckdb.org/docs/current/quack/security#overriding-authentication).

```sh
# Same value on every QuackTail server and client (K8s secret, systemd, etc.)
export QUACK_TAILNET_TOKEN='your-shared-secret-at-least-4-chars'
export TS_AUTHKEY='tskey-auth-...'   # Tailscale — separate secret
```

## Prerequisites

- C++17 toolchain, `cmake`, `make` (or `ninja` + `ccache`)
- **Go 1.25+** with CGO (for libtailscale; CMake bootstraps Go 1.25.5 automatically if the host toolchain is older)
- DuckDB with core **`quack`** extension (e.g. v1.5.3+)
- Git submodules: `duckdb`, `extension-ci-tools`, `third_party/libtailscale`

```sh
git clone --recurse-submodules https://github.com/quackscience/duckdb_tailscale.git
cd duckdb_tailscale
git submodule update --init --recursive   # if you cloned without --recurse-submodules
```

## Build

```sh
make
# faster rebuilds: GEN=ninja make
```

Artifacts:

- `./build/release/duckdb` — shell with extension preloaded
- `./build/release/extension/quackscale/quackscale.duckdb_extension` — loadable binary

Disable Tailscale embedding (stub build, no Go):

```sh
make CMAKE_VARS="-DQUACKSCALE_WITH_TAILSCALE=OFF"
```

## Quick start — QuackTail server

Set env vars **before** starting DuckDB (see [authentication](#authentication-two-layers)):

```sh
export TS_AUTHKEY='tskey-auth-...'
export QUACK_TAILNET_TOKEN='your-shared-quack-token'
./build/release/duckdb
```

```sql
LOAD quack;
LOAD quackscale;

-- 1) Join tailnet
CALL tailscale_up(
    hostname => 'my-duckdb-node',
    state_dir => '~/.local/share/duckdb/quackscale'
);

-- 2) Quack on loopback; Tailscale Serve exposes port 9494 on the tailnet
CALL quack_serve(
    'quack:127.0.0.1:9494',
    allow_other_hostname => true,
    token => quack_token()
);
CALL tailscale_serve_local(port => 9494);

-- 3) See what clients should connect to
CALL quack_discover();
```

For **local-only** (no tailnet), the [Quack docs](https://duckdb.org/docs/current/quack/overview) use `CALL quack_serve('quack:localhost', token => ...)` and `ATTACH 'quack:localhost' AS remote (TYPE quack)` with `SCOPE 'quack:localhost'` — plain HTTP is automatic for local URIs.

## Quick start — QuackTail client

Same `QUACK_TAILNET_TOKEN` on the client machine:

```sql
LOAD quack;

CREATE SECRET (
    TYPE quack,
    TOKEN 'your-shared-quack-token',
    SCOPE 'quack:my-duckdb-node:9494'
);

ATTACH 'quack:my-duckdb-node:9494' AS remote (
    TYPE quack,
    DISABLE_SSL true
);

FROM remote.query('SELECT 42');
```

Use the hostname from `tailscale_up(hostname => ...)` and Quack’s default port **9494**. Details and multi-token setups: [docs/QUACK_AUTH.md](docs/QUACK_AUTH.md).

### Tailscale login (first-time / laptop)

| Scenario | Command |
|----------|---------|
| Server / automation | `export TS_AUTHKEY=...` then `CALL tailscale_up(...)` |
| Interactive browser | `CALL tailscale_login(...)` → open `login_url` → `CALL tailscale_login_status()` until `status = 'up'` |
| Repeat visits | Reuse `state_dir` — usually no browser |

See [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md).

### Headscale (self-hosted tailnet)

[Headscale](https://github.com/juanfont/headscale) is API-compatible with Tailscale’s control server — no extra QuackScale APIs:

```sql
CALL tailscale_up(
    hostname => 'my-duckdb-node',
    control_url => 'https://headscale.example.com',
    authkey => '<headscale preauth key>',
    state_dir => '~/.local/share/duckdb/quackscale'
);
```

Example: [examples/headscale_quacktail.sql](examples/headscale_quacktail.sql). CI runs [`.github/workflows/headscale-integration.yml`](.github/workflows/headscale-integration.yml).

### Quack auth modes (pick one)

| Mode | When | How |
|------|------|-----|
| **Shared env token** | Default for QuackTail fleets | `QUACK_TAILNET_TOKEN` + `quack_token()` on serve; matching `CREATE SECRET` or `TOKEN` on clients |
| **Multi-token allowlist** | Teams, rotation, multiple clients | `SET GLOBAL quack_authentication_function = '...'` + token table — [Quack docs](https://duckdb.org/docs/current/quack/security#example-multi-token-table) |
| **Developer mode** | Lab tailnet only | Auth macro always `true` — [Quack docs](https://duckdb.org/docs/current/quack/security#example-developer-mode-always-allow) |

Full walkthrough: [docs/QUACK_AUTH.md](docs/QUACK_AUTH.md).

## SQL reference

Load with `LOAD quackscale;`. Use **`CALL`** for table functions (same style as `CALL quack_serve`), not `SELECT` / `FROM`.

### Tailscale (`quackscale` extension)

| Command | Description |
|---------|-------------|
| `CALL tailscale_up(...)` | Join tailnet; params: `hostname`, `state_dir`, `control_url`, `ephemeral`, `authkey` / `TS_AUTHKEY` |
| `CALL tailscale_login(...)` | Non-blocking join; returns `login_url` for browser auth |
| `CALL tailscale_login_status()` | Poll login (`starting` / `needs_login` / `up` / `error`) |
| `CALL tailscale_status()` | libtailscale linked?, running, hostname, tailnet IPs |
| `CALL tailscale_quack_forward(host => 'peer', port => 9494)` | Localhost TCP → `tailscale_dial` (preferred for Quack ATTACH; no ALL_PROXY) |
| `CALL tailscale_quack_proxy()` | Legacy SOCKS + ALL_PROXY |
| `CALL tailscale_proxy_status()` | Legacy SOCKS status |

### Quack on tailnet (helpers; requires core `quack` for `quack_serve`)

| Function | Description |
|----------|-------------|
| `quack_uri()` | Client-facing `quack:<host>:9494` for discovery/ATTACH |
| `CALL tailscale_serve_local(port => 9494)` | Tailscale Serve: tailnet TCP → `127.0.0.1:9494` (run after local `quack_serve`) |
| `CALL tailscale_ping(host => 'peer', port => 9494)` | tsnet TCP dial to peer (readiness check before Quack ATTACH) |
| `quack_token()` | Shared Quack token from `QUACK_TAILNET_TOKEN` / `QUACK_TOKEN` env |
| `CALL quack_discover()` | All `quack:` URIs this node advertises (`magicdns` / `tailnet_ip`) |

Core Quack (`LOAD quack`): `quack_serve`, `quack_stop`, `ATTACH`, `quack_query`, etc.

## Tests

```sh
make test
```

SQL unit tests do not require a live tailnet or `QUACK_TAILNET_TOKEN`.

### Releases and e2e

QuackScale is not published to the DuckDB community extension repo yet. **GitHub releases** ship a linux `duckdb` binary with quackscale embedded ([`.github/workflows/Release.yml`](.github/workflows/Release.yml), triggered on **Release published**).

Headscale e2e ([`.github/workflows/headscale-e2e.yml`](.github/workflows/headscale-e2e.yml)) is **manual only** — it downloads a release binary (default: `v1.0.3`) and runs [`scripts/ci_headscale_e2e.sh`](scripts/ci_headscale_e2e.sh). See [test/e2e/README.md](test/e2e/README.md).

## Based on

[duckdb/extension-template](https://github.com/duckdb/extension-template)

## License

MIT (extension template). libtailscale is [BSD-3-Clause](https://github.com/tailscale/libtailscale/blob/main/LICENSE).
