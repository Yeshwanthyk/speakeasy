#!/usr/bin/env bash
# Downloads the pinned Sparkle release, verifies its SHA-256, and unpacks it.
# Usage: script/fetch_sparkle.sh <destination-dir>
set -euo pipefail

SPARKLE_VERSION="2.7.1"
SPARKLE_SHA256="f7385c3e8c70c37e5928939e6246ac9070757b4b37a5cb558afa1b0d5ef189de"
DEST="${1:?destination directory required}"

if [[ -f "$DEST/.sparkle-$SPARKLE_VERSION" ]]; then
  exit 0
fi

mkdir -p "$DEST"
archive="$(mktemp "${TMPDIR:-/tmp}/sparkle.XXXXXX")"
trap 'rm -f "$archive"' EXIT
curl --fail --silent --show-error --location \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
  -o "$archive"
actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
if [[ "$actual" != "$SPARKLE_SHA256" ]]; then
  echo "Sparkle checksum mismatch: $actual" >&2
  exit 1
fi
rm -rf "$DEST/Sparkle.framework" "$DEST/bin"
tar -xJf "$archive" -C "$DEST" ./Sparkle.framework ./bin
touch "$DEST/.sparkle-$SPARKLE_VERSION"
