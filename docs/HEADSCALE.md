# Headscale (self-hosted control plane)

[Headscale](https://github.com/juanfont/headscale) is an open-source, self-hosted implementation of the **Tailscale control server**. Tailscale clients (and embedded **tsnet** / [libtailscale](https://github.com/tailscale/libtailscale)) treat it like Tailscale SaaS: you point at a custom **login server** URL and register with a **preauth key** or browser flow.

QuackScale adds **no Headscale-specific code**. The integration curve is effectively **zero**: use `control_url` on `CALL tailscale_up` / `CALL tailscale_login` the same way you would pass `tailscale up --login-server`.

| Topic | Doc |
|-------|-----|
| Tailscale SaaS auth keys, browser login | [AUTHENTICATION.md](AUTHENTICATION.md) |
| Quack HTTP tokens on the tailnet | [QUACK_AUTH.md](QUACK_AUTH.md) |
| Example SQL | [../examples/headscale_quacktail.sql](../examples/headscale_quacktail.sql) |

## Mapping: Tailscale CLI → QuackScale

| Tailscale CLI | QuackScale |
|---------------|------------|
| `tailscale up --login-server https://hs.example.com` | `control_url => 'https://hs.example.com'` |
| `--authkey tskey-...` or Headscale preauth key | `authkey => '...'` or `TS_AUTHKEY` |
| `--hostname` | `hostname => '...'` |
| state under `~/.local/share/tailscale` | `state_dir => '...'` |

Headscale preauth keys are created with `headscale preauthkeys create` (not the Tailscale admin UI). See [Headscale — Getting started](https://headscale.net/stable/usage/getting-started/).

## Minimal server setup

1. Install and configure Headscale ([releases](https://github.com/juanfont/headscale/releases), [docs](https://headscale.net/)).
2. Set `server_url` in `config.yaml` to the URL **clients** use (e.g. `https://headscale.my.net`).
3. Create a user and reusable key:

```sh
headscale users create quackscale
headscale preauthkeys create --user 1 --reusable --expiration 168h
```

4. On each DuckDB host:

```sh
export HEADSCALE_URL='https://headscale.my.net'
export HEADSCALE_PREAUTH_KEY='<preauth-key>'
export QUACK_TAILNET_TOKEN='<shared-quack-token>'
./build/release/duckdb
```

```sql
LOAD quack;
LOAD quackscale;

CALL tailscale_up(
    hostname => 'duckdb-node-a',
    control_url => getenv('HEADSCALE_URL'),
    authkey => getenv('HEADSCALE_PREAUTH_KEY'),
    state_dir => '/var/lib/duckdb/headscale-state'
);

CALL quack_serve(quack_uri(), allow_other_hostname => true, token => quack_token());
```

## Docker (lab / CI)

QuackScale CI uses a trimmed config under [`test/headscale/`](../test/headscale/):

```sh
docker run -d --name headscale \
  -p 127.0.0.1:8080:8080 \
  -v "$(pwd)/test/headscale/config-ci.yaml:/etc/headscale/config.yaml:ro" \
  -v "$(pwd)/test/headscale/policy.hujson:/etc/headscale/policy.hujson:ro" \
  -v headscale-data:/var/lib/headscale \
  headscale/headscale:0.28.0 serve
```

Then run the smoke script (after `make release`):

```sh
./scripts/ci_headscale_smoke.sh
```

## CI in this repository

| Workflow | What it validates |
|----------|-------------------|
| [libtailscale-integration.yml](../.github/workflows/libtailscale-integration.yml) | libtailscale `go test` (tstestcontrol) |
| [headscale-integration.yml](../.github/workflows/headscale-integration.yml) | Real Headscale + `CALL tailscale_up` + `tailscale_status` |

## Notes

- **DERP / NAT**: Headscale can use public Tailscale DERP relays (`derp.urls` in config) or your own; mesh connectivity depends on your network, not QuackScale.
- **TLS**: Production `server_url` should be `https://…`; lab CI uses plain `http://127.0.0.1:8080`.
- **MagicDNS**: Optional; `quack_uri()` prefers MagicDNS when Headscale provides it, else tailnet IP.
- Headscale is **not** affiliated with Tailscale Inc.; QuackScale links both projects as compatible stacks for QuackTail.

## Related

- [Headscale repository](https://github.com/juanfont/headscale)
- [Tailscale tsnet](https://tailscale.com/kb/1522/tsnet-server)
- [AUTHENTICATION.md](AUTHENTICATION.md)
