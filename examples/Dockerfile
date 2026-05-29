# QuackTail node — DuckDB + quackscale from latest GitHub release, quack from core.
# Build from repo root: docker build -f examples/Dockerfile -t quacktail:local .

FROM ubuntu:24.04

ARG GITHUB_REPO=quackscience/duckdb-quackscale

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini python3 \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ci_download_release_duckdb.sh /tmp/ci_download_release_duckdb.sh
RUN chmod +x /tmp/ci_download_release_duckdb.sh \
    && QUACKTAIL_RELEASE_DIR=/opt/quacktail-release GITHUB_REPOSITORY="${GITHUB_REPO}" \
       bash -c 'eval "$(/tmp/ci_download_release_duckdb.sh latest)" && install -m755 "$DUCKDB" /usr/local/bin/duckdb && cp -a "$QUACKTAIL_RELEASE_ROOT/." /opt/quacktail/ 2>/dev/null || true' \
    && rm -f /tmp/ci_download_release_duckdb.sh

ENV DUCKDB_BIN=/usr/local/bin/duckdb
ENV DUCKDB_EXTENSION_DIRECTORY=/duckdb_extensions
ENV QUACK_PORT=9494

RUN mkdir -p /duckdb_extensions \
    && duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL quack FROM core; LOAD quack; SELECT 1;" \
    || duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;"

COPY scripts/e2e/quacktail-entrypoint.sh /usr/local/bin/quacktail-entrypoint.sh
COPY scripts/lib/quacktail_ext.sh /usr/local/lib/quacktail_ext.sh
RUN chmod +x /usr/local/bin/quacktail-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/quacktail-entrypoint.sh"]
CMD ["server"]
