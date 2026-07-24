# Speakeasy Performance and Reliability Plan

## Plan Metadata

- Created: 2026-07-23
- Status: proposed
- Owner: yesh
- Baseline commit: `2ab0cc393060fba59e16ce70d4794457bf9820cc`
- Scope: app identity, startup, permissions, capture correctness, model lifecycle, transcription latency, paste reliability, telemetry, tests, and release mechanics
- Primary goal: make Speakeasy immediately visible, reliable across repeated use, and materially faster from hotkey to pasted text

## Goal

Speakeasy should feel instant even when its ASR model is still loading, never lose
captured speech because a system permission is missing, survive audio-device and
model failures without a restart, and provide measured latency rather than
subjective performance claims.

The work is split into reviewable blocks. Each phase should land as its own
logical commit after its acceptance tests pass.

## Current Verified State

### App icon

- `build.sh` converts `Assets/speakeasy.iconset` into `speakeasy.icns`.
- `Info.plist` correctly declares `CFBundleIconFile = speakeasy`.
- The source, built, bundled, and installed ICNS files have the same SHA-256.
- The visible mark occupies only about 4x5 pixels in the 16x16 representation
  and 11x13 pixels in the 32x32 representation.
- The old Wisp 16x16 asset used the full 16-pixel width.
- The source directory contains 14 PNGs, but `iconutil` packages only the 10
  canonical iconset representations. `icon_1024x1024@2x.png` is unused.
- LaunchServices has a malformed stale entry for the build-tree app because the
  final `build/Speakeasy.app` path exists before its plist and resources are
  installed. The installed app registration is correct.

### Runtime and memory

- Model construction runs off the main actor.
- The status item and hotkey are still created only after model construction
  completes, so the app has no visible loading state.
- The warmed Parakeet process used about 1.38 GB of physical memory and recorded
  a 1.80 GB peak during the audit.
- The capture engine remains armed while idle to avoid per-recording startup
  cost.
- The app uses full-buffer post-stop transcription rather than streaming
  inference.

### Permissions and signing

- The current built and installed bundles use a stable Apple Development
  designated requirement for `com.speakeasy.app`.
- Stable signing should preserve TCC grants across normal rebuilds with the same
  signer.
- The build still selects the first available Apple Development identity and
  silently falls back to ad-hoc signing.
- Microphone denial presents a Quit-only alert.
- Accessibility denial prevents synthetic paste, but also discards a successful
  transcript before it reaches history.
- Runtime errors carry descriptive strings internally, but production feedback
  discards those strings and only beeps.

### Capture and transcription

- `AudioCapture.beginRecording()` publishes recording state before resetting
  its buffers. A live callback can append samples that are then cleared.
- Every recording start reserves capacity for up to 5,760,000 floats, roughly
  22 MiB.
- Back-buffer swapping returns the callback buffer to zero capacity and causes
  later callback-thread allocations.
- The callback path uses locks shared with non-real-time work.
- The app does not observe `AVAudioEngineConfigurationChange`; input-device or
  format changes can stop the engine permanently until relaunch.
- A transcription timeout suppresses late output but cannot cancel a hung
  native inference call.
- Parakeet TDT copies the complete utterance at the Rust boundary.
- The app permits six-minute recordings while the current Parakeet TDT
  dependency documents a roughly four-to-five-minute input limit.

### Models

- A persisted missing or corrupt Nemotron selection can terminate startup before
  the installer or fallback model becomes available.
- Model installation validates only required-file presence and nonzero size.
- Downloads use a mutable Hugging Face `main` URL without pinned revisions,
  expected sizes, or hashes.
- Failed installations discard all completed downloads and restart from zero.
- Model selection has no progress, cancellation, retry, or visible warming
  state.

### Telemetry and tests

- The trace timestamp begins after the hotkey's asynchronous main-queue hop.
- The app logs `pasted` before the paste implementation attempts to create and
  post events.
- The debug summary is in-memory and does not establish a repeatable benchmark
  baseline.
- Swift strict-concurrency checking reports warnings that become errors in Swift
  6 language mode.
- The current baseline passes 83 Swift tests and 15 Rust tests.
- SwiftPM excludes `AppDelegate.swift`, `ParakeetTranscriber.swift`, and
  `main.swift`, leaving app startup and the production FFI path outside the main
  test suite.

## Product Performance Contract

Initial targets should be treated as ship gates and adjusted only with measured
evidence:

- Process start to visible status item: p95 below 100 ms, independent of model
  load duration.
