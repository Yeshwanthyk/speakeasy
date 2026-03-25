# STT Latency Improvement Subtasks

## Plan Metadata
- Created: 2026-03-25
- Status: draft
- Owner: yesh
- Scope: break Wisp latency recommendations into implementable subtasks
- Priority order:
  1. Warmup readiness gate
  2. Hot capture engine
  3. Ring buffer + pre-roll
  4. Adaptive stop grace
  5. Stage timing telemetry
  6. Data-driven follow-ups (short-clip padding, runtime/model work, streaming)

## Goal
Reduce perceived and actual voice-to-text latency in Wisp without regressing transcription quality or paste reliability.

## Current State
- Wisp records a full utterance, stops capture, then runs one full-buffer Parakeet transcription (`Sources/AppCoordinator.swift`, `Sources/AudioCapture.swift`, `Sources/ParakeetTranscriber.swift`, `rust/parakeet_bridge/src/lib.rs`).
- Model warmup exists, but launches detached at utility priority and is not readiness-gated (`Sources/AppDelegate.swift:19-24`).
- Capture engine and tap are started/stopped for every utterance (`Sources/AudioCapture.swift:69-127`).
- No stage timing telemetry exists beyond engine startup ms logging (`Sources/AudioCapture.swift:104-105`).

## Out of Scope
- Cloud/off-device STT
- UI redesign
- Large model format migrations unless phase 6 data proves necessary
- Multi-language feature expansion unrelated to latency

## Progress Tracking
- [ ] Phase 0: Baseline telemetry + measurement harness
- [ ] Phase 1: Warmup readiness gate
- [ ] Phase 2: Hot capture engine lifecycle
- [ ] Phase 3: Ring buffer + pre-roll
- [ ] Phase 4: Adaptive stop grace
- [ ] Phase 5: Telemetry hardening + acceptance thresholds
- [ ] Phase 6: Conditional follow-ups (short-clip path, runtime/model experiments, streaming spike)

---

## Phase 0: Baseline telemetry + measurement harness

### Goal
Make every later change measurable. Do this first.

### Subtasks
- [ ] Define target timings to log:
  - hotkey press -> `AudioCapture.start()` entered
  - `AudioCapture.start()` entered -> first converted buffer received
  - hotkey release -> `audioCapture.stop()` return
  - transcription start -> transcription end
  - transcription end -> paste requested
  - total hotkey release -> paste requested
- [ ] Add a small timing struct / trace ID that follows one utterance through capture, transcribe, paste.
- [ ] Emit structured logs with utterance duration, sample count, and timing breakdown.
- [ ] Add a debug-only summary path for median / p95 capture start and release-to-text latency during manual testing.
- [ ] Document a repeatable manual benchmark script in this plan.

### Files likely touched
- `Sources/AppCoordinator.swift`
- `Sources/AudioCapture.swift`
- maybe new `Sources/TranscriptionTrace.swift`

### Verification
- [ ] Build succeeds
- [ ] Logs show one correlated timing block per utterance
- [ ] Can compare before/after each later phase

---

## Phase 1: Warmup readiness gate

### Goal
Remove first-use cold-start races.

### Subtasks
- [ ] Replace detached fire-and-forget warmup with explicit warmup state management.
- [ ] Introduce coordinator/app startup state that distinguishes:
  - model loaded
  - model warming
  - model ready
- [ ] Decide UX behavior while warmup is incomplete:
  - ignore hotkey and show feedback, or
  - queue first request until warmup completes
- [ ] Ensure warmup completion or failure is logged distinctly from model load.
- [ ] Add tests for:
  - hotkey during warmup
  - warmup failure path
  - warmup success transitions to ready

### Files likely touched
- `Sources/AppDelegate.swift`
- `Sources/AppCoordinator.swift`
- `Sources/ParakeetTranscriber.swift`
- `Tests/WispTests/*`

### Dependencies
- Depends on Phase 0 timing hooks if possible, but can proceed independently.

### Verification
- [ ] First transcription no longer races detached warmup
- [ ] Ready state is explicit
- [ ] Tests cover state transitions

---

## Phase 2: Hot capture engine lifecycle

### Goal
Stop paying AVAudioEngine startup/teardown cost on every utterance.

### Subtasks
- [ ] Refactor `AudioCapture` to separate engine lifecycle from recording lifecycle.
- [ ] Add explicit methods such as:
  - `prepare()` / `arm()`
  - `beginRecording()`
  - `endRecording()`
  - `shutdown()`
- [ ] Keep `AVAudioEngine`, input node, converter, and tap armed while app is idle.
- [ ] Ensure idle path does not accumulate unbounded audio if not recording.
- [ ] Handle app startup, sleep/wake, and teardown cleanly.
- [ ] Confirm accessibility/hotkey flow still works while engine stays armed.
- [ ] Add tests for coordinator behavior against the revised capture protocol.

### Files likely touched
- `Sources/AudioCapture.swift`
- `Sources/AppCoordinator.swift`
- `Sources/AppDelegate.swift`
- maybe `Sources/AppDelegate.swift` termination handling
- `Tests/WispTests/*`

### Risks
- Hot mic resource behavior
- device/input route changes
- tap lifecycle bugs / duplicate taps

### Verification
- [ ] Repeated utterances avoid engine start cost in telemetry
- [ ] No duplicate tap installation
- [ ] App shutdown releases audio resources cleanly

---

## Phase 3: Ring buffer + pre-roll

