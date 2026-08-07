# Megaphone-Inspired Speakeasy Roadmap

## Status

- Date: 2026-08-06
- Status: proposed; no application implementation has been approved
- Speakeasy baseline: `dd4d5d0`
- Megaphone baseline: `5a9136b3ac8c766e24a5d79ac056df4d427968f1`
- Detailed source comparison: `docs/research/megaphone-comparison.md`
- Goal: add useful local features without weakening Speakeasy's simple, low-latency dictation path

## Product shape

Speakeasy should remain a small menu-bar dictation tool with one authoritative path:

```text
hotkey
  -> already-prepared capture
  -> selected local transcription backend
  -> deterministic correction
  -> durable local record and stats update
  -> paste/copy delivery
```

Optional work must be bounded, cancellable where possible, and outside the audio callback. Disk writes remain asynchronous. No feature may add a mandatory language-model cleanup call after transcription.

## What to preserve

These are Speakeasy's performance advantages and should remain architectural constraints:

- Prepared `AVAudioEngine`, pre-roll, and adaptive stop grace (`Sources/AudioCapture.swift`).
- Explicit `idle -> startingCapture -> recording -> transcribing(token) -> idle` state machine (`Sources/AppCoordinator.swift:39-50`, `331-402`).
- Retained GGUF/transcribe.cpp session and borrowed PCM at the Rust boundary (`Sources/TranscribeCppTranscriber.swift:67-87`, `rust/asr_bridge/src/lib.rs:123-177`).
- Serial off-main transcription work (`Sources/AppCoordinator.swift:477-583`).
- Lazy menu construction (`Sources/MenuBarController.swift:76-147`).
- Bounded local history with utility-queue atomic writes (`Sources/TranscriptStore.swift:10-73`).
- Numeric latency trace instead of subjective performance claims (`Sources/TranscriptionTrace.swift`).

Do not copy Megaphone's central 3,755-line state owner, cold capture graph, repeated audio conversions, synchronous Core Data setup, default audio retention, or mandatory semantic cleanup.

## Confirmed asset diagnosis

The ICNS pipeline is functioning. `CFBundleIconFile = speakeasy` is valid, `iconutil` produces the expected 10 representations, the built and installed bundles contain the same ICNS, and both signatures verify.

The visible failure has three causes:

1. **The artwork is optically too small.** The foreground is only roughly 4x5 pixels at 16x16 and 12x13 pixels at 32x32, so the icon reads as blank.
2. **The menu icon is unrelated to the ICNS.** `MenuBarController` always uses the SF Symbol `waveform` (`Sources/MenuBarController.swift:29-36`). Changing `Assets/` cannot change that glyph.
3. **The build exposes an incomplete final bundle path.** `build.sh:38-64` creates `build/Speakeasy.app` before installing its plist/resources and signing it, which leaves stale LaunchServices registration state.

The four noncanonical files in `Assets/speakeasy.iconset` (`64`, `64@2x`, `1024`, `1024@2x`) are ignored by `iconutil`. That is cleanup, not the visible failure.

## Work tracks

### Track A — Identity and delivery foundation

#### A1. Fix icon source and bundle assembly

Changes:

- Create one durable master icon source.
- Redraw optical 16x16 and 32x32 representations with a much larger, simpler mark and stronger contrast.
- Generate only the 10 canonical iconset files.
- Decide separately whether to keep the SF Symbol menu glyph or add a dedicated monochrome template asset.
- Build the app in a hidden staging directory and rename it to `build/Speakeasy.app` only after resources, plist, dylib, and signatures are complete.
- Increment `CFBundleVersion` for installed artifacts.
- Unregister the stale build-tree bundle once, then register only the completed app.

Acceptance:

- The mark is recognizable at 16x16 and 32x32 in light and dark surfaces.
- `iconutil` round-trips exactly 10 canonical representations.
- The generated, bundled, and installed ICNS hashes match.
- LaunchServices has no incomplete or launch-disabled registration for the final build path.
- The installed icon is visible in Finder and Privacy & Security.

Approval needed before implementation: select the visual mark and decide whether the menu glyph should match it.

#### A2. Make output durable before paste

Current gap: accessibility is checked before the successful transcript is retained (`Sources/AppCoordinator.swift:600-620`), pasteboard success is ignored (`Sources/PasteboardPaster.swift:14-17`), and the trace records `pasted` before delivery is attempted (`Sources/AppCoordinator.swift:607-620`).

Changes:

- Retain a successful transcript before Accessibility/Cmd-V delivery.
- Change `Pasting` to return a typed delivery result: pasteboard write failed, clipboard updated, events posted.
- Record success only after the known delivery boundary.
- Add `Copy Last Transcript`, `Paste Again`, and `Open Accessibility Settings` actions.
- Keep automatic paste behavior unchanged when permission and event creation succeed.

