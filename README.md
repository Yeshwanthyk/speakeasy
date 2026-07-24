# Speakeasy

Minimal macOS dictation app using local GGUF speech models through [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), with Metal acceleration on Apple Silicon.

## Requirements

- macOS 12 or newer with Xcode command-line tools (`swiftc`, `iconutil`, `codesign`)
- Rust toolchain; `rust/asr_bridge/rust-toolchain.toml` pins the build version
- Approximately 1.5 GB free for the selected model download and staging copy

## Models

On first launch Speakeasy downloads, verifies, loads, and warms Parakeet Unified EN 0.6B Q8_0:

```text
~/Library/Application Support/com.speakeasy.app/models/parakeet-unified-en-0.6b-Q8_0.gguf
```

The menu bar `Audio Model` submenu also supports:

- Parakeet TDT v3 Q8_0: multilingual batch transcription
- Nemotron Streaming 3.5 Q8_0: multilingual transcription

Artifacts are downloaded from immutable Hugging Face revisions and must match their catalog byte count and SHA-256 before atomic promotion. The currently selected model is persisted only after it loads and warms successfully.

Select a model before launch:

```sh
export SPEAKEASY_ASR_MODEL="parakeet-unified-en" # default
export SPEAKEASY_ASR_MODEL="parakeet-tdt-v3"
export SPEAKEASY_ASR_MODEL="nemotron-3.5-asr"
```

Override an artifact with an already-downloaded matching Q8_0 GGUF:

```sh
export PARAKEET_UNIFIED_GGUF_PATH="/path/to/parakeet-unified-en-0.6b-Q8_0.gguf"
export PARAKEET_TDT_GGUF_PATH="/path/to/parakeet-tdt-0.6b-v3-Q8_0.gguf"
export NEMOTRON_GGUF_PATH="/path/to/nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf"
```

Legacy `parakeet-tdt` and `nemotron-3.5-asr` selection values still map to their GGUF replacements. ONNX model directories are no longer used.

## Build

```sh
./build.sh
```

The app is written to `build/Speakeasy.app`. The build compiles `transcribe-cpp 0.1.3` with Metal and `GGML_NATIVE=OFF`, embeds `libasr_bridge.dylib`, and signs the dylib and app. Set `SPEAKEASY_SIGN_IDENTITY` to select a development identity; without one, the build falls back to ad-hoc signing.

## Test

```sh
swift test
TRANSCRIBE_CMAKE_ARGS=-DGGML_NATIVE=OFF \
  cargo test --manifest-path rust/asr_bridge/Cargo.toml --locked
```

`swift test` exercises the Swift library target. `./build.sh` additionally compiles the app-only files (`AppDelegate.swift`, `TranscribeCppTranscriber.swift`, and `main.swift`) and verifies the signed bundle.

## Runtime

- Hotkey toggle: Hyper+S (Cmd+Ctrl+Opt+Shift+S)
- Microphone permission is requested on first launch.
- Accessibility permission is required for auto-paste.