- Hotkey event to visible recording feedback: p95 below 25 ms.
- Hotkey event to capture-ready state: p95 below 10 ms after initial engine
  preparation.
- Audio callback after preparation: zero heap allocations during steady-state
  capture.
- No first-frame loss at the recording-state boundary.
- Stop-grace duration: bounded by the existing 40-200 ms contract and included
  in every successful trace.
- Short-utterance release-to-paste: establish a 20-utterance baseline for each
  model, then require a material p50 and p95 improvement before changing the
  default.
- A timeout or native inference failure must return the app to a usable state
  within a fixed recovery budget.
- A successful transcription must remain recoverable even when paste permission
  or event creation fails.

## Non-Goals

- Cloud transcription.
- A full settings-window redesign before the menu-bar state is reliable.
- Public distribution work mixed into local performance fixes.
- Switching default ASR models without measured latency, memory, and quality
  evidence.
- Hiding failures behind longer timeouts or additional beeps.

## Phase 1 - App Icon and Bundle Assembly

### Goal

Make the app immediately recognizable in System Settings, Finder, alerts, and
the menu bar, while preventing incomplete bundles from being registered.

### Changes

- Create a durable master icon source, preferably SVG or an Icon Composer file.
- Redraw 16x16 and 32x32 representations optically rather than mechanically
  shrinking the detailed flower.
- Use a larger mark, stronger foreground/background contrast, thicker shapes,
  and substantially less empty canvas.
- Keep only the 10 canonical legacy iconset filenames consumed by `iconutil`.
- Add a script or documented command that regenerates the canonical iconset
  reproducibly from the master source.
- Preserve the ICNS path for macOS 12 compatibility.
- Consider an Icon Composer asset as a separate macOS 26 appearance layer after
  the legacy icon is correct.
- Assemble the app in a hidden staging directory and expose
  `build/Speakeasy.app` only after its executable, plist, resources, nested
  library, and signature are complete.
- Add a status-item tooltip and a Speakeasy-specific menu-bar glyph or stateful
  waveform treatment.

### Acceptance

- The 16x16 and 32x32 icons are recognizable at 100% scale beside standard
  macOS icons.
- The foreground remains clear in light and dark system surfaces.
- `iconutil` packages exactly the expected canonical representations.
- Source, generated ICNS, built bundle, and installed bundle hashes match.
- One build creates no malformed LaunchServices registration for the final
  build path.
- The installed app displays the intended icon in Privacy & Security.

### Commit

`fix: make Speakeasy icon legible at system sizes`

## Phase 2 - Immediate App Shell and Visible State

### Goal

Make the app visible and understandable before model loading finishes.

### Changes

- Split app-shell creation from transcriber construction.
- Create the status item, menu, feedback presenter, and hotkey registration
  immediately after duplicate-instance resolution.
- Represent startup and runtime state explicitly:
  - loading model
  - warming model
  - ready
  - recording
  - transcribing
  - downloading model with progress
  - recoverable error
- Disable or queue recording actions while the model is unavailable, with
  visible text instead of a beep.
- Make hotkey-registration failure a surfaced startup error rather than a log
  attached to a nonfunctional monitor object.
- Keep the menu responsive while model creation, destruction, and warmup happen
  off the main actor.

### Acceptance

- A test transcriber that blocks for several seconds does not delay status-item
  creation beyond the launch budget.
- The menu reports `Loading model...` while construction is blocked.
- Hotkey input during loading produces immediate, descriptive feedback.
- Registration failure displays a recoverable error and does not claim the app
  is ready.
- Main-thread heartbeat tests remain responsive during model load, warmup, swap,
  and destruction.

### Commit

`feat: expose model readiness in the menu bar`

## Phase 3 - Permission and Error Recovery

### Goal

Make every permission and runtime failure actionable without losing a valid
transcript.

### Changes

- Replace beep-only `SystemFeedback` with a visible status/menu notification
  that preserves the provided error text.
- Give microphone denial an Open Microphone Settings action.
- Avoid presenting the Accessibility system prompt, System Settings, and a
  blocking app alert at the same time.
- Track Accessibility status in the menu and provide Open Settings plus Retry
  actions.
- Store a successful transcript before checking whether synthetic paste is
  permitted.
- Copy successful text to the pasteboard even when automatic Cmd-V is blocked.
- Distinguish no speech, too-short recording, model warming, download failure,
  timeout, missing permission, and paste failure.
