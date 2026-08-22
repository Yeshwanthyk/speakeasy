# Architecture

Speakeasy is a menu-bar macOS app that captures microphone audio, transcribes it locally through a Rust/transcribe.cpp bridge, stores recent transcripts, and pastes accepted text into the frontmost app.

## Data Flow

1. `KeyComboMonitor` receives the persisted dictation shortcut, which defaults to standalone fn.
2. `AppCoordinator` moves through `startingCapture` and enters recording only after `AudioCapture` confirms a fresh input callback.
3. On the next hotkey press, `AppCoordinator` moves to transcribing, hides the screen flash, and calls `AudioCapture.endRecording()` on the injected transcription queue.
4. `AudioCapture` returns captured samples plus pre-roll and stop-grace metadata.
5. `AppCoordinator` rejects empty, too-short, or silent audio before transcription.
6. The `Transcriber` implementation pins the contiguous PCM buffer and calls the Rust ASR bridge.
7. Rust borrows the 16 kHz mono samples and runs a retained transcribe.cpp GGUF session using Metal or CPU.
8. `AppCoordinator` rejects empty or likely hallucinated transcription text before correction.
9. The accepted raw text passes through an immutable spoken-command and exact-correction matcher compiled when settings change.
10. Raw and corrected text are appended to `TranscriptStore`; corrected text is pasted through `Pasting`.

## State Machine

```text
idle -> startingCapture -> recording -> transcribing(token) -> idle
```

Capture must confirm a running engine and a fresh converted input callback before `startingCapture` becomes `recording`. The token prevents stale timeout or transcription callbacks from completing a newer session. Warmup is tracked separately as `pending`, `warming`, `ready`, or `failed`; hotkeys are ignored until warmup reaches `ready` or `failed`.

UI-affecting collaborators are main-actor isolated. Blocking capture stop and native inference run off the main thread.

## Personal Corrections

`TranscriptCorrectionStore` keeps a versioned, bounded JSON document under Application Support. The Corrections window validates and persists a replacement snapshot on a utility queue before `AppCoordinator` atomically publishes its precompiled `TranscriptPostProcessor`. The dictation path only snapshots the immutable processor and scans accepted text; it never reads settings, writes correction data, builds regular expressions, or recursively processes replacement output.

`TranscriptPostProcessor` can also carry a `PhoneticCorrector`: taught terms are indexed by consonant-skeleton keys (vowels stripped, c/q folded to k, within-word duplicate collapse) over same-length word windows plus capped edit-distance entries with first-letter and length guards. Ambiguous skeleton keys are dropped; matches never overlap; replacements always come from the taught canonical spelling. The phonetic pass runs on raw text before commands and exact corrections.

A `TextPolishing` seam sits after corrections and before persistence. The default is no polisher; when one is installed, `PolishBudget` bounds generation (`max(48, min(256, ceil(tokens x 1.8) + 24))`) and `PolishGuard` structurally validates output — collapse, one-to-two-word meaning loss, implausible expansion, or emptied text falls back to the corrected source. Filler removal and stutter deduplication stay allowed.

Every terminal outcome flows through `recordTerminal` into `E2ETraceStore`, an append-only JSONL log of per-pass records gated on mandatory milestones (successful deliveries require capture start, key-up, stop return, transcription start/end, and paste request). `E2ESummarizer` reports segment medians over successful insertions only, excluding user think-time by construction.

## Audio Capture

`AudioCapture` keeps `AVAudioEngine` prepared separately from recording state. Converted mono 16 kHz samples flow through a bounded ring buffer while idle. Recording prepends a short pre-roll window and uses an adaptive stop grace derived from recent callback cadence.

After capture stops, `SpeechGate` decides whether the recording contains speech worth transcribing: 20 ms frame energy through vDSP, an adaptive bar at three times the 20th-percentile frame noise floor plus a conservative absolute floor, zero-crossing rate below 0.20 to reject broadband noise, and four consecutive voiced frames required. Steady tones read as hum and are rejected; burst-modulated quiet speech passes.

While recording, `LivePreviewController` may re-transcribe the most recent buffered audio (capped to the last 15 s) on a utility queue for a live preview. `PreviewRevisionPolicy` keeps the visible transcript monotonic — word count never shrinks between adopted partials — while the final batch pass remains the only source of delivered text. Preview passes wait at least 700 ms apart, need at least 0.5 s of new audio, run one-at-a-time in a reserved high-bit run-ID space, and are serialized against finalization by the native session.

The capture lifecycle observes `AVAudioEngineConfigurationChange` and wake events. Recovery is serialized off Apple's notification callback, invalidates callbacks from old graph generations, rebuilds the input format/converter/tap, and becomes ready only after a fresh converted callback. Route changes arriving during a rebuild are revalidated against a later callback or trigger another generation; transient failures receive bounded retries. A device change during recording aborts that recording rather than transcribing discontinuous audio.

## Model Lifecycle

`ASRModelKind` selects one pinned Q8_0 GGUF artifact. Each artifact records an immutable Hugging Face revision, expected byte count, SHA-256, and license. `ASRModelInstaller` downloads into the destination filesystem, verifies it, and atomically promotes it. Existing ONNX directories are not consulted.

The default is Parakeet TDT+CTC 110M Q8_0. Parakeet Unified EN 0.6B Q8_0 is the only fallback and user-visible alternative. Legacy Parakeet TDT v3 and Nemotron selections migrate to Unified. A model switch downloads if necessary, verifies, constructs, and warms a replacement off-main, then atomically swaps the app's `Transcriber` and persists the selection; any failure leaves the last-known-good transcriber and selection unchanged.

## Native Boundary

`rust/asr_bridge` depends on released `transcribe-cpp 0.1.3` with Metal enabled and ONNX removed. Its C ABI exports:

- `asr_create` / `asr_create_result_free`
- `asr_transcribe` / `asr_result_free` (result embeds by-value `AsrTimings`: total, session-wait, and audio duration measured inside the bridge, surfaced as `NativeASRTimings` with realtime factor)
- `asr_destroy`

All exported bodies catch Rust panics. Rust owns handles and returned strings; Swift owns and pins PCM for the synchronous call. The native session is retained between dictations and serialized by a mutex. A poisoned session is treated as unrecoverable and must be destroyed and recreated.

The GGUF run path accepts `&[f32]`, so there is no full-utterance `Vec` copy at the Rust engine boundary. Distributed builds set `GGML_NATIVE=OFF` to avoid embedding build-machine-specific CPU instructions.

The Swift declarations still mirror the small C ABI manually. Generating and importing the header with `cbindgen` remains the next ABI-hardening step.
