#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_ONLY=false
if [[ "${1:-}" == "--assets-only" ]]; then
  ASSETS_ONLY=true
  APP_PATH=""
else
  APP_PATH="${1:-$ROOT_DIR/build/Speakeasy.app}"
fi
ICONSET_DIR="$ROOT_DIR/Assets/speakeasy.iconset"

icon_specs=(
  "icon_16x16.png:16x16"
  "icon_16x16@2x.png:32x32"
  "icon_32x32.png:32x32"
  "icon_32x32@2x.png:64x64"
  "icon_128x128.png:128x128"
  "icon_128x128@2x.png:256x256"
  "icon_256x256.png:256x256"
  "icon_256x256@2x.png:512x512"
  "icon_512x512.png:512x512"
  "icon_512x512@2x.png:1024x1024"
)

if [[ ! -d "$ICONSET_DIR" ]]; then
  echo "missing iconset: $ICONSET_DIR" >&2
  exit 1
fi

png_count="$(find "$ICONSET_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
if [[ "$png_count" != "10" ]]; then
  echo "expected 10 canonical iconset PNGs, found $png_count" >&2
  exit 1
fi

for spec in "${icon_specs[@]}"; do
  filename="${spec%%:*}"
  expected_size="${spec#*:}"
  image_path="$ICONSET_DIR/$filename"
  if [[ ! -f "$image_path" ]]; then
    echo "missing icon representation: $image_path" >&2
    exit 1
  fi

  width="$(sips -g pixelWidth "$image_path" | awk '/pixelWidth:/ { print $2 }')"
  height="$(sips -g pixelHeight "$image_path" | awk '/pixelHeight:/ { print $2 }')"
  if [[ "$width"x"$height" != "$expected_size" ]]; then
    echo "$filename has dimensions ${width}x${height}; expected $expected_size" >&2
    exit 1
  fi

  has_alpha="$(sips -g hasAlpha "$image_path" | awk '/hasAlpha:/ { print $2 }')"
  if [[ "$has_alpha" != "yes" ]]; then
    echo "$filename must preserve transparent rounded corners" >&2
    exit 1
  fi
done

"$ROOT_DIR/script/check_icon_edges.swift" \
  "$ICONSET_DIR/icon_16x16.png" \
  "$ICONSET_DIR/icon_32x32.png"

roundtrip_root="$(mktemp -d "${TMPDIR:-/tmp}/speakeasy-icon-roundtrip.XXXXXX")"
trap 'rm -rf "$roundtrip_root"' EXIT

generated_icns="$roundtrip_root/speakeasy.icns"
roundtrip_iconset="$roundtrip_root/speakeasy.iconset"
iconutil -c icns "$ICONSET_DIR" -o "$generated_icns"
iconutil -c iconset "$generated_icns" -o "$roundtrip_iconset"

for spec in "${icon_specs[@]}"; do
  filename="${spec%%:*}"
  source_hash="$(shasum -a 256 "$ICONSET_DIR/$filename" | awk '{ print $1 }')"
  roundtrip_hash="$(shasum -a 256 "$roundtrip_iconset/$filename" | awk '{ print $1 }')"
  if [[ "$source_hash" != "$roundtrip_hash" ]]; then
    echo "icon round-trip hash mismatch for $filename" >&2
    echo "  source:    $source_hash" >&2
    echo "  round-trip: $roundtrip_hash" >&2
    exit 1
  fi
  printf 'icon %-24s sha256=%s\n' "$filename" "$source_hash"
done

if [[ "$ASSETS_ONLY" == true ]]; then
  printf 'icon round-trip verified\n'
  exit 0
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "missing app bundle: $APP_PATH" >&2
  exit 1
fi

app_icon="$APP_PATH/Contents/Resources/speakeasy.icns"
if [[ ! -f "$app_icon" ]]; then
  echo "missing bundled ICNS: $app_icon" >&2
  exit 1
fi

if ! cmp -s "$generated_icns" "$app_icon"; then
  echo "bundled ICNS differs from the canonical iconset representation" >&2
  exit 1
fi
printf 'icns sha256=%s\n' "$(shasum -a 256 "$app_icon" | awk '{ print $1 }')"

codesign --verify --deep --strict "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
bundle_version="$(plutil -extract CFBundleVersion raw -o - "$APP_PATH/Contents/Info.plist")"
if [[ -z "$bundle_version" ]]; then
  echo "bundled CFBundleVersion is empty" >&2
  exit 1
fi

printf 'signature verified: %s\n' "$APP_PATH"
printf 'bundle version: %s\n' "$bundle_version"
