# Headscale QuackTail e2e

Headscale stays up; **server** and **client** DuckDB containers run concurrently.

## Server bind mode (default: `tailnet`)

```sql
CALL quack_serve(quack_uri(), allow_other_hostname => true, token => quack_token());
```

Quack listens on the tailnet address from `tailscale_up` — **not** loopback + `tailscale_serve_local` (curl can pass through Serve while Quack ATTACH still fails).

Legacy loopback + Serve: `E2E_QUACK_SERVE_MODE=loopback_serve`.

## Client

- ATTACH URI matches server: `quack:quacktail-server:9494` (`E2E_QUACK_ATTACH_HOST=hostname`)
- `/etc/hosts` maps `quacktail-server` → server tailnet IP
- `quack_query('SELECT 1')` probe runs before ATTACH (same HTTP stack)

## Flow

1. `docker run -d` server → `tailscale_up` → `quack_serve(quack_uri(), ...)`
2. Resolve server IP from Headscale
3. `docker run -d` client (while server runs) → `tailscale_up` → probe → ATTACH
