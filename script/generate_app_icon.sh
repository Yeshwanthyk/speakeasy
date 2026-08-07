#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Assets/AppIcon"
ICONSET_DIR="$ROOT_DIR/Assets/speakeasy.iconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required (install librsvg with Homebrew)" >&2
  exit 1
fi

render() {
  local source="$1"
  local size="$2"
  local output="$3"
  rsvg-convert --keep-aspect-ratio --width "$size" --height "$size" \
    "$SOURCE_DIR/$source" --output "$ICONSET_DIR/$output"
}

mkdir -p "$ICONSET_DIR"

# Each logical point size uses its own optical master at both scale factors.
render signal-fold-16.svg 16 icon_16x16.png
render signal-fold-16.svg 32 icon_16x16@2x.png
render signal-fold-32.svg 32 icon_32x32.png
render signal-fold-32.svg 64 icon_32x32@2x.png
render signal-fold.svg 128 icon_128x128.png
render signal-fold.svg 256 icon_128x128@2x.png
render signal-fold.svg 256 icon_256x256.png
render signal-fold.svg 512 icon_256x256@2x.png
render signal-fold.svg 512 icon_512x512.png
render signal-fold.svg 1024 icon_512x512@2x.png

# Canonicalize PNG encoding through the same ICNS codec used by the build.
# This keeps byte-for-byte round trips stable as well as preserving pixels.
roundtrip_root="$(mktemp -d "${TMPDIR:-/tmp}/signal-fold-icon.XXXXXX")"
trap 'rm -rf "$roundtrip_root"' EXIT
generated_icns="$roundtrip_root/speakeasy.icns"
normalized_iconset="$roundtrip_root/speakeasy.iconset"
iconutil -c icns "$ICONSET_DIR" -o "$generated_icns"
iconutil -c iconset "$generated_icns" -o "$normalized_iconset"
cp "$normalized_iconset"/*.png "$ICONSET_DIR/"

"$ROOT_DIR/script/verify_bundle.sh" --assets-only
