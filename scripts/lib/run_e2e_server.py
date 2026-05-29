#!/usr/bin/env python3
"""Run DuckDB init SQL and keep the process alive for QuackTail e2e tests."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: run_e2e_server.py <duckdb> <database_path> <init_sql_path> <log_path>", file=sys.stderr)
        return 2

    duckdb, database, init_sql_path, log_path = sys.argv[1:5]
    init_sql = open(init_sql_path, encoding="utf-8").read()

    logf = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [duckdb, database],
        stdin=subprocess.PIPE,
        stdout=logf,
        stderr=subprocess.STDOUT,
        text=True,
        env=os.environ.copy(),
    )
    assert proc.stdin is not None
    proc.stdin.write(init_sql)
    proc.stdin.flush()

    def _terminate(_signum: int, _frame: object) -> None:
        if proc.poll() is None:
            proc.terminate()

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)

    keepalive = float(os.environ.get("E2E_SERVER_KEEPALIVE_SEC", "180"))
    deadline = time.time() + keepalive
    try:
        while time.time() < deadline and proc.poll() is None:
            time.sleep(1)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        logf.close()

    if proc.returncode not in (0, None, -signal.SIGTERM, -15):
        print(f"error: server DuckDB exited with code {proc.returncode}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
