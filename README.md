# Speakeasy

Minimal macOS dictation app using local Parakeet V3 or Nemotron ASR transcription.

## Requirements

- macOS with Xcode command-line tools (`swiftc`, `iconutil`, `codesign`)
- Rust toolchain; the Rust bridge pins its version in `rust/parakeet_bridge/rust-toolchain.toml`
- A local Parakeet V3 int8 model directory. Nemotron 3.5 ASR downloads on first use.

## Model Path

By default Speakeasy uses Parakeet TDT and looks for:

```text
~/Library/Application Support/com.speakeasy.app/models/parakeet-tdt-0.6b-v3-int8
```

For compatibility with pre-rename installs, it also falls back to:

```text
~/Library/Application Support/com.wisp.app/models/parakeet-tdt-0.6b-v3-int8
```

Set `PARAKEET_MODEL_DIR` to override both paths:

```sh
export PARAKEET_MODEL_DIR="/path/to/parakeet-tdt-0.6b-v3-int8"
```

Use the menu bar `Audio Model` submenu to switch between Parakeet TDT and Nemotron 3.5 ASR. On first Nemotron selection, Speakeasy downloads the model into:

```text
~/Library/Application Support/com.speakeasy.app/models/nemotron-3.5-asr-streaming-0.6b-int8
```

After download, the selected model is loaded and warmed in memory. Subsequent launches use the persisted `ASRModel` preference.

To use an existing Nemotron directory instead:

```sh
export SPEAKEASY_ASR_MODEL="nemotron-3.5-asr"
export NEMOTRON_MODEL_DIR="/path/to/nemotron-3.5-asr-streaming-0.6b-int8"
```

Nemotron expects `encoder.onnx`, `encoder.onnx.data`, `decoder_joint.onnx`, and `tokenizer.model` in the same directory. Set `NEMOTRON_TARGET_LANG` (for example `en-US`, `es-ES`, or `auto`) to override language auto-detection.

For normal Finder/LaunchServices launches, persist the same option with:

```sh
defaults write com.speakeasy.app ASRModel "nemotron-3.5-asr"
defaults write com.speakeasy.app NemotronModelDir "/path/to/nemotron-3.5-asr-streaming-0.6b-int8"
defaults write com.speakeasy.app NemotronTargetLang "auto"
```

## Build

```sh
./build.sh
```

The app is written to `build/Speakeasy.app`. The build targets macOS 12 or newer, compiles the Rust FFI bridge with `cargo build --release --locked`, links it into the app bundle, and signs both the dylib and app with the first available Apple Development identity. A stable development signature keeps macOS privacy grants attached across rebuilds. If no development identity is available, the build falls back to ad-hoc signing; set `SPEAKEASY_SIGN_IDENTITY` to choose a specific identity.

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