### Goal
Reduce clipped leading syllables and improve perceived instant capture.

### Subtasks
- [ ] Add a bounded ring buffer for recent 16k mono Float samples while engine is armed.
- [ ] Keep ring buffer writing active even when user is not “recording”.
- [ ] On start-recording, prepend configurable pre-roll from the ring buffer (initial target: 300-450 ms).
- [ ] Ensure pre-roll is appended only once per utterance.
- [ ] Add config constants for:
  - ring buffer size
  - pre-roll size
  - memory cap
- [ ] Add tests for ring buffer behavior:
  - empty buffer
  - partial buffer
  - full wraparound
  - exact pre-roll extraction
- [ ] Add telemetry fields for prepended sample count / duration.

### Files likely touched
- `Sources/AudioCapture.swift`
- maybe new `Sources/FloatRingBuffer.swift`
- `Tests/WispTests/*`

### Dependencies
- Strongly depends on Phase 2.

### Verification
- [ ] Start-of-utterance clipping subjectively reduced
- [ ] Telemetry shows non-zero prepended duration when expected
- [ ] No major memory growth over long idle sessions

---

## Phase 4: Adaptive stop grace

### Goal
Reduce clipped endings without adding a fixed, blunt sleep.

### Subtasks
- [ ] Track recent callback intervals / converted buffer durations inside capture.
- [ ] Derive a stop grace window from observed cadence, clamped to a safe min/max.
- [ ] On stop, wait only the computed grace period before finalizing samples.
- [ ] Compare adaptive grace vs current immediate stop using telemetry.
- [ ] Add tests for grace calculation logic independent of AVAudioEngine.
- [ ] Add a fallback grace for sparse/no timing history.

### Files likely touched
- `Sources/AudioCapture.swift`
- maybe new `Sources/CaptureStopTiming.swift`
- `Sources/AppCoordinator.swift`
- `Tests/WispTests/*`

### Dependencies
- Best done after Phase 2; can share capture cadence info with Phase 3.

### Verification
- [ ] End-of-utterance clipping reduced in manual testing
- [ ] Added latency stays bounded and visible in logs
- [ ] Grace logic is deterministic in tests

---

## Phase 5: Telemetry hardening + acceptance thresholds

### Goal
Turn raw logs into ship/no-ship criteria.

### Subtasks
- [ ] Capture baseline numbers before Phases 1-4 land.
- [ ] Re-run measurements after each phase.
- [ ] Define acceptance targets, e.g.:
  - p50 repeated-start latency drops materially
  - p95 release->text improves or stays flat
  - no regression in paste success / no-speech handling
- [ ] Add a short markdown results section to this plan after each phase.
- [ ] Decide whether any phase should be reverted or tuned.

### Verification
- [ ] Plan contains before/after numbers
- [ ] Can attribute wins to specific phases

---

## Phase 6: Conditional follow-ups

### 6A. Short-clip path / padding
Only do this if telemetry shows very short utterances fail or degrade.

#### Subtasks
- [ ] Measure latency + error rate by utterance duration bucket.
- [ ] Identify whether sub-1.5s clips produce poor Parakeet behavior in Wisp.
- [ ] If yes, prototype an in-memory short-clip pad/fast-path before FFI call.
- [ ] Validate quality impact on short utterances.

#### Files likely touched
- `Sources/ParakeetTranscriber.swift`
- maybe `rust/parakeet_bridge/src/lib.rs`
- tests / fixtures

### 6B. Runtime / model experiments
Only do this if Phases 1-4 still leave release->text latency unacceptable.

#### Subtasks
- [ ] Benchmark current Parakeet int8 path on representative short/medium utterances.
- [ ] Evaluate smaller/faster local models or alternative Parakeet runtime knobs.
- [ ] Check whether `transcribe-rs` / Parakeet runtime exposes batching, chunking, or lower-latency decode options.
- [ ] Produce a trade-off table: latency, quality, memory, binary complexity.

### 6C. Streaming / incremental transcription spike
Largest upside, largest scope.

#### Subtasks
- [ ] Inspect whether current Rust runtime can support chunked incremental decode rather than one post-stop `recognize_batch` call.
- [ ] If not, identify the narrowest viable architecture change:
  - chunked FFI API
  - partial hypotheses callbacks
  - decoder state reuse
- [ ] Write a spike plan with interface proposal, expected risks, and rollback path.
- [ ] Explicitly compare complexity vs expected win before implementation.

---

## Suggested implementation grouping

### PR / change set 1
- [ ] Phase 0
- [ ] Phase 1

### PR / change set 2
- [ ] Phase 2

### PR / change set 3
- [ ] Phase 3
- [ ] Phase 4

### PR / change set 4
- [ ] Phase 5 summary
- [ ] optional Phase 6 decision record

---

## Manual benchmark script
- [ ] Cold launch, wait for ready, record 3 short utterances, record timings.
- [ ] Warm app, record 10 short utterances back-to-back, record p50/p95.
- [ ] Repeat with one long utterance (~10s) to confirm no regressions.
- [ ] Specifically note clipped starts / clipped endings before and after Phases 2-4.

## Ship criteria
- [ ] First-use latency no longer has a warmup race.
- [ ] Repeated utterance start latency improves materially.
- [ ] Clipped starts/endings are reduced.
- [ ] No regressions in empty-result handling, paste, or teardown.
- [ ] Follow-up work in Phase 6 is justified by measured remaining pain, not guesswork.