- Keep the existing stable code identity and make TCC continuity part of build
  verification.

### Acceptance

- Microphone denial, Accessibility denial, model failure, and timeout each show
  distinct visible copy and the relevant recovery action.
- Accessibility denial prevents synthetic paste but preserves the transcript in
  history and on the pasteboard.
- Relaunching after granting permission updates visible state without requiring
  a reinstall.
- Rebuilding with the pinned signer preserves mutually compatible designated
  requirements.

### Commit

`feat: add actionable permission and runtime recovery`

## Phase 4 - Real-Time Capture Correctness

### Goal

Remove first-frame loss, hotkey-path allocation, and callback-thread allocation
without regressing pre-roll or stop grace.

### Changes

- Reset and prepare capture buffers before publishing recording state.
- Define the exact ownership boundary between the pre-roll snapshot and the
  first live callback so samples appear exactly once.
- Replace six-minute eager reservation with reusable chunks or a bounded buffer
  pool.
- Preserve back-buffer capacity after flushing.
- Avoid heap allocation, logging, UI callbacks, and contended locks on the audio
  callback path.
- Keep limit notification and other non-real-time work on an appropriate queue.
- Decide whether the recording limit should automatically stop and transcribe
  or visibly wait for the user; do not leave coordinator state and flash state
  ambiguous.

### Acceptance

- A deterministic race test pauses `beginRecording()` at the publication
  boundary, emits a unique frame, resumes, and finds that frame exactly once.
- Twenty short recordings produce no roughly 22 MiB allocation at recording
  start.
- Allocations/System Trace reports no steady-state callback-thread allocations.
- Pre-roll and adaptive grace tests remain green.
- Limit-reached behavior leaves the coordinator, capture engine, flash, and menu
  in one coherent state.

### Commit

`fix: make audio capture allocation-stable`

## Phase 5 - Audio Engine Lifecycle Recovery

### Goal

Survive microphones, AirPods, sample-rate changes, sleep/wake, and media-service
resets without relaunching.

### Changes

- Observe `AVAudioEngineConfigurationChange`.
- Re-read the input format and recreate the converter and conversion buffer when
  the format changes.
- Reinstall or reconnect the input tap only from a serialized lifecycle path.
- Re-arm the engine after configuration changes and wake.
- End an in-progress recording with an explicit recoverable error when capture
  continuity cannot be guaranteed.
- Avoid synchronous engine destruction inside the framework's notification
  callback.
- Keep `prepare()` idempotent while allowing a stopped engine to recover.

### Acceptance

- A fake configuration-change notification stops and re-arms the engine once.
- Converter state reflects the new sample rate and channel count.
- Repeated changes do not install duplicate taps.
- A recording interrupted by a route change ends visibly and the next recording
  succeeds.
- Manual verification passes for built-in microphone, AirPods connect/disconnect,
  input-device switching, sleep, and wake.

### Commit

`fix: recover audio capture after device changes`

## Phase 6 - Model Integrity, Fallback, and Download UX

### Goal

Prevent model state from bricking startup and make large downloads resumable and
observable.

### Changes

- Move initial model resolution through a recovery-aware model manager.
- If the persisted model is missing or invalid:
  - keep the app shell alive
  - fall back to a verified local Parakeet model when available
  - offer reinstall or model selection
- Pin downloadable models to immutable repository revisions.
- Record expected file sizes and SHA-256 values in the manifest.
- Verify each completed file before promotion.
- Preserve verified partial downloads across retry.
- Add progress, cancel, retry, and disk-space reporting.
- Promote a model directory atomically only after all files verify.
- Persist a selection only after the new transcriber loads and warms
  successfully.

### Acceptance

- A persisted missing model does not terminate the app.
- A one-byte or wrong-hash model file fails before promotion.
- Failure on file three followed by retry does not redownload verified files one
  and two.
- Cancel leaves the previous model selected and usable.
- Insufficient disk space fails before large downloads begin.
- A failed new model never replaces the last known-good configuration.

### Commit

`fix: make ASR model installation recoverable`

## Phase 7 - Timeout and Native Failure Isolation

### Goal

Guarantee that a hung native inference cannot make the app permanently
unavailable.

### Changes

- Investigate cancellation support in the exact ONNX Runtime and
  `parakeet-rs` versions in use.
- If cancellation is reliable, expose it through the Rust FFI and coordinator
  state machine.
- Otherwise move model loading and inference into a helper process with a
  narrow, versioned request/response protocol.