Acceptance:

- A valid transcript survives Accessibility denial or Cmd-V construction failure.
- Pasteboard write failure cannot be logged as pasted.
- Recovery actions work without retranscription.
- No synchronous disk write is added to release-to-paste.

#### A3. Make startup and model switching truthful

Current gaps:

- `AppDelegate` waits for model resolution/construction before creating the menu bar, so first launch or download can look like no app launched (`Sources/AppDelegate.swift:29-49`, `Sources/AppCoordinator.swift:274-320`).
- A replacement model is swapped and persisted before its warmup completes (`Sources/AppCoordinator.swift:665-678`), despite the intended last-known-good contract.
- Existing GGUF files on the fast path are accepted by exact byte count without rechecking SHA-256 (`Sources/ModelPathResolver.swift:275-280`); installation does verify the hash (`Sources/ASRModelInstaller.swift:58-119`).

Changes:

- Create the status item and hotkey shell before model download/load.
- Expose checking, downloading, loading, warming, ready, and failed states.
- Keep the previous backend selected until replacement load **and warmup** succeed; persist only after that point.
- Centralize verified-artifact validation so every GGUF load uses the same size/hash contract.

Acceptance:

- The menu bar appears within 100 ms even when model work is blocked.
- Hotkey input during setup returns visible readiness feedback.
- Failed replacement warmup leaves the prior backend selected and usable.
- A same-sized corrupt GGUF is rejected before native load.

### Track B — Simple local intelligence

#### B1. Add deterministic exact corrections first

Data:

```swift
struct PersonalDictionaryDocument: Codable, Sendable {
    let schemaVersion: Int
    var terms: [DictionaryTerm]
    var corrections: [TranscriptCorrection]
}

struct TranscriptCorrection: Codable, Identifiable, Sendable {
    let id: UUID
    var heard: String
    var written: String
    var isEnabled: Bool
}
```

Initial limits:

- At most 128 corrections.
- At most 128 Unicode characters on each side.
- Case- and diacritic-insensitive duplicate detection.
- Whole-word/whole-phrase boundaries.
- Longest phrase wins.
- Replacement output is not recursively reprocessed.

Mechanism:

- Persist a versioned JSON document under Application Support on a utility queue.
- Compile one immutable matcher when settings change, not once per dictation.
- Run it after raw ASR succeeds and hallucination filtering accepts the utterance, before history and paste.
- Preserve raw and corrected strings as separate values internally.

Performance gate:

- Correction p95 below 5 ms at the maximum supported mapping count.
- No disk I/O or regex construction per dictation.
- No measurable release-to-paste p95 regression.

This transfers Megaphone's best dictionary mechanism without copying its per-call regex construction or automatic learning.

#### B2. Add bounded local statistics

Use existing `TranscriptionTrace` values rather than Megaphone's human-readable status strings.

Persist no dictated text in stats. Track:

- total attempts and successful deliveries;
- no speech, too short, interrupted, failed, timeout, and Accessibility-denied outcomes;
- model/backend;
- capture-start, release-to-text, and release-to-paste timing samples;
- recent word and character totals only if derived from final local records.

Storage shape:

- Lifetime counters.
- Fixed per-backend counters.
- A bounded ring of 256 recent numeric latency samples.
- `schemaVersion = 1` in `stats.json`.
- Asynchronous atomic persistence.

Computation:

- O(1) update when a terminal trace is accepted.
- Percentiles calculated only when the stats view opens, over the bounded ring.
- Replace or bypass the current unbounded debug arrays and sort-on-every-record path (`Sources/TranscriptionTrace.swift:162-205`).

Initial UI:

- One small on-demand Stats panel or submenu.
- Today/Recent and Lifetime sections.
- Dictations, words, success rate, and release-to-text p50/p95.
- No charts or background analytics service in the first slice.

#### B3. Evolve history only when raw/final recovery needs it

Migrate `[String]` to a versioned 50-record envelope:

```swift
struct TranscriptRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let rawText: String
    let finalText: String
    let backend: String
    let outcome: Outcome
    let timings: Timings?
}
```

Migration order:

1. Decode the new envelope.
2. Otherwise decode the current `[String]`.
3. Wrap each old string without inventing historical timing data.
4. Preserve the newest 50.
5. Preserve the existing `com.wisp.app` fallback.
6. Write the migrated format asynchronously.

Do not adopt Core Data or retain audio by default.

#### B4. Add a small dictionary panel

- Open only when selected from the existing lazy menu.
- Add/remove/enable exact corrections.
- Add/remove manual vocabulary terms.
- Keep terms separate from corrections even before every backend can consume recognition hints.
- Later add “Create correction from last raw/final transcript.”

