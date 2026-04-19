# Architecture

Wisp is a menu-bar macOS app that captures microphone audio, transcribes it locally through a Rust FFI bridge, stores recent transcripts, and pastes accepted text into the frontmost app.

## Data Flow

1. `KeyComboMonitor` receives the Hyper+S hotkey.
2. `AppCoordinator` moves from idle to recording and tells `AudioCapture` to begin accumulating samples.
3. On the next hotkey press, `AppCoordinator` moves to transcribing, hides the screen flash, and calls `AudioCapture.endRecording()` on the injected transcription queue.
4. `AudioCapture` returns captured samples plus pre-roll and stop-grace metadata.
5. `AppCoordinator` rejects empty, too-short, or silent audio before transcription.
6. `Transcriber` runs Parakeet inference. The app implementation is `ParakeetTranscriber`; tests inject fakes.
7. `AppCoordinator` rejects empty or likely hallucinated transcription text before paste.
8. Successful text is appended to `TranscriptStore` and pasted through `Pasting`.

## State Machine

`AppCoordinator` owns the user-visible recording lifecycle:

```text
idle -> recording -> transcribing(token) -> idle
```

The `token` on the transcribing state prevents stale timeout or transcription callbacks from completing a newer session. Warmup is tracked separately as `pending`, `warming`, `ready`, or `failed`; hotkeys are ignored until warmup reaches `ready` or `failed`.

UI-affecting collaborators (`ScreenEdgeFlash`, `TranscriptStore`, menu bar updates) are main-actor isolated. Blocking capture stop and Parakeet inference run off the main thread.

## Audio Capture

`AudioCapture` keeps the AVAudioEngine prepared separately from recording state. The engine/input-node protocol seam allows tests to verify tap installation, start failure, shutdown, and stop-grace behavior without touching real hardware.

Converted mono 16 kHz samples flow through a bounded ring buffer while idle. When recording starts, Wisp prepends a short pre-roll window to avoid clipped leading syllables. When recording stops, it waits for an adaptive grace window derived from recent callback cadence.

## FFI Contract

The Rust bridge in `rust/parakeet_bridge/src/lib.rs` exports a small C ABI:

- `parakeet_create` returns `ParakeetCreateResult { handle, error }`.
- `parakeet_transcribe` returns `ParakeetResult { text, error }`.
- `parakeet_result_free`, `parakeet_create_result_free`, and `parakeet_destroy` release Rust-owned memory.

All exported bodies catch Rust panics so unwinding never crosses the FFI boundary. Result strings are NUL-terminated UTF-8; interior NULs in model output are replaced with `U+FFFD`. The Parakeet handle serializes inference through an internal mutex, and a poisoned mutex is treated as unrecoverable model state: the caller should destroy and recreate the handle.

The Swift side currently declares matching result structs manually. C header generation via cbindgen is parked in `NEXT.md` Phase 9.
