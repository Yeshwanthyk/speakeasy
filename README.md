<div align="center">
  <img src="Assets/AppIcon/signal-fold.svg" width="144" alt="Speakeasy Signal Fold icon">
  <h1>Speakeasy</h1>
  <p><strong>Fast, private dictation for macOS.</strong></p>
  <p>Press a shortcut, speak, and keep writing. Transcription stays on your Mac.</p>
</div>

Speakeasy is a small menu-bar dictation app built around one fast path: prepared audio capture, a retained local speech model, deterministic cleanup, and reliable delivery into the app you were using.

## Why Speakeasy

- **Local after download.** Audio and transcription stay on-device.
- **Fast by default.** Parakeet TDT+CTC 110M runs through Metal on Apple Silicon.
- **Recoverable.** Accepted text is saved before paste; Copy Last, Paste Last, and one failed-capture retry are available from the menu.
- **Predictable.** Spoken punctuation and personal corrections are deterministic—no second model rewrites your words.
- **Small surface.** Two models, one menu-bar app, bounded history, and content-free diagnostics.

## Performance

On an M4 Pro, the default 110M model reproduced the following result against the previous Parakeet Unified default:

| | Parakeet 110M | Parakeet Unified |
|---|---:|---:|
| Warm inference p50 | **22.34 ms** | 47.52 ms |
| Warm inference p95 | **42.45 ms** | 95.23 ms |
| Model load p50 | **60.82 ms** | 208.34 ms |
| Peak RSS | **281.8 MiB** | 915.5 MiB |
| Model artifact | **135 MB** | 731 MB |

These are directional results from five synthetic English fixtures, repeated and interleaved on one machine. They explain the default choice; they are not a universal accuracy claim. The complete methodology and caveats are in [`docs/research/compact-model-benchmark-synthesis.md`](docs/research/compact-model-benchmark-synthesis.md).

## Install from source

### Requirements

- macOS 12 or newer
- Apple Silicon recommended for Metal acceleration
- Xcode command-line tools
- Rust toolchain (`rust/asr_bridge/rust-toolchain.toml` pins the version)
- About 300 MB free for the default model plus download staging

```bash
git clone https://github.com/Yeshwanthyk/speakeasy.git
cd speakeasy
./script/build_and_run.sh run
```

The script builds, signs, verifies, installs to `~/Applications/Speakeasy.app`, and opens the app. On first launch, Speakeasy downloads the default model from a pinned Hugging Face revision and verifies its exact size and SHA-256 before loading it.

To build without installing:

```bash
./build.sh
open build/Speakeasy.app
```

## Use

1. Grant microphone permission when prompted.
2. Grant Accessibility permission if you want automatic paste.
3. Tap **fn** to start and stop in Hands-Free mode, or hold **fn** to dictate in Push-to-Talk mode. Speakeasy ignores fn when you use it with another key.
4. Use the menu-bar icon to change or reset the shortcut, choose a dictation mode, cancel, change microphones, edit personal corrections, inspect stats, or recover the last transcript.

Speakeasy preserves the target application captured when recording begins. If automatic delivery is unavailable, the transcript remains in local history and on explicit recovery actions.

## Personal corrections

Choose **Corrections…** from the menu to add exact **Heard → Write** replacements. Corrections are whole-word or whole-phrase matches, ignore case and diacritics, and apply to the next dictation after Save without relaunching. Up to 128 rules are stored locally; matching performs no disk access or rule compilation during dictation.

## Models

Speakeasy deliberately exposes only two verified Q8 models:

| Role | Model | Artifact | License |
|---|---|---:|---|
| **Default** | Parakeet TDT+CTC 110M | 135 MB | CC-BY-4.0 |
| Fallback | Parakeet Unified EN 0.6B | 731 MB | CC-BY-4.0 |

Switching is transactional: download → verify → load → warm → persist. A failed replacement never displaces the last-known-good model.

Optional launch selection:

```bash
export SPEAKEASY_ASR_MODEL="parakeet-tdt-ctc-110m" # default
export SPEAKEASY_ASR_MODEL="parakeet-unified-en"    # fallback
```

Optional paths for an already-downloaded artifact still require an exact verification match:

```bash
export PARAKEET_110M_GGUF_PATH="/path/to/parakeet-tdt_ctc-110m-Q8_0.gguf"
export PARAKEET_UNIFIED_GGUF_PATH="/path/to/parakeet-unified-en-0.6b-Q8_0.gguf"
```

## Privacy and storage

- Microphone audio is processed locally and is not retained on disk.
- One failed capture may remain bounded in memory for explicit retry; it is cleared on success, discard, a new recording, or exit.
- Transcript history is bounded and stored locally so delivery failures are recoverable.
- Diagnostics contain timings, counters, backend information, and typed outcomes—not transcript text or audio.
- Network access is used to download a selected model from its pinned source.

## Development

```bash
swift test
cargo test --locked --manifest-path rust/asr_bridge/Cargo.toml
./script/test_asr_bridge_abi.sh
./script/test_benchmark.sh
./build.sh
```

`swift test` covers the Swift library. The ABI smoke test exercises the real Swift↔Rust C boundary. `build.sh` also compiles app-only startup and native-transcriber wiring, embeds `libasr_bridge.dylib`, signs the bundle, and verifies its icon and structure.

For the execution path and state ownership, see [`ARCHITECTURE.md`](ARCHITECTURE.md). For the standalone model harness, see [`benchmarks/README.md`](benchmarks/README.md).

---

Speakeasy uses [`transcribe.cpp`](https://github.com/handy-computer/transcribe.cpp) for local GGUF inference. Model weights remain subject to their respective licenses and attribution requirements.
