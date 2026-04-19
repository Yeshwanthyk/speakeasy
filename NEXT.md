# Phased Mission Checklist

Each phase: implement → sub-agent review → fix findings → run `swift test` + `cargo test` → commit → continue.

## Phase 0 — Baseline

- [x] Commit the in-flight WIP (TranscriptStore, MenuBarController, AppCoordinator/AppDelegate diff) as the mission baseline.
- [x] Create MISSION.md, NEXT.md.

## Phase 1 — P0 Rust FFI hardening

- [x] Wrap every `#[no_mangle] extern "C"` body in `std::panic::catch_unwind`. Convert panics → error result.
- [x] Replace embedded-NUL sentinel with sanitised `CString` (U+FFFD replacement preserves content).
- [x] Surface real model-load error text via a `ParakeetCreateResult { handle, error }` struct; Swift forwards it.
- [x] Protect `ParakeetModel` with a `Mutex`; poisoned lock returns an error (model state is inconsistent after a panic).
- [x] Add `#[cfg(test)]` block in `lib.rs`: NUL handling, Unicode, free idempotence, null-handle / null-path / missing-path error paths, compile-time Send/Sync check (13 tests).
- [x] Pin toolchain: `rust-toolchain.toml` (1.87.0) + `--locked` in `build.sh`.
- [x] Post-review: poison-recovery → error, doc comment tightened (Rust-only panics), tests renamed, Swift URL-rep error message fixed, toolchain pinned to specific version.

## Phase 2 — P0 Swift safety fixes

- [x] `AudioCapture.endRecording()` no longer blocks main thread (dispatch the semaphore wait off-main or make async).
- [x] `TranscriptStore` → `@MainActor` (enforce the documented contract).
- [x] `KeyComboMonitor.nextIdentifier` → atomic / `OSAtomic` / random UUID-derived value (no shared static mutable).
- [x] Add `@MainActor` to `ScreenEdgeFlash` (touches NS APIs).

## Phase 3 — P2 Transcriber protocol seam

- [x] Extract `Transcriber` protocol into `Sources/Transcriber.swift` (inside library target).
- [x] `ParakeetTranscriber` conforms; file stays excluded from SPM target.
- [x] `AppCoordinator` depends on `Transcriber` (already does via protocol; verify & tighten).
- [x] Rewire tests to use a `FakeTranscriber` that lives in the test target (if not already).

## Phase 4 — P1 Quick-win tests (batch)

- [x] `TranscriptionTraceTests` (5 tests).
- [x] `TranscriptStoreTests` (5 tests: eviction, persistence, malformed JSON, truncation, clear).
- [x] `FloatRingBufferTests` additional edges (4 tests).
- [x] `CaptureStopTimingTests` additional edges (2 tests).
- [x] `ModelPathResolverTests` (2 tests).
- [x] `AppCoordinatorTests` additions: a11y-denied path, triple-toggle ignore, store integration.

## Phase 5 — P2 remaining seams & visibility

- [x] `transcriptionQueue` injectable into `AppCoordinator`.
- [x] `KeyComboMonitor.carbonModifiers(from:)` → internal (to enable tests).
- [x] Expose read-only `isRecording: Bool` from `AppCoordinator` (removes side-effect assertions).
- [x] Tests for carbonModifiers + queue injection determinism.

## Phase 6 — P2 AudioCapture seam

- [x] Introduce `AudioEngineProtocol`; move hardware access out of `AudioCapture.init` into `prepare()`.
- [x] Add tests: prepare installs tap, engine-start failure surfaces, shutdown removes tap, grace semaphore signalled.

## Phase 7 — P3 Agent-friendliness polish

- [x] Extract `HallucinationFilter` from `AppCoordinator` as its own named type with tests.
- [x] Widen `UserFeedback` protocol to `notify(event:)` enum; migrate call sites.
- [x] Add MARK / state-machine comment to `AppCoordinator`.
- [x] Delete `ScreenEdgeFlash.hide(window:)` dead code; drop unused `flash(duration:lineWidth:)` from `Flashing`.

## Phase 8 — P3 docs & hygiene

- [ ] Pick one canonical name (Speakeasy vs Wisp) and make it consistent; update README.
- [ ] Expand README: prerequisites, model provisioning, test command.
- [ ] Add ARCHITECTURE.md: data-flow, state machine, FFI contract.
- [ ] Add top-of-file FFI contract comment to `lib.rs`.
- [ ] Update `plans/*.md` statuses (phases 0-4 done vs open).
- [ ] `.gitignore`: `.pi/`, `*.DS_Store`, untrack tracked `.DS_Store`.
- [ ] Delete or document empty `resources/`.

## Phase 9 — P4 parked to NEXT (not this mission)

- [ ] CI workflow (macOS runner, cached cargo, `swift test` + `cargo test`).
- [ ] `fetch_model.sh` with checksum.
- [ ] `WispIntegrationTests` target (opt-in, fixture WAV).
- [ ] cbindgen FFI header generation + Swift bridging header so
      `ParakeetResult` / `ParakeetCreateResult` layouts are C-ABI-guaranteed
      rather than a Swift-default coincidence (parked from Phase 1 review).
- [ ] Signing / notarization pipeline; `NSAccessibilityUsageDescription`.

(Phase 9 items are parked in this file only. They are NOT in scope for this mission.)

## Mission Check Cadence

After each phase:

1. Sub-agent review (general-purpose or review-deep) on only the changed files.
2. Fix any P0/P1 findings from the review (P2 findings deferred to NEXT.md unless trivial).
3. `swift test` (from repo root) → green.
4. `cargo test --manifest-path rust/parakeet_bridge/Cargo.toml` → green.
5. `git commit` — terse message, no emoji.
6. Update NEXT.md checkboxes, append critical learnings to MISSION.md if material.
