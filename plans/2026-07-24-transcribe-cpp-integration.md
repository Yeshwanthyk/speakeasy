# transcribe.cpp Integration for Speakeasy

## Decision

Adopt `transcribe-cpp` behind the existing Rust dynamic-library boundary and remove the ONNX `parakeet-rs` engine. Do not copy C++ optimizations into Speakeasy.

Ship against the released `transcribe-cpp = 0.1.3` crate with `default-features = false, features = ["metal"]`, locked by Cargo. Existing ONNX directories are intentionally replaced by pinned, verified GGUF artifacts. Evaluate the unreleased 0.2.0 line separately; do not pin production to its moving `main` branch.

This preserves Speakeasy's small Swift surface, macOS 12 target, and panic-safe FFI while removing the legacy runtime and inheriting upstream GGML/Metal optimizations and model-family support through one maintained dependency.

## What changed upstream

### Handy

Handy introduced `transcribe.cpp` in [`31d8fc2`](https://github.com/cjpais/Handy/commit/31d8fc2) and made it the primary GGUF/GGML engine in v0.9.0. Its integration:

- loads one `Model` and retains one `Session` across dictations;
- selects Metal/CPU at model load and records the backend actually bound;
- reads capabilities from GGUF metadata instead of hard-coding behavior;
- uses the same batch path for Whisper, Parakeet, Granite, Voxtral, Qwen3-ASR, MedASR, and other GGUF families;
- uses optional family-specific extensions only where the model architecture accepts them (a capability such as initial-prompt support does not imply acceptance of the Whisper-specific extension);
- defaults timestamp selection to runtime `Auto` rather than maintaining model-family switches;
- routes streaming audio to a dedicated worker and exposes committed/tentative hypotheses;
- keeps `transcribe-rs` only for legacy ONNX models.

Handy moved from `transcribe-cpp` 0.1.0 to 0.1.1 in [`5f54e17`](https://github.com/cjpais/Handy/commit/5f54e17), then to 0.1.3 in [`c912c6b`](https://github.com/cjpais/Handy/commit/c912c6b). At inspected HEAD `390729a` (2026-07-23), Handy still uses released 0.1.3; it does not yet consume transcribe.cpp's post-0.1.3 main branch.

### transcribe.cpp 0.1.3

The released line provides:

- a borrowed `&[f32]` run API, avoiding Speakeasy's current full-utterance `samples.to_vec()` copy;
- GGML Metal and optimized CPU execution;
- model/session reuse, per-model compute serialization, cancellation, batch inference, timings, and input limits;
- runtime capabilities: languages, translation, language detection, streaming, timestamps, maximum audio length, architecture, variant, backend, and device;
- native streaming with stable committed/tentative text;
- 16 model families and 60+ variants, including Parakeet, Whisper, Canary, Moonshine, Qwen3-ASR, Cohere, SenseVoice, FunASR, both Nemotron streaming families, Granite, Voxtral, and MedASR;
- published GGUF quantizations and model-specific WER/numerical validation.

Relevant optimization history in transcribe.cpp includes:

- decoder graph/dispatch improvements across Parakeet, Whisper, Canary, Moonshine, and Cohere;
- Parakeet encoder graph reuse and conformer changes in [`144d24c`](https://github.com/handy-computer/transcribe.cpp/commit/144d24c);
- migration to the native GGML threadpool, correct thread defaults, and leak fixes in [`ebddd49`](https://github.com/handy-computer/transcribe.cpp/commit/ebddd49);
- safer Metal auto-selection in [`666e2bb`](https://github.com/handy-computer/transcribe.cpp/commit/666e2bb);
- improved discrete/integrated GPU probe ordering in [`bf8cfd8`](https://github.com/handy-computer/transcribe.cpp/commit/bf8cfd8).

Upstream's M4 Max publication benchmark reports Parakeet TDT v3 Q8 at 74 ms for 11 seconds of audio and 231 ms for 35.3 seconds on Metal. These numbers establish potential, not a Speakeasy performance claim; Speakeasy must benchmark its own hardware, audio, model quantization, load state, and release-to-paste path.

### Post-0.1.3 / unreleased 0.2.0 work

The inspected transcribe.cpp `main` is versioned 0.2.0 but has no 0.2.0 tag. Since 0.1.3 it adds:

- Multitalker Parakeet streaming in [`fd8b8f8`](https://github.com/handy-computer/transcribe.cpp/commit/fd8b8f8);
- MOSS Transcribe-Diarize in [`5a5a496`](https://github.com/handy-computer/transcribe.cpp/commit/5a5a496);
- structured diarization, speaker IDs/segments, and raw model text in [`8c7ae67`](https://github.com/handy-computer/transcribe.cpp/commit/8c7ae67);
- Whisper short-form tail-truncation continuation in [`b6a6aca`](https://github.com/handy-computer/transcribe.cpp/commit/b6a6aca).

These changes alter the public ABI and result types. Consume them only after a tagged crate release and a deliberate bridge ABI revision. Handy's current catalog already contains a MOSS entry while its locked 0.1.3 engine and known-architecture list do not support `moss`; this is concrete evidence that catalog presence must never be treated as loadability proof.

## Current Speakeasy constraints

At baseline `3df8303`:

- The baseline `rust/parakeet_bridge/Cargo.toml` depended on `parakeet-rs 0.3.6`; the implemented [`rust/asr_bridge/Cargo.toml`](../rust/asr_bridge/Cargo.toml) now depends only on `transcribe-cpp 0.1.3`.
- The baseline Rust bridge hard-coded two ONNX model variants and copied every Parakeet utterance with `samples.to_vec()`; the implemented `rust/asr_bridge` replaces it.
- [`Sources/ModelPathResolver.swift`](../Sources/ModelPathResolver.swift) conflates user-visible model identity, storage shape, and engine selection in `ASRModelKind`.
- [`Sources/Transcriber.swift`](../Sources/Transcriber.swift) supports only full-buffer transcription and warmup.
- The baseline `ParakeetTranscriber.swift` manually duplicated the old C ABI; [`Sources/TranscribeCppTranscriber.swift`](../Sources/TranscribeCppTranscriber.swift) now owns the generic bridge.
- [`build.sh`](../build.sh) already has the right dependency direction: Swift -> one Rust dylib -> native engine.
- The official transcribe.cpp Swift wrapper is not the right first integration point: its package mirror is not published and it raises the deployment target to macOS 13. The Rust crate fits the current macOS 12 build and preserves one native boundary.

## Target architecture

```text
Swift app
  AppCoordinator
    Transcriber (existing batch contract)
    StreamingTranscriber? (optional capability)
    CancellableTranscriber? (optional capability)
          |
          v
  Generated C header + Swift adapter
          |
          v
Rust asr_bridge cdylib
  AsrHandle { Mutex<transcribe_cpp::Session> }
          |
          +--> transcribe-cpp 0.1.3 -> GGML -> Metal/CPU
```

### Ownership

- `AppCoordinator` owns the selected model generation and rejects stale results.
- A model manager owns the selected descriptor and download/install state; failed model switches leave the current loaded model unchanged.
- Rust owns native `Model`, `Session`, stream, cancellation token, and all native strings.
- Swift owns captured PCM. Batch inference borrows the pinned contiguous buffer for the duration of the synchronous FFI call.
- An active stream owns its compute lease from begin through finalize/reset/drop; another run returns busy instead of racing.

### Model descriptor

Replace the expanding `ASRModelKind` switch surface with a data-driven descriptor:

```swift
struct ASRModelDescriptor: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let artifact: ModelArtifact     // immutable URL, bytes, SHA-256, filename
    let expectedCapabilities: ExpectedCapabilities
    let license: ModelLicense
}
```

GGUF architecture is discovered by transcribe.cpp at load time. Do not create a Swift enum case for every upstream family. The descriptor chooses artifact and policy; runtime metadata remains authoritative for capabilities.

Persist descriptor `id`, not enum ordinals. Map existing `parakeet-tdt` and `nemotron-3.5-asr` preference values to their GGUF replacements during resolution.

### Versioned FFI

Rename the library boundary from Parakeet-specific to ASR-specific. Generate its header with `cbindgen` and import it through a Clang module; do not add more `_silgen_name` declarations.

Use a versioned create struct with `struct_size` and `abi_version`:

```c
typedef struct {
    uint32_t struct_size;
    uint32_t abi_version;
    int32_t engine_kind;
    const char *model_path;
    const char *language;
    int32_t backend;      // auto, cpu, metal
    int32_t device_index;
    int32_t n_threads;    // 0 = upstream default
} asr_create_options;
```

Required operations:

- create/destroy;
- batch transcribe returning text plus native timings;
- capabilities query after load;
- cancel current generation without waiting on the session mutex;
- stream begin/feed/snapshot/finalize/reset;
- matching free functions for every Rust allocation.

Keep panic containment on every exported body. Model/session poisoning or native failure requires handle recreation; no unwind crosses FFI.

### Capability surface

Expose one owned JSON payload for variable-length capabilities and decode it into a Swift `Codable` type. Keep hot-path transcript text/timings in fixed C structs. This avoids unstable C layouts for language arrays while keeping PCM and transcript paths direct.

Capability decisions must be runtime-driven:

- streaming availability;
- language auto-detection and accepted languages;
- translation support;
- timestamp level;
- cancellation;
- maximum audio duration;
- actual backend/device.

### Streaming seam

Do not force streaming into the existing batch `Transcriber` contract. Add a separate optional protocol:

```swift
protocol StreamingTranscriber: Transcriber {
    func beginStream() throws
    func feed(samples: UnsafeBufferPointer<Float>) throws -> StreamSnapshot
    func finalizeStream() throws -> String
    func resetStream()
}
```

The audio callback must not call native inference or allocate. It writes to the existing bounded buffer path; a dedicated worker drains reusable chunks into the stream. Stop closes the input generation, drains through the stop-grace boundary, finalizes once, and returns only the final transcript for paste. Partial text is optional UI state, never authoritative history.

## Migration

### 1. Prove the dependency in isolation

- Add `transcribe-cpp 0.1.3` with Metal to the Rust bridge.
- Set `TRANSCRIBE_CMAKE_ARGS=-DGGML_NATIVE=OFF` for distributed builds unless the artifact intentionally targets one exact CPU; the upstream native build otherwise selects the build machine's CPU features.
- Add a Rust integration test that loads one pinned Parakeet TDT v3 Q8 or Q4 GGUF fixture and transcribes known 16 kHz mono audio.
- Verify `MACOSX_DEPLOYMENT_TARGET=12.0`, release build, dylib linkage, codesigning, model destruction, repeated load/run/drop, and execution on the oldest supported Apple Silicon generation.
- Record cold load, warm run, physical/peak memory, and native timings.

Exit: the dependency builds and runs on Speakeasy's deployment target without changing the app default.

### 2. Generalize the boundary

- Introduce generic `asr_bridge` names and a generated C header.
- Retain one transcribe.cpp model/session behind the opaque handle.
- Preserve existing Swift `Transcriber` behavior.
- Return capabilities and actual backend after load.
- Remove the full-utterance `samples.to_vec()` copy.

Exit: Swift and Rust tests remain green and one GGUF model works end to end.

### 3. Add a catalog and safe model installation

- Introduce descriptors with immutable Hugging Face revision URLs, expected bytes, SHA-256, required free space, and license metadata.
- Download to resumable staging, verify hash, then atomically promote.
- Ignore existing ONNX directories; they are no longer runtime inputs.
- Persist selection only after load and warmup succeed.

Initial GGUF candidates:

1. Parakeet TDT v3 Q8 or Q4: direct quality/performance comparison with the current default.
2. Parakeet Unified EN Q8 or Q4: best English streaming candidate.
3. Nemotron 3.5 Q8 or Q4: multilingual streaming candidate.

Exit: failed download/load cannot replace the last-known-good model.

### 4. Benchmark batch before changing the default

Use the same fixture corpus against current ONNX and GGUF Metal/CPU. Measure cold load, warmup, idle/peak memory, release-to-final, release-to-paste, WER/semantic checks, short commands, and long input. Run 20 warm repetitions and report p50/p95.

Exit: select a default only if latency materially improves without an agreed quality or memory regression.

### 5. Add cancellation, then streaming

- Wire transcribe.cpp cancellation into the coordinator timeout generation.
- Add the worker/chunk streaming path behind `StreamingTranscriber`.
- Start with finalize-only UI; add committed/tentative overlay later if useful.
- Verify rapid start/stop, cancellation, model switch, timeout, stream reset, and audio route changes.

Exit: a hung/cancelled run recovers, and streaming state cannot leak across recordings.

### 6. Adopt tagged 0.2.x separately

After upstream tags and publishes 0.2.x:

- update the bridge ABI for `raw_text`, diarization mode, speaker IDs, and speaker segments;
- add Multitalker/MOSS only if speaker attribution is a product requirement;
- include the Whisper tail-continuation regression fixture;
- do not combine this ABI/model expansion with the initial 0.1.3 engine migration.

## Production and test call graphs

### Batch production

```text
hotkey stop
 -> AudioCapture.endRecording
 -> AppCoordinator validates PCM and generation
 -> ASRTranscriber.transcribe
 -> asr_transcribe(handle, borrowed PCM)
 -> EngineHandle::Gguf Session::run
 -> Transcript + native timings
 -> generation check / hallucination filter
 -> durable history
 -> paste
```

### Streaming production

```text
hotkey start
 -> AppCoordinator begins capture generation
 -> streaming worker begins native stream
 -> audio callback writes reusable capture buffers
 -> worker drains chunks -> asr_stream_feed
 -> optional partial snapshot to UI
hotkey stop
 -> stop grace closes generation
 -> worker drains final chunk -> finalize
 -> final transcript follows normal history/paste path
```

### Tests

```text
AppCoordinator tests -> fake Transcriber / fake StreamingTranscriber
Swift bridge tests    -> fake C shim or null/malformed argument tests
Rust ABI tests        -> no-model safety + generated header layout
Rust model tests      -> opt-in pinned GGUF + known WAV
Benchmark             -> recorded ONNX baseline and GGUF engine on identical PCM
```

## Risks and controls

| Risk | Control |
| --- | --- |
| GGUF migration requires new large downloads | Dual engine; no in-place conversion; previous model remains usable |
| Upstream 0.x ABI moves | Released crate + Cargo.lock; versioned Speakeasy FFI; no `main` dependency |
| Metal increases load/peak memory | Drop old engine before loading new; measure; CPU fallback |
| Swift binding currently requires macOS 13 | Integrate the Rust crate behind the existing macOS 12 dylib |
| Streaming races with batch/model switching | Explicit compute lease and coordinator generation token |
| Native timeout still blocks a mutex | Cancellation token stored outside session mutex; unload/recreate on failure |
| Catalog drifts from runtime truth | Catalog is download/policy metadata; GGUF capabilities are authoritative; reject unknown architectures before download/selection |
| Build-host CPU instructions leak into releases | Build distributed artifacts with `GGML_NATIVE=OFF` and test the oldest supported CPU |
| Benchmark claims do not transfer to the user's Mac | Record local p50/p95, memory, model hash, backend, and hardware |

## Verification gates

```sh
swift test
cargo test --manifest-path rust/asr_bridge/Cargo.toml --locked
cargo clippy --manifest-path rust/asr_bridge/Cargo.toml --all-targets -- -D warnings
./build.sh
codesign --verify --deep --strict build/Speakeasy.app
```

Add an opt-in real-model command that records model SHA-256, transcribe.cpp version/commit, actual backend/device, native timings, end-to-end timings, and memory. Transcript contents must stay out of normal telemetry.

## Source evidence

- Handy v0.9.0 release notes: [`src/content/release-notes/0.9.0.md`](https://github.com/cjpais/Handy/blob/390729a8007a9c09be38416bc7755e4fa04165c3/src/content/release-notes/0.9.0.md)
- Handy dependency/backend configuration: [`src-tauri/Cargo.toml`](https://github.com/cjpais/Handy/blob/390729a8007a9c09be38416bc7755e4fa04165c3/src-tauri/Cargo.toml)
- Handy model/session/run integration: [`transcription.rs`](https://github.com/cjpais/Handy/blob/390729a8007a9c09be38416bc7755e4fa04165c3/src-tauri/src/managers/transcription.rs)
- transcribe.cpp 0.1.3 Rust API: [`lib.rs`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/bindings/rust/transcribe-cpp/src/lib.rs), [`model.rs`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/bindings/rust/transcribe-cpp/src/model.rs), [`session.rs`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/bindings/rust/transcribe-cpp/src/session.rs)
- transcribe.cpp 0.1.3 model support and build: [`README.md`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/README.md)
- Parakeet TDT v3 validation/benchmarks: [`parakeet-tdt-0.6b-v3.md`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/docs/models/parakeet-tdt-0.6b-v3.md)
- Parakeet Unified streaming/benchmarks: [`parakeet-unified-en-0.6b.md`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/docs/models/parakeet-unified-en-0.6b.md)
- Nemotron 3.5 streaming/benchmarks: [`nemotron-3.5-asr-streaming-0.6b.md`](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/docs/models/nemotron-3.5-asr-streaming-0.6b.md)
