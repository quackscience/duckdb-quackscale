-- DuckLake + Quack on one host (no tailnet). Requires DuckDB 1.5+ with quack + ducklake from core.
--
-- Server session (terminal 1):
--   duckdb server.duckdb
--
-- Client session (terminal 2):
--   duckdb

-- === Server ===
INSTALL quack FROM core;
INSTALL ducklake FROM core;
LOAD quack;
LOAD ducklake;

ATTACH 'ducklake:./lake/metadata/inventory.ducklake' AS lake (DATA_PATH './lake/data/');
USE lake;

CREATE TABLE IF NOT EXISTS inventory (item_id INT, quantity INT);
INSERT INTO inventory VALUES (101, 50), (102, 120);

CALL quack_serve(
    'quack:127.0.0.1:9494',
    allow_other_hostname => true,
    token => 'quackscale-demo-token'
);

-- === Client (new duckdb process) ===
-- INSTALL quack FROM core;
-- INSTALL ducklake FROM core;
-- LOAD quack;
-- LOAD ducklake;
--
-- CREATE SECRET (TYPE quack, TOKEN 'quackscale-demo-token', SCOPE 'quack:127.0.0.1:9494');
--
-- Option A: query lake tables via Quack attach
-- ATTACH 'quack:127.0.0.1:9494' AS remote (TYPE quack);
-- SELECT * FROM remote.lake.inventory;
--
-- Option B: DuckLake metadata via Quack URI (local Parquet path on client)
-- ATTACH 'ducklake:quack:127.0.0.1:9494' AS my_lake (DATA_PATH './lake/data/');
-- SELECT * FROM my_lake.inventory;
