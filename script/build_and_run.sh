#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Speakeasy"
BUNDLE_ID="com.speakeasy.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP="$ROOT_DIR/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
STAGING_APP="$INSTALL_DIR/.$APP_NAME.installing.app"
APP_BINARY="$INSTALL_APP/Contents/MacOS/$APP_NAME"

stop_app() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
  if pgrep -x Wisp >/dev/null; then
    osascript -e 'tell application id "com.wisp.app" to quit' >/dev/null 2>&1 || true
  fi
  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null && ! pgrep -x Wisp >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x Wisp >/dev/null 2>&1 || true
}

build_and_install() {
  "$ROOT_DIR/build.sh"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$STAGING_APP"
  ditto "$BUILD_APP" "$STAGING_APP"
  codesign --verify --deep --strict "$STAGING_APP"
  stop_app
  "$ROOT_DIR/script/atomic_replace_bundle.swift" "$INSTALL_APP" "$STAGING_APP"
  if ! codesign --verify --deep --strict "$INSTALL_APP"; then
    if [[ -d "$STAGING_APP" ]]; then
      "$ROOT_DIR/script/atomic_replace_bundle.swift" "$INSTALL_APP" "$STAGING_APP" || true
    fi
    echo "Installed bundle verification failed; previous bundle restored" >&2
    exit 1
  fi
  rm -rf "$STAGING_APP"
}

open_app() {
  /usr/bin/open "$INSTALL_APP"
}

case "$MODE" in
  run)
    build_and_install
    open_app
    ;;
  install)
    build_and_install
    ;;
  --debug|debug)
    build_and_install
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_and_install
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_and_install
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    build_and_install
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|install|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
