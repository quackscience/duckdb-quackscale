# Tailscale authentication (QuackScale)

This document covers **only Tailscale** — getting a DuckDB process onto your tailnet.

For **Quack HTTP tokens** (shared secrets between QuackTail servers and clients), see **[QUACK_AUTH.md](QUACK_AUTH.md)**. You need both layers in production.

| Doc | Topic |
|-----|--------|
| [QUACK_AUTH.md](QUACK_AUTH.md) | Shared `QUACK_TAILNET_TOKEN`, `quack_token()`, `CREATE SECRET`, overriding `quack_authentication_function` |
| [PLAN.md](PLAN.md) | Architecture and roadmap |
| [../README.md](../README.md) | Quick start and SQL reference |

## How it fits QuackTail

```
  Client                                    Server
    │                                         │
    │  ① Tailscale (wire)                     │  CALL tailscale_up
    │     TS_AUTHKEY / login                  │  → node on tailnet
    │                                         │
    │  ② Quack HTTP :9494                     │  CALL quack_serve(..., token => quack_token())
    │     QUACK_TAILNET_TOKEN                 │  → SQL API on tailnet IP
    └─────────────────────────────────────────┘
```

Tailscale ACLs control **who can open TCP to port 9494**. Quack tokens control **who may run SQL** once connected. See [Quack security](https://duckdb.org/docs/current/quack/security).

---

QuackScale embeds [libtailscale](https://github.com/tailscale/libtailscale) (Go **tsnet**). Joining a tailnet matches other embedded Tailscale apps: **auth keys**, **environment variables**, **persisted state**, or **interactive browser login**.

## How tsnet authenticates

| Mode | How | Best for |
|------|-----|----------|
| **Auth key** | `authkey` in `CALL tailscale_up`, or `TS_AUTHKEY` env | Servers, CI, automation |
| **Persisted state** | `state_dir` — keys on disk after first login | Laptops, repeat use |
| **Interactive login** | Login URL in logs; open in browser | First-time dev setup |
| **Headscale** | `control_url` → your [Headscale](https://github.com/juanfont/headscale) URL + Headscale preauth key | Self-hosted tailnet (Tailscale-compatible) |
| **Test control** | `control_url` → [tstestcontrol](https://github.com/tailscale/libtailscale/tree/main/tstestcontrol) | libtailscale unit tests |

The libtailscale C API exposes `tailscale_set_authkey`, `tailscale_set_dir`, `tailscale_set_control_url`, `tailscale_set_logfd`, and `tailscale_up`. There is no C API that returns a login URL directly — tsnet prints `https://login.tailscale.com/a/…` on the **log stream** (see [libtailscale Python README](https://github.com/tailscale/libtailscale/blob/main/python/README.md)).

Reference: [tsnet.Server · Tailscale Docs](https://tailscale.com/kb/1522/tsnet-server).

## Loopback forward (Quack HTTP over the tailnet)

Embedded tsnet can dial peers (`tailscale_ping`), but **Quack uses normal HTTP/TCP**. Kernel sockets cannot reach tailnet IPs without help.

The native libtailscale path ([tsnetctest](https://github.com/tailscale/libtailscale/blob/main/tsnetctest/tsnetctest.go)) uses `tailscale_dial`. QuackScale exposes that for Quack via a **localhost TCP forwarder** — no SOCKS, no `ALL_PROXY`:

```sql
CALL tailscale_up(hostname => 'my-client', authkey => '...', state_dir => '/var/lib/duckdb/ts');
CALL tailscale_quack_forward(host => 'peer-hostname', port => 9494, local_port => 19494);
-- quack_uri => quack:127.0.0.1:19494

CREATE SECRET (TYPE quack, TOKEN '...', SCOPE 'quack:127.0.0.1:19494');
ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack, DISABLE_SSL true);
```

`tailscale_quack_forward` listens on `127.0.0.1:local_port` and dials `host:port` over tsnet for each Quack HTTP connection.

Legacy: `CALL tailscale_quack_proxy()` (SOCKS + `ALL_PROXY`) remains but is deprecated.

## Recommended patterns

### Production / servers — auth key

Create a [reusable or ephemeral auth key](https://tailscale.com/kb/1085/auth-keys), then:

```sh
export TS_AUTHKEY='tskey-auth-...'
```

```sql
LOAD quackscale;

CALL tailscale_up(
    hostname => 'analytics-duck-1',
    state_dir => '/var/lib/duckdb/tailscale'
);
```

Or pass the key in SQL: `CALL tailscale_up(authkey => 'tskey-auth-...', ...)`.

Do not commit auth keys in SQL files — use env or your orchestrator’s secret store.

### Developer laptop — browser login

`CALL tailscale_up()` **blocks** until login completes. For a non-blocking flow:

```sql
LOAD quackscale;

CALL tailscale_login(
    hostname => 'my-laptop-duckdb',
    state_dir => '~/.local/share/duckdb/quackscale'
);
-- Returns status, login_url, message

CALL tailscale_login_status();  -- poll until status = 'up'
```

Open `login_url` in a browser and approve the device. tsnet may also print the same URL on DuckDB stderr.

After the first login, reuse `state_dir`; later `CALL tailscale_up()` usually needs no browser.

### Self-hosted — Headscale

[Headscale](https://github.com/juanfont/headscale) implements the Tailscale control server API. QuackScale uses the same knobs as the Tailscale CLI:

```sql
CALL tailscale_up(
    hostname => 'my-node',
    control_url => 'https://headscale.example.com',
    authkey => '<headscale preauth key>',
    state_dir => '/var/lib/duckdb/headscale-state'
);
```

Create keys with `headscale preauthkeys create`. Full walkthrough: **[HEADSCALE.md](HEADSCALE.md)** and [examples/headscale_quacktail.sql](../examples/headscale_quacktail.sql).

### CI / tests

| Workflow | Control plane |
|----------|----------------|
| [headscale-integration.yml](../.github/workflows/headscale-integration.yml) | Docker Headscale + `CALL tailscale_up` |
| [headscale-e2e.yml](../.github/workflows/headscale-e2e.yml) | Two-node QuackTail e2e (linux, manual dispatch) |
| [libtailscale-integration.yml](../.github/workflows/libtailscale-integration.yml) | libtailscale `tstestcontrol` (`go test`) |

## SQL surface (Tailscale only)

Invoke with **`CALL`**, like Quack:

| Command | Purpose |
|---------|---------|
| `CALL tailscale_up(...)` | Blocking join; `authkey` or `TS_AUTHKEY`; optional `state_dir`, `control_url`, `ephemeral` |
| `CALL tailscale_login(...)` | Background join; returns `login_url` |
| `CALL tailscale_login_status()` | Poll `status`, `login_url`, tailnet IPs |
| `CALL tailscale_status()` | Linked?, running, hostname, IPs |

## Environment variables

| Variable | Effect |
|----------|--------|
| `TS_AUTHKEY` | Tailscale auth key if not passed in `CALL tailscale_up` |
| `TSNET_FORCE_LOGIN` | Force interactive login even if an auth key is set (rare) |

**Quack tokens are separate:** `QUACK_TAILNET_TOKEN` / `QUACK_TOKEN` — see [QUACK_AUTH.md](QUACK_AUTH.md).

## Security notes

- Treat `TS_AUTHKEY` like any infrastructure secret.
- Tailnet [ACLs](https://tailscale.com/kb/1018/acls) should restrict who can reach peer TCP **9494** (Quack).
- QuackScale advertises `quack:` URIs; it does not replace Quack’s application-level auth.

## Related reading

- [QUACK_AUTH.md](QUACK_AUTH.md) — Quack / QuackTail application tokens
- [HEADSCALE.md](HEADSCALE.md) — self-hosted Headscale
- [libtailscale](https://github.com/tailscale/libtailscale)
- [Headscale](https://github.com/juanfont/headscale)
- [Tailscale auth keys](https://tailscale.com/kb/1085/auth-keys)
