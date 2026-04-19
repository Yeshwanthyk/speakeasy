# Wisp

Minimal macOS dictation app using local Parakeet V3 transcription.

## Requirements

- macOS with Xcode command-line tools (`swiftc`, `iconutil`, `codesign`)
- Rust toolchain; the Rust bridge pins its version in `rust/parakeet_bridge/rust-toolchain.toml`
- A local Parakeet V3 int8 model directory

## Model Path

By default Wisp looks for:

```text
~/Library/Application Support/com.wisp.app/models/parakeet-tdt-0.6b-v3-int8
```

For compatibility with pre-rename installs, it also falls back to:

```text
~/Library/Application Support/com.speakeasy.app/models/parakeet-tdt-0.6b-v3-int8
```

Set `PARAKEET_MODEL_DIR` to override both paths:

```sh
export PARAKEET_MODEL_DIR="/path/to/parakeet-tdt-0.6b-v3-int8"
```

## Build

```sh
./build.sh
```

The app is written to `build/Wisp.app`. The build compiles the Rust FFI bridge with `cargo build --release --locked`, links it into the app bundle, and ad-hoc signs both the dylib and app.

## Test

```sh
swift test
cargo test --manifest-path rust/parakeet_bridge/Cargo.toml --locked
```

`swift test` exercises the Swift library target. `./build.sh` is still required before release because the app-only files (`AppDelegate.swift`, `ParakeetTranscriber.swift`, `main.swift`) are excluded from SwiftPM tests.

## Runtime

- Hotkey toggle: Hyper+S (Cmd+Ctrl+Opt+Shift+S)
- Microphone permission is requested on first launch.
- Accessibility permission is required for auto-paste.
