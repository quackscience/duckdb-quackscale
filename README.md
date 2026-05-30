# QuackScale

**QuackScale** embeds a [Tailscale](https://tailscale.com) / WireGuard client ([libtailscale](https://github.com/tailscale/libtailscale)) inside DuckDB so a process can join a private tailnet and reach peers over encrypted mesh networking — without a separate VPN sidecar, tunnel daemon, or public ingress.

Combined with DuckDB’s [Quack](https://duckdb.org/docs/current/quack/overview) HTTP protocol, you get **QuackTail**: SQL engines that discover each other on `100.x.x.x` / MagicDNS, authenticate callers, and run `ATTACH`, `quack_query`, and DuckLake workloads across the mesh.

```sql
LOAD quack;       -- HTTP server, ATTACH, quack_query
LOAD quackscale;  -- tailnet join, dial, forward, serve — all from SQL
```

QuackScale does **not** replace `quack` or `ducklake`. It provides the **network layer** Quack needs on a tailnet.

| Goal | Start here |
|------|------------|
| Design a deployment (patterns, DuckLake, demos) | [docs/GUIDE.md](docs/GUIDE.md) |
| Tailnet login, Headscale, Quack tokens | [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md) |
| Two-node proof (Docker Compose) | [examples/README.md](examples/README.md) |
| Build from source, CI, roadmap | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
| Full doc index | [docs/README.md](docs/README.md) |

---

## Why embedded Tailscale in DuckDB?

Traditional setups expose DuckDB/Quack on localhost or bind a public IP and add TLS, firewalls, and VPN appliances around it. QuackScale flips that model: **each DuckDB process carries its own tailnet identity** and speaks WireGuard to peers that your control plane already trusts.

| Benefit | What it means for you |
|---------|------------------------|
| **WireGuard encryption** | Traffic between tailnet nodes is encrypted end-to-end ([Noise](https://tailscale.com/blog/how-tailscale-works) / WireGuard). Quack HTTP rides inside that mesh — not cleartext on the public internet. |
| **No public listen by default** | Nodes get tailnet IPs (`100.64.0.0/10`). Quack binds loopback; `tailscale_serve_local` exposes **9494** only on the mesh. Nothing needs a world-routable address. |
| **Identity-based access** | Tailscale or [Headscale](https://github.com/juanfont/headscale) ACLs decide **which nodes** may open TCP to a peer. Quack tokens decide **which callers** may run SQL — [defense in depth](docs/AUTHENTICATION.md). |
| **No sidecar VPN** | libtailscale (tsnet) runs in-process. One binary, one lifecycle — ideal for containers, batch jobs, and edge nodes that should not run `tailscaled` separately. |
| **NAT traversal** | Mesh connectivity works across NATs and regions (direct paths or DERP relays). DuckDB nodes on laptops, cloud VMs, and on-prem can mesh without manual port forwarding. |
| **Self-hosted or SaaS control plane** | Same SQL API for [Tailscale](https://tailscale.com) and [Headscale](https://headscale.net/) — set `control_url` and a preauth key. |
| **Manage the tailnet from SQL** | Join, status, ping, forward, serve, and teardown are **`CALL` table functions** — scriptable in migrations, init SQL, and orchestration hooks. |

QuackScale handles **reachability and transport**. You still configure [Quack application auth](docs/AUTHENTICATION.md) (`QUACK_TAILNET_TOKEN`, secrets, allowlists) for who may execute SQL.

---

## How QuackTail fits together

```text
  Server (long-lived)                    Client (job / laptop)
  ───────────────────                    ─────────────────────
  CALL tailscale_up(...)                 CALL tailscale_up(...)
  CALL quack_serve(127.0.0.1:9494)       CALL tailscale_quack_forward(host => …)
  CALL tailscale_serve_local(:9494)            │
         │                                       ▼
         │         WireGuard mesh               quack:127.0.0.1:19494
         └◄──────── tailscale_dial ────────────┘
                    ATTACH / quack_query / attach_ducklake
```

**`tailscale_quack_forward`** is required when the client uses embedded tsnet: Quack speaks normal HTTP/TCP, which kernel routing does not send over the tailnet by itself. The forwarder listens on loopback and dials peers via `tailscale_dial`.

End-to-end recipes and DuckLake patterns: **[docs/GUIDE.md](docs/GUIDE.md)**.

---

## SQL API (`LOAD quackscale`)

Use **`CALL`** for table functions (same style as `CALL quack_serve`). Parameters for `tailscale_up` / `tailscale_login`: `hostname`, `authkey` (or `TS_AUTHKEY` env), `control_url`, `state_dir`, `ephemeral`, `loopback_proxy`.

### Tailnet lifecycle

| Command | Purpose |
|---------|---------|
| [`CALL tailscale_up(...)`](docs/AUTHENTICATION.md#tailnet-login-tailscale-saas) | Join the tailnet (blocking). Server automation and CI. |
| [`CALL tailscale_login(...)`](docs/AUTHENTICATION.md#developer-laptop) | Non-blocking join; returns `login_url` for browser auth. |
| [`CALL tailscale_login_status()`](docs/AUTHENTICATION.md#developer-laptop) | Poll login state (`starting` / `needs_login` / `up` / `error`). |
| [`CALL tailscale_status()`](docs/GUIDE.md#observability) | Linked?, running, hostname, tailnet IPs. |
| [`CALL tailscale_down()`](docs/GUIDE.md#standard-client-connection-recipe) | Stop forwarder and close tsnet. **Required** for one-shot clients or the process hangs. |

### Connectivity on the mesh

| Command | Purpose |
|---------|---------|
| [`CALL tailscale_serve_local(port => 9494)`](docs/GUIDE.md#use-case-1--remote-duckdb-hub-pattern-a) | Tailscale Serve: tailnet TCP **→** `127.0.0.1:9494`. Run after local `quack_serve`. |
| [`CALL tailscale_ping(host => 'peer', port => 9494)`](docs/GUIDE.md#observability) | TCP dial to a peer over tsnet — readiness before Quack `ATTACH`. |
| [`CALL tailscale_quack_forward(host => 'peer', port => 9494)`](docs/GUIDE.md#standard-client-connection-recipe) | Listen on loopback; dial peer for each Quack HTTP connection. Returns `quack_uri`. **Preferred client path.** |
| [`CALL tailscale_quack_proxy()`](docs/DEVELOPMENT.md) | Legacy SOCKS proxy + `ALL_PROXY` — deprecated; use `tailscale_quack_forward`. |
| [`CALL tailscale_proxy_status()`](docs/DEVELOPMENT.md) | Legacy SOCKS status. |

### Quack on tailnet (helpers; `LOAD quack` required for serve/attach)

| Function | Purpose |
|----------|---------|
| `quack_uri()` | This node’s client-facing `quack:<host>:9494` (MagicDNS or tailnet IP). |
| `quack_token()` | Shared Quack secret from `QUACK_TAILNET_TOKEN` / `QUACK_TOKEN` env. |
| [`CALL quack_discover(port => 9494)`](docs/GUIDE.md#finding-peers) | All `quack:` URIs this node advertises on the tailnet. |

Core Quack (`LOAD quack`): `quack_serve`, `quack_stop`, `ATTACH`, `quack_query`, etc.

### Remote DuckLake

| Command | Purpose |
|---------|---------|
| [`CALL attach_ducklake(uri, ...)`](docs/GUIDE.md#use-case-2--ducklake-on-the-server-patterns-b--b) | Local views over a remote DuckLake catalog when Parquet lives on the server. |

---

## Authentication (two layers)

| Layer | Question | Details |
|-------|----------|---------|
| **Tailnet** | Is this machine on our mesh? | [docs/AUTHENTICATION.md — Tailnet login](docs/AUTHENTICATION.md#tailnet-login-tailscale-saas) |
| **Quack** | May this caller run SQL? | [docs/AUTHENTICATION.md — Quack tokens](docs/AUTHENTICATION.md#quack-http-tokens) |

```sh
export TS_AUTHKEY='tskey-auth-...'              # or Headscale preauth key
export QUACK_TAILNET_TOKEN='shared-quack-secret' # same on servers and clients
```

Do **not** copy the random `auth_token` from each `CALL quack_serve`. Use a fleet-wide shared token or [Quack allowlist](https://duckdb.org/docs/current/quack/security#overriding-authentication).

---

## Quick start

### Server

```sh
export TS_AUTHKEY='tskey-auth-...'
export QUACK_TAILNET_TOKEN='your-shared-quack-token'
./build/release/duckdb
```

```sql
LOAD quack;
LOAD quackscale;

CALL tailscale_up(
    hostname => 'my-duckdb-node',
    state_dir => '~/.local/share/duckdb/quackscale'
);

CALL quack_serve(
    'quack:127.0.0.1:9494',
    allow_other_hostname => true,
    token => quack_token()
);
CALL tailscale_serve_local(port => 9494);

FROM quack_discover();
```

Long-lived servers: persistent `state_dir`, **no** `tailscale_down()`. Headscale: add `control_url` and preauth key — [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md).

### Client

```sql
LOAD quackscale;
LOAD quack;

CALL tailscale_up(hostname => 'my-client', state_dir => '…', …);
CALL tailscale_quack_forward(host => 'my-duckdb-node', port => 9494, local_port => 19494);

CREATE SECRET (
    TYPE quack,
    TOKEN 'your-shared-quack-token',
    SCOPE 'quack:127.0.0.1:19494'
);

ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack, DISABLE_SSL true);
FROM remote.query('SELECT 42');

DETACH remote;
CALL tailscale_down();
```

Full client recipe (probe, DuckLake, compose markers): **[docs/GUIDE.md](docs/GUIDE.md)**.

---

## Build

**Prerequisites:** C++17, cmake, make or ninja, Go 1.25+ (CGO; CMake bootstraps Go 1.25.5 if needed), DuckDB with core **`quack`**, git submodules (`duckdb`, `extension-ci-tools`, `third_party/libtailscale`).

```sh
git clone --recurse-submodules https://github.com/quackscience/duckdb-quackscale.git
cd duckdb-quackscale
GEN=ninja make release
```

- `./build/release/duckdb` — shell with extension  
- `./build/release/extension/quackscale/quackscale.duckdb_extension` — loadable binary  

Stub build without Tailscale: `make CMAKE_VARS="-DQUACKSCALE_WITH_TAILSCALE=OFF"`.

Docker images (source build + verify): **[examples/README.md](examples/README.md)**.

---

## Tests

```sh
make test
```

Unit tests need no live tailnet. **E2e (manual):** [`.github/workflows/headscale-e2e.yml`](.github/workflows/headscale-e2e.yml) — release binary, `workflow_dispatch` only. **Local full demo:** [examples/README.md](examples/README.md). **PR smoke:** [headscale-integration.yml](.github/workflows/headscale-integration.yml).

---

## License

MIT (extension template). libtailscale is [BSD-3-Clause](https://github.com/tailscale/libtailscale/blob/main/LICENSE).

Based on [duckdb/extension-template](https://github.com/duckdb/extension-template).