- Terminate and recreate the helper after timeout, crash, or poisoned model
  state.
- Keep the app shell, history, hotkey feedback, and permissions outside the
  helper.
- Treat helper startup and model warmup as explicit readiness states.

### Acceptance

- A transcriber that never returns cannot block recording beyond timeout plus
  the recovery budget.
- A helper crash produces visible feedback and automatic restart.
- Late results from a timed-out generation are never pasted.
- The next successful session uses a fresh model instance.

### Commit

`fix: isolate hung ASR inference`

## Phase 8 - Streaming and Runtime Benchmark

### Goal

Choose the fastest acceptable local transcription path with evidence.

### Candidates

- Current Parakeet TDT 0.6B int8 full-buffer transcription.
- Nemotron 3.5 0.6B int8 cache-aware streaming in 560 ms chunks.
- Parakeet realtime EOU 120M streaming in 160 ms chunks.
- Smaller or more heavily quantized model variants only when their quality is
  acceptable.

### Measurements

- Cold model-load time.
- Warm model-load time.
- Warmup time.
- Idle physical footprint and peak footprint.
- CPU time and energy while idle, recording, and transcribing.
- Release-to-first-text and release-to-final-text p50/p95.
- Word error rate or stable semantic accuracy on a representative local fixture
  set.
- Short-command accuracy below 1.5 seconds.
- Long-form stability.
- Punctuation, casing, multilingual behavior, and hallucination rate.
- Effect of intra-op and inter-op thread counts on this Mac.
- Effect of ONNX session memory settings.

### Changes after selection

- Stream audio chunks during recording for models that support incremental
  inference.
- Keep partial hypotheses internal unless product UX needs them.
- Finalize and paste only after the recording stop boundary.
- Remove the Parakeet utterance copy if the upstream API accepts borrowed
  samples; otherwise define an ownership-transferring FFI path.
- Lower the TDT maximum recording duration or split inputs so the app never
  exceeds the runtime's supported range.
- Revisit the six-minute in-memory capture cap after the model decision.

### Acceptance

- Benchmark input, hardware, commands, and raw results are committed or attached
  to the plan.
- The selected default materially improves release-to-paste p50 and p95 without
  an agreed quality regression.
- Peak memory and idle energy are recorded for every candidate.
- The fallback model remains available when the preferred model fails.
- Streaming state resets cleanly between utterances.

### Commit

`perf: add measured streaming transcription path`

## Phase 9 - Paste, Clipboard, and History Durability

### Goal

Make text delivery observable and recoverable.

### Changes

- Change `Pasting` to return an explicit success or failure result.
- Log `pasted` only after paste event construction and posting succeeds.
- Decide and document whether Speakeasy permanently owns the clipboard after a
  transcription or restores the prior contents safely.
- Preserve a successful transcript before attempting automatic paste.
- Add Copy Last Transcript and Retry Paste actions.
- Add a bounded `TranscriptStore.flush()` for application termination.
- Keep transcript retention configurable if sensitive history is a concern.

### Acceptance

- Injected event-source, key-down, and key-up failures never produce a `pasted`
  outcome.
- Successful text survives Accessibility denial and paste failure.
- App termination immediately after transcription preserves the latest entry.
- Clipboard behavior is deterministic and covered by tests.

### Commit

`fix: make transcript delivery durable`

## Phase 10 - Telemetry and Performance Gates

### Goal

Make latency regressions visible before release.

### Changes

- Capture the timestamp at the Carbon hotkey event before dispatching to main.
- Add structured signpost intervals for:
  - process start to app shell
  - model resolution
  - model load
  - warmup
  - hotkey to capture
  - recording stop grace
  - inference
  - paste
- Record model kind, utterance duration bucket, outcome, and failure stage
  without logging transcript contents.
- Add a repeatable benchmark command or opt-in test harness for short, medium,
  and long fixture audio.
- Store local benchmark output outside normal transcript history.
- Define p50/p95 regression thresholds in CI or a release verification script.

### Acceptance

- Main-queue contention before coordinator delivery appears in the trace.
- Paste failure cannot be counted as success.
- A 20-utterance warm benchmark produces reproducible p50 and p95 output.
- Performance reports include memory and model kind.
- No telemetry contains dictated text.

### Commit

`perf: add end-to-end transcription benchmarks`

## Phase 11 - Swift Concurrency and Integration Coverage

### Goal

Remove broad unchecked concurrency assumptions and test the production app
boundaries.

### Changes

