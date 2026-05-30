# QuackTail usage guide

QuackTail combines three ideas:

1. **Tailscale (or Headscale)** — private mesh network between nodes  
2. **Quack** — DuckDB’s HTTP client/server protocol (`quack:` URIs)  
3. **QuackScale** — joins DuckDB to the tailnet and bridges Quack across it  

Optional fourth ingredient: **DuckLake** — transactional lakehouse catalog + Parquet, which [integrates with Quack in DuckDB 1.5.3+](https://duckdb.org/2026/05/20/announcing-duckdb-153.html).

This guide is for **designing solutions**: what works today, how the compose demo maps to real deployments, and how to grow toward S3, many lakes, and fleet discovery.

---

## What you can build

| Idea | Building blocks | Tailnet role |
|------|-----------------|--------------|
| **Shared analytics DB** | `quack_serve` + client `ATTACH` | One DuckDB process serves tables; many clients query/write over Quack |
| **Edge ingest → central DuckDB** | Quack `INSERT` from clients | Laptops/containers push rows to a central server without copying files |
| **Lakehouse catalog server** | DuckLake on server + Quack | Server owns metadata + Parquet; clients query lake tables remotely |
| **Distributed lake readers** | `ducklake:quack:` + shared `DATA_PATH` | Catalog over Quack; Parquet on S3 or a path every reader can see |
| **Hybrid** | Quack primary DB + attached DuckLake | Operational tables via `remote.*`; historical Parquet via lake SQL |

QuackScale’s job is **not** to replace Quack or DuckLake — it makes them reachable on `100.x.x.x` / MagicDNS without exposing the public internet.

---

## Mental model

```text
┌─────────────────────────────────────────────────────────────────┐
│  quacktail-server (long-lived)                                   │
│  ┌─────────────┐   ┌──────────────┐   ┌─────────────────────────┐ │
│  │ quackscale  │──►│ tsnet        │──►│ tailnet :9494           │ │
│  │ tailscale_up│   │ serve_local  │   │ (MagicDNS / 100.x)      │ │
│  └─────────────┘   └──────────────┘   └───────────┬─────────────┘ │
│  ┌─────────────┐   quack_serve(127.0.0.1:9494)     │             │
│  │ quack       │◄────────────────────────────────┘             │
│  │ DuckDB      │   optional: ATTACH ducklake:… AS lake           │
│  └─────────────┘   Parquet → local disk or s3://bucket/prefix/   │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ tailscale_dial (encrypted)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  quacktail-client (batch job, laptop, second container)          │
│  tailscale_up → tailscale_quack_forward → quack:127.0.0.1:19494 │
│  ATTACH / quack_query / ducklake:quack:…                         │
│  CALL tailscale_down()  ← one-shot clients must tear down tsnet   │
└─────────────────────────────────────────────────────────────────┘
```

**Two credentials, always:**

| Layer | Question | Typical secret |
|-------|----------|----------------|
| Tailscale | Is this node on our mesh? | `TS_AUTHKEY` / Headscale preauth key |
| Quack | May this caller run SQL? | `QUACK_TAILNET_TOKEN` + `CREATE SECRET` |

See [AUTHENTICATION.md](AUTHENTICATION.md) and [QUACK_AUTH.md](QUACK_AUTH.md).

---

## Choose a pattern

```text
Need remote DuckDB tables (CRUD, dashboards)?
  └─► Pattern A: ATTACH 'quack:…' AS remote

Need lakehouse tables (Parquet, time travel, many files)?
  ├─► Server owns all Parquet?
  │     └─► Pattern B: quack_query(server, 'SELECT … FROM lake.t')
  └─► Clients can read same Parquet path (disk mount, S3, GCS)?
        └─► Pattern C: ATTACH 'ducklake:quack:…' AS lake (DATA_PATH 's3://…')

Both operational + lake on one node?
  └─► Pattern D: Hybrid (B + A in one session — mind ordering & limits)
```

### Pattern comparison

| Pattern | Client SQL | Parquet location | Best for |
|---------|------------|------------------|----------|
| **A — Quack attach** | `ATTACH 'quack:host:9494' AS remote` | Server DuckDB file / memory | Shared tables, multi-writer Quack |
| **B — quack_query lake** | `quack_query(uri, 'SELECT … FROM lake.t')` | Server-only paths | Compose demo fallback |
| **B+ — remote lake views** | `CALL attach_ducklake(...)` then `SELECT … FROM lake.t` | Server-only paths | **Preferred** when quackscale ≥ ducklake branch ([DUCKLAKE_REMOTE_ATTACH.md](DUCKLAKE_REMOTE_ATTACH.md)) |
| **C — ducklake:quack** | `ATTACH 'ducklake:quack:host' AS lake (DATA_PATH '…')` | Shared object store or mount | Fleet of readers, [DuckDB 1.5.3 pattern](https://duckdb.org/2026/05/20/announcing-duckdb-153.html) |
| **D — Hybrid** | B first, then A (separate statements) | Mixed | Apps + analytics on one tailnet node |

**Common mistake:** `SELECT * FROM remote.lake.inventory` — plain Quack attach exposes the **primary catalog only**, not nested attached DuckLake databases. Use pattern B or C instead.

---

## Use case 1 — Remote DuckDB over Quack (analytics hub)

**Story:** A central DuckDB node serves live tables to analysts and services on the tailnet.

### Server (long-lived)

```sql
LOAD quack;
LOAD quackscale;

CALL tailscale_up(
    hostname => 'analytics-hub',
    state_dir => '/var/lib/quacktail/hub',
    authkey => getenv('TS_AUTHKEY')  -- or Headscale preauth key
);

CREATE TABLE IF NOT EXISTS events (id INTEGER, payload VARCHAR, ts TIMESTAMP);
INSERT INTO events VALUES (1, 'hello-tailnet', now());

CALL quack_serve(
    'quack:127.0.0.1:9494',
    allow_other_hostname => true,
    token => quack_token()
);
CALL tailscale_serve_local(port => 9494);

-- What clients can use:
FROM quack_discover();
```

Keep this process running (systemd, Kubernetes, `quacktail-server` container). Do **not** call `tailscale_down()` on the server.

### Client (analyst laptop or job)

```sql
LOAD quack;
LOAD quackscale;

CALL tailscale_up(hostname => 'analyst-laptop', state_dir => '…', authkey => '…');

-- Forward tailnet Quack to loopback (required when client uses embedded tsnet)
CALL tailscale_quack_forward(host => 'analytics-hub', port => 9494, local_port => 19494);

CREATE SECRET (
    TYPE quack,
    TOKEN getenv('QUACK_TAILNET_TOKEN'),
    SCOPE 'quack:127.0.0.1:19494'
);

ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);

SELECT * FROM remote.events ORDER BY ts DESC LIMIT 10;
INSERT INTO remote.events VALUES (2, 'from-client', now());

-- One-shot jobs: tear down so the process exits
DETACH remote;
CALL tailscale_down();
```

**Expand:** add read replicas (multiple Quack servers), token allowlists ([Quack security](https://duckdb.org/docs/current/quack/security)), TLS termination in front of Quack for non-tailnet clients.

**Runnable demo:** [examples/README.md](../examples/README.md)

---

## Use case 2 — DuckLake on a QuackTail node (server owns Parquet)

**Story:** One node holds the DuckLake catalog and Parquet files; tailnet clients query inventory, metrics, or historical tables without copying the lake.

### Server

```sql
LOAD quack;
LOAD ducklake;
LOAD quackscale;

CALL tailscale_up(hostname => 'lake-server', …);

ATTACH 'ducklake:/data/lake/metadata/warehouse.ducklake' AS warehouse (
    DATA_PATH '/data/lake/parquet/'
);
USE warehouse;

CREATE TABLE IF NOT EXISTS inventory (item_id INTEGER, quantity INTEGER);
INSERT INTO inventory VALUES (101, 50), (102, 120);

CALL quack_serve('quack:127.0.0.1:9494', allow_other_hostname => true, token => quack_token());
CALL tailscale_serve_local(port => 9494);
```

Persist `/data/lake/` on disk, EBS, or sync to object storage out-of-band.

### Client — query via `quack_query` (verified in compose)

Run lake SQL **on the server** through stateless Quack HTTP. Use **`quack_query` before `ATTACH remote`** in the same session.

```sql
LOAD quack;
LOAD quackscale;

CALL tailscale_up(…);
CALL tailscale_quack_forward(host => 'lake-server', port => 9494, local_port => 19494);

CREATE SECRET (TYPE quack, TOKEN '…', SCOPE 'quack:127.0.0.1:19494');

-- Lake query (executes on server where `warehouse` is attached)
FROM quack_query(
    'quack:127.0.0.1:19494',
    'SELECT * FROM warehouse.inventory ORDER BY item_id',
    token => '…',
    disable_ssl => true
);

-- Optional: also use Quack attach for non-lake tables
ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);
SELECT * FROM remote.some_operational_table;

DETACH remote;
CALL tailscale_down();
```

**Expand to S3 on the server:** attach DuckLake with `DATA_PATH 's3://my-bucket/lake/parquet/'` ([DuckLake remote data path](https://duckdb.org/docs/stable/duckdb/guides/using_a_remote_data_path)). Clients keep using `quack_query` — they never need direct S3 credentials if the server holds them.

**Runnable demo:** [examples/ducklake/README.md](../examples/ducklake/README.md) (branch `ducklake`)

---

## Use case 3 — DuckLake over Quack with shared Parquet (client-side `DATA_PATH`)

**Story:** Catalog metadata flows over Quack; every reader resolves Parquet from a **shared** location (S3, GCS, NFS, read-only volume).

Official [DuckDB 1.5.3 example](https://duckdb.org/2026/05/20/announcing-duckdb-153.html):

### Server (catalog via Quack only)

```sql
LOAD quack;
LOAD quackscale;

CALL tailscale_up(hostname => 'lake-catalog', …);
CALL quack_serve('quack:127.0.0.1:9494', allow_other_hostname => true, token => quack_token());
CALL tailscale_serve_local(port => 9494);
```

### Client

```sql
LOAD ducklake;
LOAD quack;
LOAD quackscale;

CALL tailscale_up(…);
CALL tailscale_quack_forward(host => 'lake-catalog', port => 9494, local_port => 19494);

CREATE SECRET (TYPE quack, TOKEN '…', SCOPE 'quack:127.0.0.1:19494');

ATTACH 'ducklake:quack:127.0.0.1:19494' AS warehouse (
    DATA_PATH 's3://my-bucket/lake/parquet/'
);
-- Or: DATA_PATH '/mnt/shared/lake/parquet/' when NFS/K8s volume is mounted identically

SELECT * FROM warehouse.inventory;
INSERT INTO warehouse.inventory VALUES (103, 7);

CALL tailscale_down();
```

**When to choose this:** many readers, object-store Parquet, clients need local DuckLake semantics (attach, `USE`, DML) — not just single-statement `quack_query`.

**Requirements:**

- `DATA_PATH` must be reachable from **each client** (same bucket prefix or shared mount).  
- Configure DuckDB `httpfs` / cloud secrets on clients for `s3://` paths.  
- Align with [DuckLake attach options](https://duckdb.org/docs/stable/duckdb/attach) (`OVERRIDE_DATA_PATH`, etc.) when migrating paths.

---

## Use case 4 — Hybrid hub (Quack tables + DuckLake)

**Story:** Same tailnet node serves live operational tables **and** a lake catalog.

```text
analytics-hub
├── primary catalog     → remote.orders, remote.users     (Pattern A)
└── ATTACH ducklake AS warehouse → lake SQL via Pattern B or C
```

**Session discipline:**

1. Lake reads/writes: `quack_query(…, '… lake …')` **or** `ducklake:quack:` attach  
2. Operational tables: `ATTACH 'quack:…' AS remote`  
3. **One remote Quack read/write per SQL statement** ([QUACK_STREAMING.md](QUACK_STREAMING.md))  
4. End one-shot clients with `DETACH remote; CALL tailscale_down();`

---

## Connection recipe (tailnet client)

This sequence is what the compose e2e proves end-to-end:

```sql
LOAD quackscale;
CALL tailscale_up(hostname => '…', control_url => '…', authkey => '…', …);

CALL tailscale_quack_forward(host => 'peer-hostname', port => 9494, local_port => 19494);
CALL tailscale_ping(host => 'peer-hostname', port => 9494);  -- optional readiness

LOAD quack;
CREATE SECRET (TYPE quack, TOKEN '…', SCOPE 'quack:127.0.0.1:19494');

FROM quack_query('quack:127.0.0.1:19494', 'SELECT 1 AS probe', token => '…', disable_ssl => true);

-- Pattern B/C/D statements here …

ATTACH 'quack:127.0.0.1:19494' AS remote (TYPE quack);   -- Pattern A
-- …

DETACH remote;
CALL tailscale_down();
```

**Why `tailscale_quack_forward`?** Quack clients use normal HTTP/TCP. Embedded tsnet does not automatically route kernel TCP to tailnet IPs. The forwarder listens on `127.0.0.1:19494` and dials the peer via `tailscale_dial`.

**Why `tailscale_down`?** `tailscale_up` and the forwarder start background threads. One-shot DuckDB processes **hang after SQL finishes** unless you shut tsnet down.

---

## Finding peers on the tailnet

| Method | Scope | Status |
|--------|--------|--------|
| **`CALL tailscale_quack_forward(…)`** | Returns `quack_uri` for a **known** host | **Use today** |
| **`FROM quack_discover()`** on **this** node | Lists URIs this node would advertise | **Use today** (server-side) |
| **Config / service registry** | Helm values, Consul, env vars | **Use today** (operations) |
| **`quack_query(…, 'FROM quack_discover()')`** | Remote discover via Quack | **Avoid** — can deadlock on server |
| **`ducklake_discover()`** | Enriched discovery (lake + Quack) | **Planned** ([DUCKLAKE_TAILNET.md](DUCKLAKE_TAILNET.md)) |

**Practical fleet pattern today:**

1. Deploy lake/analytics nodes with stable Headscale/Tailscale hostnames (`analytics-hub`, `lake-server`).  
2. Document `quack_uri` from server bootstrap (`quack_discover()` in server init logs).  
3. Clients use MagicDNS names in `tailscale_quack_forward(host => 'analytics-hub', …)`.

**Multiple lakes on one server:** attach each with a distinct alias:

```sql
ATTACH 'ducklake:/data/sales.ducklake' AS sales (DATA_PATH 's3://bucket/sales/');
ATTACH 'ducklake:/data/support.ducklake' AS support (DATA_PATH 's3://bucket/support/');
```

Clients query with fully qualified names:

```sql
FROM quack_query(uri, 'SELECT * FROM sales.orders LIMIT 100', …);
FROM quack_query(uri, 'SELECT count(*) FROM support.tickets', …);
```

Each call is one statement — compatible with Quack streaming limits.

**Multiple Quack servers:** one forwarder port per peer (`19494`, `19495`, …) or sequential client sessions:

```sql
CALL tailscale_quack_forward(host => 'hub-a', port => 9494, local_port => 19494);
-- work with hub-a …
CALL tailscale_down();

CALL tailscale_up(…);  -- or reuse session if your app keeps tsnet up
CALL tailscale_quack_forward(host => 'hub-b', port => 9494, local_port => 19494);
```

---

## Expanding toward production

### Object storage (S3 / GCS / Azure)

| Role | Approach |
|------|----------|
| **Server owns lake** | `DATA_PATH 's3://bucket/prefix/'` in server `ATTACH ducklake:…`; clients use Pattern B |
| **Readers with credentials** | Pattern C — each client `ATTACH 'ducklake:quack:…' (DATA_PATH 's3://…')` |
| **Inline small files** | DuckLake [data inlining](https://duckdb.org/docs/stable/duckdb/ducklake) — future Quack+DuckLake perf wins on tailnet |

Load `httpfs` / cloud extensions and set secrets on whichever node reads/writes `s3://`.

### Persistence & lifecycle

| Deployment | `state_dir` | `tailscale_down` |
|------------|-------------|------------------|
| Long-lived server | Persistent volume | **Never** on steady state |
| Cron / CI job | Ephemeral or persistent | **Always** at end |
| Compose client profile | `/tmp/client-tailscale` | **Always** (see compose bootstrap) |

DuckLake metadata: file (`*.ducklake`), Postgres, or DuckDB file — see [DuckLake catalog options](https://duckdb.org/docs/stable/duckdb/attach).

### Security hardening

- Rotate `QUACK_TAILNET_TOKEN`; use [multi-token tables](https://duckdb.org/docs/current/quack/security#example-multi-token-table)  
- Prefer Headscale ACLs ([examples compose policy](../examples/docker-compose.yml))  
- Do not commit auth keys; use K8s secrets / systemd `EnvironmentFile`  
- Consider TLS in front of Quack for non-tailnet callers (QuackScale handles tailnet encryption only)

### Observability

- Server: `CALL tailscale_status()`, Quack logs, `/work/server.log` in compose  
- Client: `/work/client.out`  
- Readiness: `CALL tailscale_ping(host => 'peer', port => 9494)` before heavy queries

---

## Limitations & workarounds

| Issue | Workaround |
|-------|------------|
| `remote.lake.table` does not exist | Use `quack_query` or `ducklake:quack:` (patterns B/C) |
| Multiple Quack scans in one SQL | Split statements; see [QUACK_STREAMING.md](QUACK_STREAMING.md) |
| `quack_query` + `ATTACH remote` stalls | Run lake `quack_query` **before** attach; separate statements |
| Client hangs after success | `CALL tailscale_down()` (and `DETACH remote`) |
| `quack_query(…, quack_discover())` hangs | Discover locally or via known hostname — not via remote quack_query |
| Kernel TCP to `100.x:9494` fails from tsnet client | Use `tailscale_quack_forward` |

---

## Runnable demos

| Demo | Command | Proves |
|------|---------|--------|
| **Quack two-node cluster** | [examples/README.md](../examples/README.md) | tailnet + forward + Quack ATTACH |
| **DuckLake + Quack** | [examples/ducklake/README.md](../examples/ducklake/README.md) | Pattern B lake queries over tailnet |
| **Host DuckDB → compose stack** | `scripts/local_remote_headscale_test.sh` | Laptop joins same Headscale |
| **Vanilla tailnet probe** | `docker compose --profile debug run tailscale-probe` | Network vs DuckDB isolation |

Quick start:

```bash
cd examples
docker compose build quacktail-server quacktail-client
docker compose up -d headscale quacktail-server
docker compose --profile test run --rm quacktail-client   # Quack + DuckLake on ducklake branch
```

---

## Sketch: multi-lake SaaS on one tailnet (future-friendly)

```text
                    ┌─ sales.ducklake ── s3://tenant-a/sales/
lake-server ────────┼─ metrics.ducklake ─ s3://tenant-a/metrics/
  quack_serve       └─ archive.ducklake ─ s3://tenant-a/archive/
        ▲
        │  quack_query / ducklake:quack:
        │
   ┌────┴────┬────────────┐
   │         │            │
 BI tool   ETL job    notebook
 (Pattern C) (B)      (B + A)
```

1. **ETL** (batch): `quack_query` to run server-side `COPY` / `INSERT` into lake tables.  
2. **BI** (interactive): `ducklake:quack:` + `DATA_PATH` on S3 with read-only IAM.  
3. **Ops** (live): Quack `ATTACH` to `remote.*` staging tables before lake merge.

QuackScale roadmap for richer discovery: [PLAN.md](PLAN.md), [DUCKLAKE_TAILNET.md](DUCKLAKE_TAILNET.md).

---

## Further reading

| Doc | Topic |
|-----|--------|
| [README.md](../README.md) | Build, SQL reference |
| [AUTHENTICATION.md](AUTHENTICATION.md) | Tailscale keys, browser login |
| [HEADSCALE.md](HEADSCALE.md) | Self-hosted control plane |
| [QUACK_AUTH.md](QUACK_AUTH.md) | Shared Quack tokens |
| [QUACK_STREAMING.md](QUACK_STREAMING.md) | One remote op per statement |
| [DUCKLAKE_TAILNET.md](DUCKLAKE_TAILNET.md) | Lake-specific tailnet notes |
| [Quack overview](https://duckdb.org/docs/current/quack/overview) | Upstream Quack protocol |
| [DuckLake docs](https://duckdb.org/docs/stable/duckdb/ducklake) | Catalog, Parquet, attach |
