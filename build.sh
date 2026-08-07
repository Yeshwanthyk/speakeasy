#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_NAME="Speakeasy"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
BUILD_ARCH="$(uname -m)"
CLANG_RUNTIME_DIR="$(xcrun clang -print-runtime-dir)"
SIGN_IDENTITY="${SPEAKEASY_SIGN_IDENTITY:-}"

if BUILD_VERSION_FROM_GIT=$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null); then
  :
else
  BUILD_VERSION_FROM_GIT=""
fi

SOURCE_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "$ROOT_DIR/Info.plist")"
BUILD_VERSION="${SPEAKEASY_BUILD_VERSION:-${BUILD_VERSION_FROM_GIT:-$SOURCE_BUILD_VERSION}}"
MARKETING_VERSION="${SPEAKEASY_MARKETING_VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/Info.plist")}"

if [[ ! "$BUILD_VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo "Invalid SPEAKEASY_BUILD_VERSION: $BUILD_VERSION" >&2
  exit 1
fi

if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Invalid SPEAKEASY_MARKETING_VERSION: $MARKETING_VERSION" >&2
  exit 1
fi

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

mkdir -p "$BUILD_DIR"
STAGING_ROOT="$(mktemp -d "$BUILD_DIR/.$APP_NAME.assembly.XXXXXX")"
STAGING_APP="$STAGING_ROOT/$APP_NAME.app"
BIN_DIR="$STAGING_APP/Contents/MacOS"
FRAMEWORKS_DIR="$STAGING_APP/Contents/Frameworks"
RESOURCES_DIR="$STAGING_APP/Contents/Resources"
STAGED_PLIST="$STAGING_APP/Contents/Info.plist"
trap 'rm -rf "$STAGING_ROOT"' EXIT

# --locked ensures Cargo.lock is authoritative; fails if deps drift.
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export TRANSCRIBE_CMAKE_ARGS="-DGGML_NATIVE=OFF${TRANSCRIBE_CMAKE_ARGS:+ $TRANSCRIBE_CMAKE_ARGS}"
export RUSTFLAGS="-L native=$CLANG_RUNTIME_DIR${RUSTFLAGS:+ $RUSTFLAGS}"
cargo build --release --locked --manifest-path "$RUST_DIR/Cargo.toml"
install_name_tool -id @rpath/libasr_bridge.dylib "$RUST_DIR/target/release/libasr_bridge.dylib"

mkdir -p "$BIN_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

swiftc -O \
  -target "$BUILD_ARCH-apple-macosx$DEPLOYMENT_TARGET" \
  -import-objc-header "$RUST_DIR/include/asr_bridge.h" \
  -framework AppKit \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework Carbon \
  -framework ApplicationServices \
  -L "$RUST_DIR/target/release" \
  -lasr_bridge \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/"*.swift \
  -o "$BIN_DIR/$APP_NAME"

ICONSET_DIR="$ROOT_DIR/Assets/speakeasy.iconset"
ICON_FILE="$RESOURCES_DIR/speakeasy.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

cp "$ROOT_DIR/Info.plist" "$STAGED_PLIST"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$STAGED_PLIST"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$STAGED_PLIST"
cp "$RUST_DIR/target/release/libasr_bridge.dylib" "$FRAMEWORKS_DIR/"

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$FRAMEWORKS_DIR/libasr_bridge.dylib"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGING_APP"
"$ROOT_DIR/script/verify_bundle.sh" "$STAGING_APP"

# Exchange same-filesystem bundles in one filesystem operation. When an old
# bundle exists it moves to STAGING_APP and remains recoverable until the new
# current bundle has passed post-publication verification.
"$ROOT_DIR/script/atomic_replace_bundle.swift" "$APP_DIR" "$STAGING_APP"
if ! "$ROOT_DIR/script/verify_bundle.sh" "$APP_DIR"; then
  if [[ -d "$STAGING_APP" ]]; then
    "$ROOT_DIR/script/atomic_replace_bundle.swift" "$APP_DIR" "$STAGING_APP" || true
  fi
  echo "Published bundle verification failed; previous bundle restored" >&2
  exit 1
fi
rm -rf "$STAGING_APP"

echo "Built $APP_DIR (version $BUILD_VERSION, signed with $SIGN_IDENTITY)"
