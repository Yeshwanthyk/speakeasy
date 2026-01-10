#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_NAME="Wisp"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"

RUST_DIR="$ROOT_DIR/rust/parakeet_bridge"

cargo build --release --manifest-path "$RUST_DIR/Cargo.toml"
install_name_tool -id @rpath/libparakeet_bridge.dylib "$RUST_DIR/target/release/libparakeet_bridge.dylib"

mkdir -p "$BIN_DIR" "$FRAMEWORKS_DIR"

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

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$RUST_DIR/target/release/libparakeet_bridge.dylib" "$FRAMEWORKS_DIR/"

echo "Built $APP_DIR"