- Replace mutable captured `TranscriptionTrace` values with single-owner or
  returned-value updates.
- Narrow or remove `AppCoordinator: @unchecked Sendable`.
- Mark feedback, callback, and lock types with correct actor or Sendable
  contracts.
- Fix AppKit completion-handler isolation in `ScreenEdgeFlash`.
- Make hotkey identifier state concurrency-safe without unannotated mutable
  globals.
- Add a full app target or integration harness that compiles and exercises:
  - `AppDelegate`
  - `ParakeetTranscriber`
  - Swift/Rust FFI layout
  - production startup wiring
- Generate the FFI header with `cbindgen` instead of manually duplicating C
  layouts in Swift.
- Add an opt-in real-model fixture test with known 16 kHz mono audio.

### Acceptance

- Strict concurrency type-checking produces no warnings.
- The project is ready to enable Swift 6 language mode without isolation errors.
- A real model loads and transcribes a known fixture through the production FFI.
- ABI layout comes from a generated C header.
- The release app target is part of the build verification gate.

### Commit

`refactor: enforce production concurrency contracts`

## Phase 12 - Install and Distribution Hardening

### Goal

Keep local builds stable and make public distribution a deliberate separate
pipeline.

### Local install changes

- Require a configured stable signing identity for install/run workflows.
- Keep ad-hoc signing available only as an explicit build-only option.
- Increment `CFBundleVersion` for every installed artifact.
- Preserve the prior installed app until the staged replacement is completely
  verified.
- Add rollback if the final replacement or launch verification fails.
- Verify installed version, inode, icon hash, designated requirement, nested
  signature, process path, and launch state.

### Public distribution changes

- Build a universal binary if Intel support is required.
- Sign with Developer ID Application.
- Enable hardened runtime and validate required entitlements.
- Use secure timestamps.
- Notarize and staple the distributed artifact.
- Validate with `codesign`, `spctl`, and notarization tooling on a clean machine.

### Acceptance

- Local rebuilds keep mutually compatible designated requirements.
- A missing development identity fails before replacing the installed app.
- A failed replacement leaves the prior app recoverable.
- Version and build numbers identify the installed artifact uniquely.
- The public artifact passes Gatekeeper verification on a clean Mac.

### Commit

`build: harden Speakeasy installation and release`

## Test Matrix

Every implementation phase must run the relevant focused tests followed by:

```sh
swift test
cargo test --manifest-path rust/parakeet_bridge/Cargo.toml --locked
cargo clippy --manifest-path rust/parakeet_bridge/Cargo.toml --all-targets -- -D warnings
./build.sh
codesign --verify --deep --strict build/Speakeasy.app
```

Before replacing the installed app:

```sh
./script/build_and_run.sh --verify
codesign --verify --deep --strict ~/Applications/Speakeasy.app
```

Manual release verification must include:

- Fresh launch with an already-installed model.
- Fresh launch with a missing persisted model.
- Fresh launch with a corrupt persisted model.
- Microphone allowed and denied.
- Accessibility allowed and denied.
- Twenty repeated short dictations.
- A long dictation within the selected model's supported range.
- AirPods connect and disconnect.
- Input-device switch.
- Sleep and wake.
- Model download success, failure, cancellation, and retry.
- Transcription timeout and native-process recovery.
- Immediate quit after a successful transcription.

## Research Sources

- Apple Human Interface Guidelines, App icons:
  <https://developer.apple.com/design/human-interface-guidelines/app-icons>
- Apple, Creating your app icon using Icon Composer:
  <https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer>
- Apple, Improving app responsiveness:
  <https://developer.apple.com/documentation/xcode/improving-app-responsiveness>
- Apple, `AXIsProcessTrustedWithOptions`:
  <https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions>
- Apple, `AVAudioEngineConfigurationChange`:
  <https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange>
- Apple TN3127, Inside Code Signing Requirements:
  <https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements>
- Apple, Notarizing macOS software before distribution:
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- `parakeet-rs` 0.3.6 source selected by `Cargo.lock`.

## Recommended Execution Order

1. Phase 1: icon and bundle assembly.
2. Phases 2-3: immediate shell, state, permissions, and feedback.
3. Phases 4-5: capture correctness and audio lifecycle recovery.
4. Phases 6-7: model recovery and native failure isolation.
5. Phase 8: measured streaming/runtime decision.
6. Phases 9-10: durable delivery and performance telemetry.
7. Phase 11: concurrency and integration hardening.
8. Phase 12: install and distribution hardening.

