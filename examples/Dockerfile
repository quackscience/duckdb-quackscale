# QuackTail node — DuckDB + quackscale from latest GitHub release, quack from core.
# Build from repo root: docker build -f examples/Dockerfile -t quacktail:local .

FROM ubuntu:24.04

ARG GITHUB_REPO=quackscience/duckdb-quackscale
ARG HEADSCALE_VERSION=0.28.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl tini python3 \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ci_download_release_duckdb.sh /tmp/ci_download_release_duckdb.sh
RUN chmod +x /tmp/ci_download_release_duckdb.sh \
    && QUACKTAIL_RELEASE_DIR=/opt/quacktail-release GITHUB_REPOSITORY="${GITHUB_REPO}" \
       bash -c 'eval "$(/tmp/ci_download_release_duckdb.sh latest)" && install -m755 "$DUCKDB" /usr/local/bin/duckdb && cp -a "$QUACKTAIL_RELEASE_ROOT/." /opt/quacktail/ 2>/dev/null || true' \
    && rm -f /tmp/ci_download_release_duckdb.sh

RUN case "${TARGETARCH:-amd64}" in \
      amd64) HS_ARCH=amd64 ;; \
      arm64) HS_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/headscale \
         "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${HS_ARCH}" \
    && chmod +x /usr/local/bin/headscale

ENV DUCKDB_BIN=/usr/local/bin/duckdb
ENV DUCKDB_EXTENSION_DIRECTORY=/duckdb_extensions
ENV QUACK_PORT=9494

RUN mkdir -p /duckdb_extensions \
    && duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL quack FROM core; LOAD quack; SELECT 1;" \
    || duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;"

COPY scripts/e2e/quacktail-entrypoint.sh /usr/local/bin/quacktail-entrypoint.sh
COPY scripts/e2e/quacktail-compose-bootstrap.sh /usr/local/bin/quacktail-compose-bootstrap.sh
COPY scripts/lib/quacktail_ext.sh /usr/local/lib/quacktail_ext.sh
RUN chmod +x /usr/local/bin/quacktail-entrypoint.sh /usr/local/bin/quacktail-compose-bootstrap.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/quacktail-entrypoint.sh"]
CMD ["server"]
