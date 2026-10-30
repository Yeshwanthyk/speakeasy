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
                                    \-> annotating(id) -> idle   (when marks exist)
```

Capture must confirm a running engine and a fresh converted input callback before `startingCapture` becomes `recording`. The token prevents stale timeout or transcription callbacks from completing a newer session. Warmup is tracked separately as `pending`, `warming`, `ready`, or `failed`; hotkeys are ignored until warmup reaches `ready` or `failed`.

UI-affecting collaborators are main-actor isolated. Blocking capture stop and native inference run off the main thread.

## Personal Corrections

`TranscriptCorrectionStore` keeps a versioned, bounded JSON document under Application Support. The Corrections window validates and persists a replacement snapshot on a utility queue before `AppCoordinator` atomically publishes its precompiled `TranscriptPostProcessor`. The dictation path only snapshots the immutable processor and scans accepted text; it never reads settings, writes correction data, builds regular expressions, or recursively processes replacement output.

`TranscriptPostProcessor` can also carry a `PhoneticCorrector`, disabled by default and enabled by the experimental Corrections preference (effective after editing corrections or restarting). Enabled exact correction pairs supply its taught terms. Terms are indexed by consonant-skeleton keys (vowels stripped, c/q folded to k, within-word duplicate collapse) over same-length word windows plus capped edit-distance entries with first-letter and length guards. Short terms and a static common-word list cannot be fuzzy-matched. Ambiguous skeleton keys are dropped; matches never overlap; replacements always come from the taught canonical spelling. The phonetic pass runs on raw text before commands and exact corrections.

The accepted transcript records per-stage change counts alongside the raw and delivered text; e2e traces contain counts only, never transcript text.

Every terminal outcome flows through `recordTerminal` into `E2ETraceStore`, an append-only JSONL log of per-pass records gated on mandatory milestones (successful deliveries require capture start, key-up, stop return, transcription start/end, and paste request). `E2ESummarizer` reports segment medians over successful insertions only, excluding user think-time by construction.
Production creates `logs/dictation-e2e.jsonl` under its bundle-ID Application Support directory at coordinator startup and logs write errors. Each record includes the sleep-inclusive key-down idle gap since the last successful native inference, whether rewarm started during the pass, whether any rewarm was still in flight when finalization began, and native total/session-wait milliseconds when the bridge returned success. A cancelled or timed-out pass may not have native timings yet. The same fields appear in the terminal OSLog line.

## Markups (draw while dictating)

`MarkupSessionController` observes the dictation lifecycle through `AnnotationRecordingObserving`. When a recording starts and Screen Recording access exists (macOS 14+), it shows transparent, click-through `MarkupOverlayController` canvases on every display. The canvases never take mouse input. A 60 Hz poll of the global modifier state and pointer location turns Shift-plus-movement into ink; ink that strays at least 6 pt from its start commits a mark when Shift is released. Global monitors turn a Shift-click into a pin, or remove the visible mark under it (`MarkupHitTest`), and fade on-screen marks on any scroll. For each new mark, the coordinator appends the current recording sample offset (including pre-roll) to `annotationCuts`, and `MarkupScreenCapturer` takes a ScreenCaptureKit still of that display excluding Speakeasy's own windows. A stroke starting within 1.2 s of the previous one extends that mark. Removing a mark drops its cut by sample offset and renumbers the rest.

If any cut exists when dictation stops, the coordinator enters `annotating(UUID)` instead of `transcribing`, cancels live preview and segment commit, ends the capture off-main, and splits the samples with `MarkupTranscriptCutter`: speech before the first mark, then one span per mark, each cut snapped to the quietest 20 ms frame within 600 ms. Each span goes through the speech gate, windowed final transcription, hallucination filter, and corrections. Dictation intents are ignored until the state returns to idle.

`MarkupBundleWriter` then draws each mark onto its still (`MarkupRenderer`), crops it with `MarkupCropPlanner` to the mark plus context inside the window it landed on, packs the crops shortest-column-first (`ContactSheetLayout`), and writes `contact-sheet.png`, `frames/`, and `summary.md` under `Application Support/<bundle id>/markups/`. Only the 20 newest bundles are kept, and audio is never written. The summary text is pasted into the front app like a transcript, or left on the clipboard when no paste target is stable. It carries no image: apps given text and a PNG on one pasteboard item paste only the image. Instead the text names the bundle path so agents can open the files. Each mark also records the accessibility element under it (`MarkupElementLocator`; read off the main thread with a 100 ms message timeout, never the value of a password field), and the summary names it ("Safari, over “Save” button"). Consecutive marks on the same display whose stills match a 16×8 luma grid within 0.05 share one contact-sheet tile drawn on the newest still. The sheet keeps at most 12 tiles, spread evenly and always including the first and last, while every mark keeps its own full frame. The summary tells the agent to open the contact sheet before answering.

## Delivery

`PasteboardPaster` writes the transcript as one pasteboard item carrying the nspasteboard.org `TransientType` and `AutoGeneratedType` markers, so clipboard managers skip it, then posts Command-V and restores the previous clipboard 500 ms later (only if nothing newer was copied). Any path that leaves the transcript on the clipboard rewrites it without the markers. The V key comes from `PasteKeyResolver`: the active layout's Command layer, then its plain layer, then the ASCII-capable layout, so Dvorak, "Dvorak - QWERTY ⌘", and non-Latin layouts paste correctly. Text Input Sources are read on the main thread and cached for other threads.

`PasteUndoWindow` remembers the app that received the last automatic paste. For 30 s, while that app is still in front, **Undo Last Dictation** sends it a layout-resolved Command-Z once. History's **Fix…** stores the corrected text and feeds `CorrectionDiff`, which keeps only short word swaps (up to three words each side; case, punctuation, insertions, and deletions are ignored). `CorrectionTally` counts them, bounded to 200 entries, and offers a correction rule after the same fix is made twice.

## Hotkey

In push-to-talk, `FunctionKeyGestureState` latches hands-free dictation on two fn taps less than 300 ms apart; the next press stops it, and Escape or a mode or shortcut change clears the latch. Once a fn hold starts dictation, `FunctionChordBreaker` posts one press of the unassigned key 0x44 under fn at the HID tap, so Raycast or Karabiner fn-tap actions see a chord rather than a tap. An annotated-session event tap drops that marked press before the focused app sees it; if the tap cannot be created, nothing is posted. Too-short recordings are discarded silently, and "No speech detected" is a status rather than an error beep. Each dictation's ending is recorded as a `DictationAttempt`, which setup's practice step turns into guidance.

## Audio Capture

`AudioCapture` keeps `AVAudioEngine` prepared separately from recording state. Converted mono 16 kHz samples flow through a bounded ring buffer while idle. Recording prepends a short pre-roll window and uses an adaptive stop grace derived from recent callback cadence.

After capture stops, `SpeechGate` decides whether the recording contains speech worth transcribing: 20 ms frame energy through vDSP, an adaptive bar at three times the 20th-percentile frame noise floor plus a conservative absolute floor, zero-crossing rate below 0.20 to reject broadband noise, and four consecutive voiced frames required. Steady tones read as hum and are rejected; burst-modulated quiet speech passes.

While recording, `LivePreviewController` may re-transcribe the most recent buffered audio (capped to the last 15 s) on a utility queue for a live preview. `PreviewRevisionPolicy` keeps the visible transcript monotonic — word count never shrinks between adopted partials — while the final batch pass remains the only source of delivered text. Preview passes wait at least 700 ms apart, need at least 0.5 s of new audio, run one-at-a-time in a reserved high-bit run-ID space, and are serialized against finalization by the native session.

`RecordingIndicator` shows recording state in a click-through, never-key panel on the display holding the focused window (else the pointer's). By default it is a black island grown out of the notch (a red dot and four level bars in the wings), or a small plate inside the menu bar on flat displays; the bottom placement is a small pill above the Dock. Processing dims the dot and sweeps the bars; an error opens one line of text for 1.6 s, and a late `hide()` cannot cut it short. `OverlayModel` holds these transitions as pure state; `RecordingIndicatorGeometry` holds the placement math. The live preview is drawn only when the person opts in (`OverlayPreferences`, schema 2): v1 stored the live-text flag only when toggled, so only a stored `true` survives migration, and a stored bottom-pill style survives only alongside it.

Recording storage starts at one minute and grows geometrically, with a configurable 60-minute / ~230 MB Float32 PCM safety ceiling. The ceiling truncates only the callback that reaches it and stops capture with explicit feedback. Preview reads the last 15 seconds of the recording (including pending callbacks), while the one-second ring remains dedicated to pre-roll. Failed captures can be replayed up to the same ceiling. Final inference above 60 seconds runs sequential overlapping 60-second windows (two seconds of overlap) on the retained session; adjacent transcript word overlaps are deduplicated, and cancellation is checked between windows. The timeout scales with captured duration plus 30 seconds, without the former ten-minute cap. This bounds native Metal graph size: in the pinned `transcribe-cpp-sys 0.1.3` source, `src/arch/parakeet/model.cpp` builds the offline encoder from all mel frames (`build_encoder_graph` near line 953), while `encoder.cpp` notes offline full attention near line 365 and allocates a `T_enc × T_enc` mask near line 382. `model.cpp` also allocates the corresponding square host mask near line 1060. No safe 10–60-minute single-pass memory bound is established, so we do not send such inputs in one run.

During recording, a separate scanner reads only new 20 ms frames under the capture buffer locks. After 20 seconds it commits at a 300 ms low-energy pause, or forces a bounded 60-second window with a two-second overlap. One background native call and one pending PCM window are allowed; pending cuts merge only while they fit a native window. At key-up pending work stops starting, the in-flight call settles, and the uncommitted tail takes priority before the pending window. Results join in audio order with forced-overlap word deduplication; the joined raw text still follows the original hallucination filter and delivery path. Segment metrics are persisted in E2E JSONL. Preview transcribes the uncommitted tail and prefixes accepted committed text while retaining its monotonic revision gate.

The capture lifecycle observes `AVAudioEngineConfigurationChange` and wake events. Recovery is serialized off Apple's notification callback, invalidates callbacks from old graph generations, rebuilds the input format/converter/tap, and becomes ready only after a fresh converted callback. Route changes arriving during a rebuild are revalidated against a later callback or trigger another generation; transient failures receive bounded retries. A device change during recording aborts that recording rather than transcribing discontinuous audio.

With no microphone pinned, `InputRoutePolicy` replaces a Bluetooth default input (HFP or LE) with the first built-in input, never a virtual or aggregate device, because the idle engine would otherwise hold the headset in its narrowband call profile. The preference is on by default, and changing it rebuilds the graph on the system route.

## Meetings

Meetings are opt-in (`meetingsEnabled`, off by default). `MeetingController` records two tracks:

- **You** is the dictation engine's converted 16 kHz stream, via `AudioCapture.setSampleObserver`, so device choice and the Bluetooth policy are shared.
- **Them** is ScreenCaptureKit system audio (16 kHz mono, Speakeasy excluded), recorded when Screen Recording access exists.

Each `MeetingTrackPipeline` streams to `ChunkedWAVWriter`: 5-minute 16-bit WAV chunks whose header is rewritten after every append. `MeetingSegmenter` cuts 3–30 s segments at 500 ms pauses and skips stretches with no speech energy. `MeetingSampleWindow` keeps only unsegmented audio, so memory is bounded by one segment however long the call runs.

`MeetingTranscriptionWorker` transcribes segments one at a time through `AppCoordinator.transcribeMeetingSegment`: speech gate, the shared retained session (run IDs in the 1<<62 space; the native mutex serializes them with dictation), hallucination filter, and corrections. More than 60 pending segments are skipped and counted rather than queued. Each segment is appended to `segments.jsonl`, and a torn last line is ignored on read.

On stop, `MeetingEchoFilter` drops mic segments that repeat the system track (at least 60% shared words within 4 s), and `MeetingNotes` extracts talk time and likely action items. On macOS 26 with Apple Intelligence, `MeetingSummarizer` adds an on-device summary and title. `transcript.md` is written next to `manifest.json`. A meeting still marked `recording` at launch, after a quit or crash, becomes `interrupted`: it adopts the chunks on disk and gets a transcript. `MeetingRetention` deletes audio after the chosen period (default 30 days) and keeps transcripts.

`MeetingDetector` polls `MicrophoneClientMonitor` once a second on macOS 14.2+. That monitor reads CoreAudio process objects, maps helper processes to their app, and excludes Speakeasy, whose own engine holds the mic. A known call app is offered after 2 s on the mic and a browser after 20 s. A declined app is snoozed until it has been off the mic for 60 s, and a recorded call ends 3 s after its app leaves. An unanswered offer closes after 20 s and never records by itself.

## Release

CI (`.github/workflows/ci.yml`) runs `swift test` and requires XCTest's top-level pass line, because a crashed test process can otherwise exit 0. It also builds the app, builds the Sparkle variant with a placeholder key, runs the ABI smoke and bridge tests, and runs the benchmark harness checks. `release.yml` runs CI first. With a Developer ID certificate secret, `build.sh` signs inside-out with the hardened runtime and a microphone entitlement, and `script/notarize.sh` notarizes and staples. With Sparkle keys, the app embeds Sparkle 2.7.1 (pinned SHA-256) and the release publishes a signed `appcast.xml`. Without secrets, releases stay ad-hoc signed.

## Model Lifecycle

`ASRModelKind` selects one pinned Q8_0 GGUF artifact. Each artifact records an immutable Hugging Face revision, expected byte count, SHA-256, and license. `ASRModelInstaller` downloads into the destination filesystem, verifies it, and atomically promotes it. Existing ONNX directories are not consulted.

The default is Parakeet TDT+CTC 110M Q8_0. Parakeet Unified EN 0.6B Q8_0 is the only fallback and user-visible alternative. Legacy Parakeet TDT v3 and Nemotron selections migrate to Unified. A model switch downloads if necessary, verifies, constructs, and warms a replacement off-main, then atomically swaps the app's `Transcriber` and persists the selection; any failure leaves the last-known-good transcriber and selection unchanged.
After 90 seconds without successful inference, key-down or system wake/screen unlock requests a one-second, off-main silent rewarm; it is skipped if final transcription has already started. The retained native session mutex serializes any rewarm already running with final transcription. Finalization requests cooperative cancellation of an in-flight rewarm through transcribe.cpp's abort token; if the backend does not abort promptly, final inference still waits for the session. A final-run cancel during that wait is retained and consumed before inference. Rewarm and final inference use user-interactive dispatch queues; startup and replacement warmups use a dedicated dispatch worker, not the cooperative executor. Native inference holds a `.userInitiated` process activity, without disabling system sleep. There is no periodic keepalive.

## Native Boundary

`rust/asr_bridge` depends on released `transcribe-cpp 0.1.3` with Metal enabled and ONNX removed. Its C ABI exports:

- `asr_create` / `asr_create_result_free`
- `asr_transcribe` / `asr_result_free` (result embeds by-value `AsrTimings`: total, session-wait, and audio duration measured inside the bridge, surfaced as `NativeASRTimings` with realtime factor)
- `asr_destroy`

All exported bodies catch Rust panics. Rust owns handles and returned strings; Swift owns and pins PCM for the synchronous call. The native session is retained between dictations and serialized by a mutex. A poisoned session is treated as unrecoverable and must be destroyed and recreated.

The GGUF run path accepts `&[f32]`, so there is no full-utterance `Vec` copy at the Rust engine boundary. Distributed builds set `GGML_NATIVE=OFF` to avoid embedding build-machine-specific CPU instructions.

The Swift declarations still mirror the small C ABI manually. Generating and importing the header with `cbindgen` remains the next ABI-hardening step.
