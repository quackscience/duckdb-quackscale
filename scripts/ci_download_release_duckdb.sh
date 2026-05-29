#!/usr/bin/env bash
# Download the linux DuckDB + quackscale bundle from a GitHub release.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-quackscience/duckdb-quackscale}"
QUACKTAIL_RELEASE_TAG_DEFAULT="${QUACKTAIL_RELEASE_TAG_DEFAULT:-v1.0.3}"
TAG="${1:-${QUACKTAIL_RELEASE_TAG:-$QUACKTAIL_RELEASE_TAG_DEFAULT}}"
ASSET_PREFIX="${QUACKTAIL_RELEASE_ASSET_PREFIX:-quacktail-linux-amd64}"
DEST="${QUACKTAIL_RELEASE_DIR:-$(mktemp -d)}"

if [[ -z "$TAG" || "$TAG" == "latest" ]]; then
  echo "Resolving latest release for $REPO ..." >&2
  TAG="$(
    python3 - <<PY
import json, urllib.request
url = "https://api.github.com/repos/${REPO}/releases/latest"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req, timeout=60) as resp:
    print(json.load(resp)["tag_name"])
PY
  )"
fi

echo "Using release tag: $TAG" >&2

RELEASE_JSON="$(
  python3 - <<PY
import json, urllib.parse, urllib.request
repo = "${REPO}"
tag = urllib.parse.quote("${TAG}")
url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req, timeout=60) as resp:
    print(json.dumps(json.load(resp)))
PY
)"

export RELEASE_JSON ASSET_PREFIX

read -r ASSET_NAME DOWNLOAD_URL < <(
  python3 - <<'PY'
import json, os, sys
release = json.loads(os.environ["RELEASE_JSON"])
prefix = os.environ["ASSET_PREFIX"]
for asset in release.get("assets", []):
    name = asset.get("name", "")
    if name.startswith(prefix) and name.endswith(".tar.gz"):
        print(name, asset["browser_download_url"])
        sys.exit(0)
print("error: no matching release asset", file=sys.stderr)
sys.exit(1)
PY
)

ARCHIVE="$DEST/$ASSET_NAME"
mkdir -p "$DEST"
echo "Downloading $ASSET_NAME ..." >&2
curl -fsSL -L -o "$ARCHIVE" "$DOWNLOAD_URL"

EXTRACT_DIR="$DEST/extracted"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"

DUCKDB_BIN="$(find "$EXTRACT_DIR" -name duckdb -type f | head -1)"
if [[ -z "$DUCKDB_BIN" || ! -x "$DUCKDB_BIN" ]]; then
  echo "error: duckdb binary not found in release archive" >&2
  exit 1
fi

export DUCKDB="$DUCKDB_BIN"
export QUACKTAIL_RELEASE_ROOT="$(dirname "$DUCKDB_BIN")"

echo "export DUCKDB='$DUCKDB'"
echo "export QUACKTAIL_RELEASE_ROOT='$QUACKTAIL_RELEASE_ROOT'"
if [[ -f "$QUACKTAIL_RELEASE_ROOT/VERSION" ]]; then
  cat "$QUACKTAIL_RELEASE_ROOT/VERSION" >&2
fi
