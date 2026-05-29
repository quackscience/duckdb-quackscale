# QuackScale documentation

## Start here

1. **[../README.md](../README.md)** — build, quick start, SQL reference  
2. **[AUTHENTICATION.md](AUTHENTICATION.md)** — Tailscale (`TS_AUTHKEY`, `tailscale_up`, browser login)  
3. **[HEADSCALE.md](HEADSCALE.md)** — self-hosted [Headscale](https://github.com/juanfont/headscale) (`control_url`, preauth keys)  
4. **[QUACK_AUTH.md](QUACK_AUTH.md)** — Quack tokens for QuackTail (`QUACK_TAILNET_TOKEN`, shared secrets, auth macros)  
5. **[PLAN.md](PLAN.md)** — architecture, API roadmap, risks  

## QuackTail authentication at a glance

| Step | Layer | Action |
|------|--------|--------|
| 1 | Tailscale | `export TS_AUTHKEY=...` → `CALL tailscale_up(hostname => 'node-a', ...)` |
| 2 | Quack (server) | `export QUACK_TAILNET_TOKEN=...` → `CALL quack_serve(quack_uri(), allow_other_hostname => true, token => quack_token())` |
| 3 | Quack (client) | Same token → `CREATE SECRET (TYPE quack, TOKEN '...', SCOPE 'quack:node-a:9494')` → `ATTACH ... (TYPE quack, DISABLE_SSL true)` |

Do **not** rely on the random `auth_token` column from default `quack_serve`. Use a **shared** token or [override `quack_authentication_function`](https://duckdb.org/docs/current/quack/security#overriding-authentication).
