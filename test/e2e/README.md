# Headscale QuackTail e2e

Headscale stays up; **server** and **client** DuckDB containers run concurrently.

## Server bind mode (default: `loopback_serve`)

Quack on loopback; **`tailscale_serve_local`** publishes port 9494 on the tailnet.

```sql
CALL quack_serve('quack:127.0.0.1:9494', allow_other_hostname => true, token => quack_token());
CALL tailscale_serve_local(port => 9494);
```

## Client (no curl — extension + quack only)

One DuckDB `-init client_session.sql` session:

1. `CALL tailscale_up(...)`
2. `CALL tailscale_ping(host => 'quacktail-server', port => 9494)` — tsnet dial over tailnet
3. `FROM quack_query(...)` — Quack HTTP probe (same stack as ATTACH)
4. `ATTACH`, insert, `PASSED` summary

`/etc/hosts` maps `quacktail-server` → server tailnet IP. Client retries the session until `PASSED` (mesh + serve warmup).

## Flow

1. `docker run -d` server → `tailscale_up` → `quack_serve(127.0.0.1)` → `tailscale_serve_local`
2. Resolve server IP from Headscale; client maps hostname in `/etc/hosts`
3. Client `-init client_session.sql` with `tailscale_ping` + `quack_query` + ATTACH
