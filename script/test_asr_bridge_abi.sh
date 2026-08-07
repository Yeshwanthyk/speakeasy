#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust/asr_bridge"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speakeasy-asr-abi.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

cargo build --release --locked --manifest-path "$RUST_DIR/Cargo.toml"

cat > "$TEMP_DIR/main.swift" <<'SWIFT'
import Foundation

let result = asr_transcribe(nil, nil, 0, 1)
defer { asr_result_free(result) }
precondition(result.status == ASR_STATUS_ERROR)
precondition(result.text == nil)
guard let error = result.error else {
    fatalError("ASR bridge returned no typed error for a null handle")
}
precondition(String(cString: error) == "null handle")
print("Swift/Rust ASR ABI smoke passed")
SWIFT

swiftc \
  -import-objc-header "$RUST_DIR/include/asr_bridge.h" \
  -L "$RUST_DIR/target/release" \
  -lasr_bridge \
  -Xlinker -rpath \
  -Xlinker "$RUST_DIR/target/release" \
  "$TEMP_DIR/main.swift" \
  -o "$TEMP_DIR/asr-bridge-smoke"

"$TEMP_DIR/asr-bridge-smoke"
