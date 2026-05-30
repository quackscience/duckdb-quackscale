#!/usr/bin/env bash
# Builder-stage script for examples/Dockerfile (BUILD_FROM_SOURCE=1).
set -euo pipefail

OUT="${1:-/out}"
mkdir -p "$OUT"

need_submodules() {
  [[ -f duckdb/CMakeLists.txt ]] \
    && [[ -f extension-ci-tools/makefiles/duckdb_extension.Makefile ]] \
    && [[ -f third_party/libtailscale/go.mod || -f third_party/libtailscale/README.md ]] \
    && return 1
  return 0
}

if need_submodules; then
  echo "→ initializing git submodules ..."
  if [[ -d .git ]]; then
    git submodule sync --recursive
    git submodule update --init --recursive
  else
    echo "error: git submodules missing and .git not available in build context" >&2
    echo "  clone with: git clone --recurse-submodules …" >&2
    echo "  or ensure duckdb/ and extension-ci-tools/ are populated before docker build" >&2
    exit 1
  fi
else
  echo "→ submodules present in build context (skipping git submodule update)"
fi

# Never reuse host build trees (especially dangerous when building linux from macOS).
rm -rf build .cache

echo "→ make release (GEN=ninja, $(nproc) jobs) ..."
GEN=ninja make release -j"$(nproc)"

EXT_ART="build/release/extension/quackscale/quackscale.duckdb_extension"
if [[ ! -f "$EXT_ART" ]]; then
  echo "error: quackscale loadable extension not found at ${EXT_ART}" >&2
  ls -la build/release/extension/quackscale 2>/dev/null >&2 || true
  exit 1
fi

install -m755 build/release/duckdb "$OUT/duckdb"
cp -a build/release/extension/quackscale "$OUT/quackscale-ext"

if [[ -d .git ]]; then
  git rev-parse HEAD > "$OUT/git-rev"
else
  echo "docker-build" > "$OUT/git-rev"
fi
echo "build_from_source=1" > "$OUT/build-info"
echo "✓ quackscale builder done"
