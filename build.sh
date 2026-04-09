#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_NAME="Speakeasy"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SIGN_IDENTITY="-"

RUST_DIR="$ROOT_DIR/rust/parakeet_bridge"

cargo build --release --manifest-path "$RUST_DIR/Cargo.toml"
install_name_tool -id @rpath/libparakeet_bridge.dylib "$RUST_DIR/target/release/libparakeet_bridge.dylib"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

swiftc -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -L "$RUST_DIR/target/release" \
  -lparakeet_bridge \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/"*.swift \
  -o "$BIN_DIR/$APP_NAME"

ICONSET_DIR="$ROOT_DIR/Assets/speakeasy.iconset"
ICON_FILE="$BUILD_DIR/speakeasy.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
cp "$ICON_FILE" "$RESOURCES_DIR/"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$RUST_DIR/target/release/libparakeet_bridge.dylib" "$FRAMEWORKS_DIR/"

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$FRAMEWORKS_DIR/libparakeet_bridge.dylib"
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR"
