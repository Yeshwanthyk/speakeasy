# Mission

**Mission:** Harden Wisp for extensibility, AI-agent friendliness, and test coverage by working through the audited punch list phase-by-phase with sub-agent review, tests, and commit per phase.

## Done Criteria

- [ ] All P0 safety bugs fixed (panic-across-FFI, transcriber thread-safety, main-thread blocking, TranscriptStore isolation, KeyComboMonitor static var, FFI error propagation, NUL-safe result strings).
- [ ] All P1 quick-win tests landed (TranscriptionTrace, TranscriptStore, FloatRingBuffer edges, CaptureStopTiming edges, ModelPathResolver, AppCoordinator: a11y-denied, triple-toggle ignore, store integration; Rust `#[cfg(test)]` block).
- [ ] All P2 architectural seams: Transcriber protocol extraction, AudioEngineProtocol seam, transcriptionQueue injection, carbonModifiers visibility, @MainActor annotations, AppCoordinator state exposure.
- [ ] P3 ergonomics: HallucinationFilter / UserFeedback widening / state-machine comment / dead code removal / README expansion / ARCHITECTURE.md / FFI contract comments / plans updated / .gitignore tightened / toolchain pins.
- [ ] P4 deferred or tracked in NEXT.md: CI workflow, model provisioning script, integration test target, cbindgen, signing pipeline.
- [ ] After every phase: sub-agent review → fix → `swift test` green → `cargo test` green → commit.

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

- _(none yet)_
