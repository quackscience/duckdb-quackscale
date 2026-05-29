# Quack “Multiple streaming scans” limitation

This is **not** a QuackScale (`quackscale`) limitation. It comes from the **core `quack` extension** shipped with DuckDB.

## Source code

[`duckdb-quack/src/storage/quack_optimizer.cpp`](https://github.com/duckdb/duckdb-quack/blob/main/src/storage/quack_optimizer.cpp)

Before executing a query, `QuackOptimizer` walks the plan and counts, per Quack connection:

- **streaming scans** — reads from attached Quack tables (`LogicalGet` on Quack scans)
- **writes** — `INSERT` / `CREATE TABLE AS` targeting a Quack catalog

If `scans + inserts > 1` **within the same query**, it throws:

```text
Not implemented Error: Multiple streaming scans or streaming scans + CTAS / insert in the same query are not currently supported
```

## What triggers it

Any **single SQL statement** that both:

1. reads from an attached Quack catalog (`remote.table`, `FROM remote…`, subqueries), and
2. writes to the same attached Quack catalog (`INSERT INTO remote…`, CTAS into `remote`)

Examples that fail:

```sql
-- INSERT + correlated read in one statement
INSERT INTO remote.t
SELECT 1, 'x'
WHERE NOT EXISTS (SELECT 1 FROM remote.t WHERE id = 1);

-- Multiple remote reads in one statement (e.g. SHOW TABLES on nested Quack catalogs)
SHOW TABLES;
```

Examples that work (separate statements, one remote op each):

```sql
ATTACH 'quack:host:9494' AS remote (TYPE quack, DISABLE_SSL true);

INSERT INTO remote.t VALUES (1, 'x')
ON CONFLICT DO NOTHING;

SELECT * FROM remote.t;
```

`CALL tailscale_up()` is a **local** QuackScale table function — it is **not** a Quack streaming scan and is not the cause of this error.

## Upstream status

- Reported in [duckdb/duckdb#22605](https://github.com/duckdb/duckdb/issues/22605) (remote catalog / `SHOW TABLES`).
- A community PR to lift the restriction ([duckdb/duckdb-quack#126](https://github.com/duckdb/duckdb-quack/pull/126)) was **not merged** as of May 2026 — maintainers want smaller, incremental changes.

QuackScale cannot patch this inside `quackscale`; fixes belong in **`duckdb-quack`** (or query shape/workarounds in client SQL).

## Demo / DuckLake guidance

For attached remote writes:

- Prefer plain `INSERT INTO remote.t VALUES (…)` or `ON CONFLICT DO NOTHING` for idempotency.
- Avoid `INSERT … SELECT … WHERE NOT EXISTS (SELECT … FROM remote.t)` in one statement.
- Split read and write into **separate SQL statements**, or use `quack_query(uri, '…')` for one-off remote SQL when ATTACH + DML in one plan is awkward.
