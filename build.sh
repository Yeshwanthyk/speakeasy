#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_NAME="Speakeasy"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
BUILD_ARCH="$(uname -m)"
CLANG_RUNTIME_DIR="$(xcrun clang -print-runtime-dir)"
SIGN_IDENTITY="${SPEAKEASY_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "Warning: no Apple Development identity found; Accessibility permission may need to be granted again after rebuilds." >&2
fi

RUST_DIR="$ROOT_DIR/rust/asr_bridge"

# --locked ensures Cargo.lock is authoritative; fails if deps drift.
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export TRANSCRIBE_CMAKE_ARGS="-DGGML_NATIVE=OFF${TRANSCRIBE_CMAKE_ARGS:+ $TRANSCRIBE_CMAKE_ARGS}"
export RUSTFLAGS="-L native=$CLANG_RUNTIME_DIR${RUSTFLAGS:+ $RUSTFLAGS}"
cargo build --release --locked --manifest-path "$RUST_DIR/Cargo.toml"
install_name_tool -id @rpath/libasr_bridge.dylib "$RUST_DIR/target/release/libasr_bridge.dylib"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

swiftc -O \
  -target "$BUILD_ARCH-apple-macosx$DEPLOYMENT_TARGET" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -L "$RUST_DIR/target/release" \
  -lasr_bridge \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/"*.swift \
  -o "$BIN_DIR/$APP_NAME"

ICONSET_DIR="$ROOT_DIR/Assets/speakeasy.iconset"
ICON_FILE="$BUILD_DIR/speakeasy.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
cp "$ICON_FILE" "$RESOURCES_DIR/"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$RUST_DIR/target/release/libasr_bridge.dylib" "$FRAMEWORKS_DIR/"

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$FRAMEWORKS_DIR/libasr_bridge.dylib"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR (signed with $SIGN_IDENTITY)"
