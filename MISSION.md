# Mission

**Mission:** Harden Wisp for extensibility, AI-agent friendliness, and test coverage by working through the audited punch list phase-by-phase with sub-agent review, tests, and commit per phase.

## Done Criteria

- [x] All P0 safety bugs fixed (panic-across-FFI, transcriber thread-safety, main-thread blocking, TranscriptStore isolation, KeyComboMonitor static var, FFI error propagation, NUL-safe result strings).
- [x] All P1 quick-win tests landed (TranscriptionTrace, TranscriptStore, FloatRingBuffer edges, CaptureStopTiming edges, ModelPathResolver, AppCoordinator: a11y-denied, triple-toggle ignore, store integration; Rust `#[cfg(test)]` block).
- [x] All P2 architectural seams: Transcriber protocol extraction, AudioEngineProtocol seam, transcriptionQueue injection, carbonModifiers visibility, @MainActor annotations, AppCoordinator state exposure.
- [x] P3 ergonomics: HallucinationFilter / UserFeedback widening / state-machine comment / dead code removal / README expansion / ARCHITECTURE.md / FFI contract comments / plans updated / .gitignore tightened / toolchain pins.
- [x] P4 deferred or tracked in NEXT.md: CI workflow, model provisioning script, integration test target, cbindgen, signing pipeline.
- [x] After every phase: sub-agent review → fix → `swift test` green → `cargo test` green → commit.

## Guardrails

- One phase = one commit. Never skip review or tests.
- Never use `try!`, `!` non-null assertions, `AnyView`, or `as Type` in Swift edits (per AGENTS.md).
- Never break existing tests. If a fix requires breaking a test, call it out before merging.
- Do not widen scope beyond the audited punch list without adding the item to NEXT.md first.
- Respect existing uncommitted WIP (TranscriptStore + MenuBarController + AppCoordinator diff) — commit it as the mission baseline before starting.
- Do NOT commit destructive operations (history rewrites, force push) without explicit user request.

## Mission Reference

- Full audit: the user's previous turn (four sub-agent reports synthesized).
- Phased checklist: see NEXT.md.
- Original mission trigger: user request "scan the repo... figure out improvements... use sub agents... come back with increments... [then] set this as mission... review → fix → comment [commit] → continue."

## Critical Learnings Log

(Updated as work progresses.)

- **Phase 1 — poisoned Parakeet mutex is unrecoverable.** `ParakeetModel`
  mutates `prev_state` and ONNX session frames during `recognize_batch`; a
  panic mid-inference leaves the model inconsistent. `parakeet_transcribe`
  therefore returns an error on a poisoned lock rather than silently
  calling `into_inner()`. Caller should destroy+recreate the handle.
- **Phase 1 — Swift-to-Rust struct layout is a latent assumption.** Swift
  `struct { UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>? }` happens
  to match Rust `#[repr(C)]` on arm64 for two pointer-sized fields, but this
  is not guaranteed across Swift versions. Parked in NEXT.md Phase 9
  (cbindgen + bridging header).
- **Phase 2 — app-only sources need the full build path.** `swift test`
  excludes `AppDelegate.swift`, `ParakeetTranscriber.swift`, and `main.swift`;
  `./build.sh` caught the `@MainActor` initializer isolation error in the
  non-SwiftPM app build.
- **Phase 2 — XCTest callbacks must not cross actor boundaries.** The
  off-main `endRecording` regression test records thread state inside the
  stub under a lock, then asserts from the main-actor test body.
- **Phase 4 — process environment tests need serialization.** Tests that
  mutate `PARAKEET_MODEL_DIR` save/restore the prior value while holding a
  process-wide lock so parallel Swift test runs do not leak state.
- **Phase 6 — mutable audio conversion state must be synchronized.** Moving
  converter setup from `init` to `prepare` made converter/buffer state
  mutable; access is guarded by `conversionLock` so shutdown cannot race an
  in-flight tap callback.
- **Phase 8 — app rename needs data-path compatibility.** The canonical
  product name is now Wisp, with bundle/logging identifiers moved to
  `com.wisp.app`. `ModelPathResolver` still falls back to the legacy
  `com.speakeasy.app` model directory so existing installs do not lose their
  model provisioning.
