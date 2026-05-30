# QuackTail node — DuckDB + quackscale + quack for compose demo.
# Build from repo root: docker build -f examples/Dockerfile -t quacktail:local .
#
# BUILD_FROM_SOURCE=1 (default in compose): build DuckDB + quackscale from this repo.
# BUILD_FROM_SOURCE=0: pull pinned GitHub release binary (QUACKTAIL_RELEASE_TAG, default v1.0.2).
#   Release v1.0.2 lacks attach_ducklake/tailscale_down — DuckLake demo requires source build.

ARG BUILD_FROM_SOURCE=1
ARG GITHUB_REPO=quackscience/duckdb-quackscale
ARG QUACKTAIL_RELEASE_TAG=v1.0.2
ARG HEADSCALE_VERSION=0.28.0
ARG TARGETARCH

FROM ubuntu:24.04 AS builder
ARG BUILD_FROM_SOURCE
ARG GITHUB_REPO
ARG QUACKTAIL_RELEASE_TAG

ENV DEBIAN_FRONTEND=noninteractive
RUN mkdir -p /out

RUN if [ "$BUILD_FROM_SOURCE" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends bash ca-certificates curl git \
         build-essential cmake ninja-build patch python3 \
      && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /src
COPY . /src/

RUN chmod +x /src/scripts/e2e/docker-build-quackscale.sh

RUN if [ "$BUILD_FROM_SOURCE" = "1" ]; then \
      /src/scripts/e2e/docker-build-quackscale.sh /out; \
    else \
      echo "build_from_source=0" > /out/build-info \
      && echo "release_tag=${QUACKTAIL_RELEASE_TAG}" >> /out/build-info; \
    fi

FROM ubuntu:24.04

ARG BUILD_FROM_SOURCE
ARG GITHUB_REPO
ARG QUACKTAIL_RELEASE_TAG
ARG HEADSCALE_VERSION
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl tini python3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/ /opt/quacktail-build/
COPY scripts/ci_download_release_duckdb.sh /tmp/ci_download_release_duckdb.sh
RUN chmod +x /tmp/ci_download_release_duckdb.sh \
    && if [ -x /opt/quacktail-build/duckdb ]; then \
         install -m755 /opt/quacktail-build/duckdb /usr/local/bin/duckdb; \
       else \
         QUACKTAIL_RELEASE_DIR=/opt/quacktail-release GITHUB_REPOSITORY="${GITHUB_REPO}" \
           bash -c 'eval "$(/tmp/ci_download_release_duckdb.sh '"${QUACKTAIL_RELEASE_TAG}"')" && install -m755 "$DUCKDB" /usr/local/bin/duckdb && cp -a "$QUACKTAIL_RELEASE_ROOT/." /opt/quacktail/ 2>/dev/null || true'; \
       fi \
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

# Install quack + ducklake first, then lay down our quackscale artifact (must not be overwritten).
RUN mkdir -p /duckdb_extensions /etc/quacktail \
    && duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL quack FROM core; LOAD quack; SELECT 1;" \
    || duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL quack FROM core_nightly; LOAD quack; SELECT 1;" \
    && duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL ducklake FROM core; LOAD ducklake; SELECT 1;" \
    || duckdb :memory: -batch -c "SET extension_directory='/duckdb_extensions'; INSTALL ducklake FROM core_nightly; LOAD ducklake; SELECT 1;" \
    && if [ -d /opt/quacktail-build/quackscale-ext ]; then \
         install -d /duckdb_extensions/quackscale; \
         install -m644 /opt/quacktail-build/quackscale-ext/quackscale.duckdb_extension \
           /duckdb_extensions/quackscale/quackscale.duckdb_extension; \
       fi \
    && if [ -f /opt/quacktail-build/build-info ]; then \
         cp /opt/quacktail-build/build-info /etc/quacktail/build-info; \
       fi \
    && if [ -f /opt/quacktail-build/git-rev ]; then \
         cp /opt/quacktail-build/git-rev /etc/quacktail/git-rev; \
       fi

COPY scripts/lib/quacktail_ext.sh /usr/local/lib/quacktail_ext.sh
COPY scripts/e2e/quacktail-verify-image.sh /usr/local/bin/quacktail-verify-image.sh
RUN chmod +x /usr/local/bin/quacktail-verify-image.sh \
    && /usr/local/bin/quacktail-verify-image.sh

COPY scripts/e2e/quacktail-entrypoint.sh /usr/local/bin/quacktail-entrypoint.sh
COPY scripts/e2e/quacktail-compose-bootstrap.sh /usr/local/bin/quacktail-compose-bootstrap.sh
COPY scripts/e2e/quacktail-server-run.sh /usr/local/bin/quacktail-server-run.sh
COPY scripts/e2e/quacktail-server-healthcheck.sh /usr/local/bin/quacktail-server-healthcheck.sh
RUN chmod +x /usr/local/bin/quacktail-entrypoint.sh /usr/local/bin/quacktail-compose-bootstrap.sh \
    /usr/local/bin/quacktail-server-run.sh /usr/local/bin/quacktail-server-healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/quacktail-entrypoint.sh"]
CMD ["server"]
