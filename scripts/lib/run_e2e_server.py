#!/usr/bin/env python3
"""Run DuckDB server SQL and keep the session alive while Quack listens."""
from __future__ import annotations

import os
import pty
import select
import signal
import subprocess
import sys
import threading
import time


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: run_e2e_server.py <duckdb> <database_path> <init_sql_path> <log_path>", file=sys.stderr)
        return 2

    duckdb, database, init_sql_path, log_path = sys.argv[1:5]
    init_sql = open(init_sql_path, encoding="utf-8").read()
    pid_path = f"{log_path}.duckdb.pid"

    logf = open(log_path, "a", encoding="utf-8")
    # Quack needs a real TTY session: piped stdin lets quack_serve return without a live listener.
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        [duckdb, database, "-echo"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        start_new_session=True,
        env=os.environ.copy(),
    )
    os.close(slave_fd)

    with open(pid_path, "w", encoding="utf-8") as pidf:
        pidf.write(str(proc.pid))

    payload = init_sql if init_sql.endswith("\n") else init_sql + "\n"
    os.write(master_fd, payload.encode())

    stop = threading.Event()

    def _stream_output() -> None:
        while not stop.is_set():
            ready, _, _ = select.select([master_fd], [], [], 0.5)
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            text = chunk.decode("utf-8", errors="replace")
            logf.write(text)
            logf.flush()
            sys.stderr.write(text)
            sys.stderr.flush()

    def _keepalive() -> None:
        while not stop.wait(30):
            if proc.poll() is not None:
                break
            try:
                os.write(master_fd, b"\n")
            except OSError:
                break

    def _terminate(_signum: int, _frame: object) -> None:
        stop.set()
        if proc.poll() is None:
            proc.terminate()

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)

    reader = threading.Thread(target=_stream_output, daemon=True)
    keepalive = threading.Thread(target=_keepalive, daemon=True)
    reader.start()
    keepalive.start()

    keepalive_sec = float(os.environ.get("E2E_SERVER_KEEPALIVE_SEC", "180"))
    deadline = time.time() + keepalive_sec
    try:
        while time.time() < deadline and proc.poll() is None:
            time.sleep(1)
    finally:
        stop.set()
        reader.join(timeout=5)
        keepalive.join(timeout=1)
        try:
            os.close(master_fd)
        except OSError:
            pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        logf.close()
        try:
            os.remove(pid_path)
        except OSError:
            pass

    if proc.returncode not in (0, None, -signal.SIGTERM, -15):
        print(f"error: server DuckDB exited with code {proc.returncode}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