Automatic learning is deferred. Terms should be learned only from explicit user corrections or acceptance, never merely from ASR output.

### Track C — Parakeet benchmark and optimization loop

The active engine strategy is Parakeet through transcribe.cpp. Build the standalone harness described in [`plans/2026-08-06-parakeet-performance-harness.md`](2026-08-06-parakeet-performance-harness.md) before changing production defaults.

#### C1. Capture a production-parity baseline

- Run the exact locked transcribe.cpp version in an isolated worker process.
- Benchmark a versioned, hashed corpus of short, medium, long, and no-speech fixtures.
- Measure cold start, retained-session inference, real-time factor, native stage timings, first hypothesis/commit, peak RSS, errors, and WER.
- Record host, build, model, corpus, backend, and configuration fingerprints with every result.

#### C2. Sweep safe native controls

Test one controlled change at a time: timestamps, thread count, KV type, context size, backend/device selection, and speculative drafts. Promote a setting only when comparable release runs show a material latency win without quality, stability, or memory regression.

#### C3. Benchmark Parakeet streaming separately

Use transcribe.cpp's Parakeet streaming API to test accelerated replay and real-time pacing, including commit policy, stable-prefix agreement, attention context, and buffered left/chunk/right windows. Streaming remains an experimental harness capability until it beats batch release-to-final latency, preserves WER, resets cleanly, and stays within the memory budget.

#### C4. Promote only measured winners

Keep benchmark configuration explicit and reviewable. A production change must cite its result artifact and retain an easy fallback. Future local speech models may enter through another harness adapter only after a concrete transcribe.cpp-compatible artifact, license, and reproducible configuration are available.

## Cross-cutting performance gates

Every slice must preserve these gates:

- Process start to visible status item: p95 under 100 ms, independent of model download/load.
- Hotkey to visible recording feedback: p95 under 25 ms.
- Hotkey to capture-ready after preparation: p95 under 10 ms.
- Audio callback steady state: zero heap allocations and no synchronous optional work.
- Stop grace: existing 40-200 ms adaptive range, no more than 220 ms with padding.
- History: at most 50 records; all persistence asynchronous.
- Stats: at most 256 recent latency samples; no transcript text.
- Dictionary: hard count/size caps; compiled only on settings changes.
- Failed backend load/warmup: previous backend remains selected and usable.
- After 1,000 short dictations: no unbounded stats/history growth; RSS returns to within 5% of post-warmup baseline.
- Streaming candidate: materially better release-to-final p95 than the batch baseline, WER within the agreed tolerance, peak RSS within budget, no duplicate delivery, and clean reset/cancel behavior.

## Recommended order

1. **A1 — Icon and staged bundle assembly.** Independent, visible fix.
2. **A2 — Durable output and truthful paste result.** Correctness foundation for history/stats.
3. **A3 — Immediate shell and last-known-good model switching.** Make startup and backend state truthful.
4. **B1 — Deterministic exact corrections.** Highest-value feature with negligible expected cost.
5. **B2 — Bounded local stats.** Reuse existing traces; expose actual performance.
6. **B3/B4 — Structured history and small dictionary UI.** Add only the data/UI needed for recovery and editing.
7. **C1 — Standalone Parakeet harness and production-parity baseline.** Establish trustworthy comparison before tuning.
8. **C2 — Native option sweeps.** Test timestamps, sessions, backend, and speculative decoding one factor at a time.
9. **C3/C4 — Parakeet streaming and production promotion.** Integrate only measured winners with an easy fallback.
10. **Later:** conservative learning, paragraphing, hold-to-talk, clipboard preservation, or optional semantic cleanup as separate slices.

## Explicit deferrals

- Apple SpeechAnalyzer and DictationTranscriber integration.
- Replacing Parakeet/GGUF as the default before local comparison data exists.
- Prewiring Cohere or another model before a concrete compatible artifact and license exist.
- Dropping macOS 12-25 support.
- Mandatory Foundation Models cleanup.
- Automatic dictionary learning from ASR output.
- Core Data or unbounded run logs.
- Default audio retention.
- Commands, wake phrases, screen context, macros, and updater work bundled into this roadmap.
- Production streaming changes before the standalone Parakeet harness establishes a batch baseline.

## User approval gates

1. Choose a new app icon direction and whether the menu-bar glyph should match it.
2. Approve A2/B1 as the first product code slice or choose a different order.
3. Approve the harness-first Parakeet baseline and identify the primary target Mac and representative fixture corpus.
4. Approve production streaming only after its benchmark thresholds pass.
5. Decide stats retention semantics: lifetime totals plus 256 recent samples (recommended), or resettable recent-only stats.
