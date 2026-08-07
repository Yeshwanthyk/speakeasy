# Speakeasy improvement synthesis

**Date:** 2026-08-06
**Branch:** `perf/parakeet-benchmark-harness`

## Executive conclusion

Speakeasy's retained Parakeet model is already very fast on this M4 Pro once loaded. The directional synthetic run measured a stable batch baseline near 48 ms p50 and 98 ms p95, with the encoder responsible for most native inference time. None of the tested native settings cleared the promotion threshold. Current streaming also failed the quality and latency gates.

The best next work is therefore not to change production inference defaults. It is to:

1. harden the benchmark so it fails closed and supports paired evidence;
2. measure and finish the capture-buffer ownership design;
3. make startup immediate and transcript delivery durable;
4. add exact corrections, bounded stats, and structured history;
5. evaluate smaller Parakeet quantizations and upstream graph reuse;
6. revisit live streaming only with a real speech corpus and an end-to-end capture prototype.

## Evidence collected

A local ignored corpus was synthesized with the macOS Samantha voice: two short, two medium, and one long 16 kHz mono fixture. Each configuration ran 25 samples against the installed Parakeet Unified Q8 model. These results are directional only: TTS is not representative of spontaneous speech, accents, microphone noise, prosody, or conversational corrections; the host also had unrelated background load. Result artifacts are under the ignored directory `benchmarks/results/synthesis-2026-08-06/`.

Stable comparison baseline (`baseline-b`):

- 47.73 ms wall p50;
- 98.13 ms wall p95;
- 9.26% synthetic micro-WER;
- 914.2 MiB sampled peak RSS;
- native medians: 0.25 ms mel, 41.37 ms encode, 4.71 ms decode;
- actual backend/device: Metal (`MTL0`) on Apple M4 Pro.

The first baseline had a 240.29 ms p95 and 432.55 ms model-load timing, while the second baseline had a 98.13 ms p95 and 259.21 ms model-load timing. That drift proves first-use/cache state and paired ordering must be handled before promotion decisions.

| Candidate | p50 vs stable baseline | p95 vs stable baseline | WER | Verdict |
|---|---:|---:|---:|---|
| Timestamps none | +13.2% | +17.5% | unchanged | Do not promote |
| Threads 4 | -1.3% | -0.4% | unchanged | Below meaningful-win threshold |
| Threads 8 | -0.2% | -3.9% | unchanged | Below meaningful-win threshold |
| KV F16 | +0.7% | -3.1% | unchanged | Effectively current AUTO behavior |
| Context 512 | +3.9% | +7.3% | unchanged | Parakeet no-op/no benefit |
| Explicit Metal | +35.9% | +30.7% | unchanged | Failed regression gates; AUTO already chose Metal |
| Speculative drafts 4 | n/a | n/a | n/a | Correctly rejected as unsupported |
| Streaming accelerated | total compute worse; 82.60 ms finalize p95 | 15.8% finalize improvement | 11.11% | Failed latency and WER gates |
| Streaming real time | 150.46 ms finalize p95 | worse than batch | 11.11% | Failed latency and WER gates |
| Explicit buffered stream, 1040 ms feed | 81.59 ms finalize p95 | 16.8% finalize improvement | 11.11% | Failed meaningful-win and WER gates |

Streaming's synthetic WER regressed by 1.85 percentage points. Real-time first hypothesis/commit occurred around 2.18 seconds p50, and release-to-final p95 was 150 ms. Production streaming should not ship from this evidence.

## Priority 0 — Make benchmark conclusions trustworthy

The current harness is useful for directional experiments but can still accept incomplete evidence.

1. **Validate result semantics, not only JSON syntax.** Require exactly one start/end per run, matching IDs, a successful terminal status, unique fixture/repetition keys, expected sample counts, and complete metrics. Current parsing only deserializes lines (`benchmarks/speech-bench/src/runner.rs`).
2. **Hash the executable and all source/input contents.** The dirty fingerprint hashes tracked diffs and untracked names, not untracked contents (`environment.rs`). This matters while the new harness itself is untracked.
3. **Record production build parity.** Production sets `TRANSCRIBE_CMAKE_ARGS=-DGGML_NATIVE=OFF` (`build.sh`); the benchmark script does not. Record CMake flags, binary hash, Rust version, and transcribe native commit/header.
4. **Fail closed on WER coverage.** Require the manifest normalization to equal the scorer version, non-empty references for scored fixtures, a minimum scored-fixture count, and coverage in reports (`fixtures.rs`, `score.rs`).
5. **Add paired A/B blocks.** Alternate baseline/candidate by fixture, report per-fixture deltas, variance/confidence intervals, and short/medium/long buckets. Nearest-rank p95 over mixed fixtures is insufficient for close settings (`metrics.rs`).
6. **Capture system state.** Record AC/battery, Low Power Mode, thermal state, and meaningful background load. The first/second baseline drift demonstrates the need.
7. **Improve memory evidence.** Polling `ps` every 20 ms can miss peaks and excludes Metal/unified-memory behavior (`runner.rs`). Add a native high-watermark and record sampling failure explicitly.
8. **Aggregate native stages.** Native timings are in sample records but omitted from standard reports. Encoder time is currently the dominant optimization target.
9. **Trigger parity CI on production code.** Include `rust/asr_bridge/src/lib.rs`, model selection, transcriber, and build flags—not only Cargo manifests and locks (`.github/workflows/benchmark-harness.yml`).
10. **Separate startup labels.** Distinguish process spawn, fixture/config validation, model hashing, backend initialization, model load, session creation, warmup, and first inference. Current “process-cold model load” is only one part.

## Priority 1 — Finish the fast, reliable app pipeline

### Capture buffer ownership

The current branch fixes repeated buffer-capacity loss: front/back capacity remains available across recordings and the regression test now passes (`AudioCapture.swift`, `AudioCaptureTests.swift`). The trade-off is a complete recording copy under `frontLock` at stop. For long recordings, peak memory includes the retained front capacity plus the returned copy.

Next steps:

- measure 1 s, 5 s, 35 s, and maximum-length recordings with Allocations and Time Profiler;
- record begin, callback p50/p95/p99, flush, stop-copy, and peak RSS separately;
- if the stop copy is material, replace it with an explicit pooled/leased PCM ownership type that returns storage after synchronous transcription;
- enforce the recording cap before append so the result cannot exceed the declared maximum;
- retain the current design if the copy is sub-millisecond for normal dictations and callback allocation stability is better.

### Callback path

The callback currently passes through conversion locking, ring-buffer locking/copying, state/stop-timing locking, back-buffer append, and occasional back-to-front flush (`AudioCapture.swift`, `FloatRingBuffer.swift`). Do not restructure it speculatively. Add signposts or counters and change it only if callback p99 approaches 5 ms, allocations occur after warmup, or lock waits are visible.

### Remove avoidable post-stop work

- Measure the full-recording RMS scan in `AppCoordinator.swift`; maintain incremental energy during capture only if it is material on long recordings.
- Record `stopReturnedAt` before the main-queue round trip, then measure main-queue delay separately.
- Avoid changing adaptive stop grace until traces show it materially dominates release-to-text and tail audio remains intact.

### Ducking

Voice-processing/advanced ducking is configured once during `AudioCapture` initialization. Treat it as a benchmark variable because it can affect startup, callback cadence, input format, audio quality, and ASR accuracy. Verify active playback, route changes, sleep/wake, graph recovery, and restoration of other-audio volume. Reapply after graph rebuild only if real testing proves configuration is lost.

## Priority 2 — Improve perceived speed and correctness

### Immediate shell and truthful model lifecycle

`AppDelegate` currently waits for model resolution/construction, capture preparation, coordinator setup, and synchronous history loading before creating the menu-bar shell. Create the status item immediately and show `checking`, `downloading`, `loading`, `warming`, `ready`, and `failed` states.

Model switching should load and warm a candidate off-main, then atomically swap and persist only after success. Preserve the last-known-good model on failure. Avoid synchronously hashing the ~700 MB model on every launch; retain verified metadata or validate off-main.

### Durable transcripts and truthful paste

Store accepted text before Accessibility/paste checks. `PasteboardPaster` currently ignores pasteboard write success, and the trace marks paste before delivery (`PasteboardPaster.swift`, `AppCoordinator.swift`). Return typed outcomes such as clipboard failure, event creation failure, events posted, and permission denied. Add `Copy Last Transcript` and `Paste Again` without adding synchronous disk I/O to release-to-paste.

### Cancellation and recovery

A coordinator timeout does not cancel native `session.run`; the Rust mutex remains occupied until the call returns (`AppCoordinator.swift`, `rust/asr_bridge/src/lib.rs`). Add transcribe.cpp cancellation support or isolate production inference in a recoverable worker process before treating timeout as full recovery.

## Priority 3 — Engine work worth pursuing

1. **Smaller Parakeet quantizations/variants.** Q8 is roughly 700 MB. Compare Q6/Q5 or another supported Parakeet artifact on the real corpus. Require a meaningful latency/RSS gain and quality within gates. Extend comparison identity with an explicit allowed model candidate rather than weakening normal comparisons.
2. **Upstream graph/context reuse.** Parakeet recreates compute graph/context state on offline runs in transcribe.cpp 0.1.3. Reuse could help short utterances where encoder setup dominates, but belongs upstream and needs strong correctness proof.
3. **Text-only result path.** Timestamps-none did not help in the directional run. A deeper text-only API that avoids constructing/materializing segment/word/token results may still reduce binding overhead, but encoder time—not result materialization—is dominant.
4. **Thread count.** Threads 4/8 were essentially tied with AUTO. Do not hard-code either without repeated paired real-corpus evidence.
5. **Metal.** AUTO already selected Metal. Keep actual backend/device telemetry and fallback truth; do not force Metal from the current result.
6. **Streaming.** Revisit only after real-corpus testing and an end-to-end prototype that overlaps capture. Engine-only streaming did not pass current gates, and app integration adds queueing, cancellation, fallback, and duplicate-delivery risk.
7. **Future models.** Add Cohere or another engine only when a concrete local artifact, license, and transcribe.cpp-compatible adapter exist. Use the same corpus and gates.

Remove or reclassify current no-op/invalid sweeps for this model: context 512, KV F16 versus AUTO, speculative decoding, cache-aware extension for the Unified buffered model, and stable-prefix agreement where the family implementation does not use it meaningfully.

## Priority 4 — High-value product improvements that preserve speed

1. **Exact correction dictionary.** Bounded `heard → written` whole-word/phrase mappings, longest match wins, non-recursive, matcher compiled only when settings change. Apply after hallucination filtering and before history/paste. This adds no model call.
2. **Structured history.** Migrate the existing 50-string store to a versioned 50-record envelope with timestamp, raw/final text, model, outcome, and numeric timings. Keep persistence asynchronous and do not retain audio by default.
3. **Bounded stats.** Replace unbounded debug timing arrays and per-result sorting in `TranscriptionTrace.swift` with lifetime counters plus at most 256 recent numeric samples. Compute p50/p95 only when the stats view opens.
4. **Recovery UI.** Add readiness/error status, Copy Last Transcript, Paste Again, and distinct messages for microphone recovery, no speech, transcription failure, Accessibility denial, and paste failure.
5. **Manual vocabulary.** Keep vocabulary separate from deterministic corrections. Connect it to recognition only after the selected backend proves a supported hint mechanism and no latency regression.
6. **Assets and bundle assembly.** Redraw optical 16/32 px app icons; the current foreground is too small. Decide separately whether to replace the menu-bar `waveform` SF Symbol. Stage and sign the complete bundle before atomically exposing it, and increment bundle versions to avoid stale LaunchServices caching.

## Explicit deferrals

- Production streaming from the current synthetic result.
- Hard-coding threads, timestamps-none, F16 KV, context 512, or explicit Metal.
- Speculative decoding on the current Parakeet model.
- Mandatory semantic/LLM cleanup.
- Automatic dictionary learning from ASR output.
- Default audio retention, Core Data, or unbounded logs.
- Commands, wake phrases, macros, screen context, or a broad settings surface.

## Recommended implementation order

1. Harness fail-closed validation, source/build fingerprints, WER coverage, and paired/bucket reporting.
2. Instruments proof for current capture buffer change; keep or replace the stop-copy design based on evidence.
3. Durable transcript plus typed paste outcome and recovery actions.
4. Immediate menu shell and last-known-good model lifecycle.
5. Exact correction dictionary.
6. Bounded stats and structured history.
7. Real 50-fixture corpus and paired release baseline.
8. Smaller Parakeet quantization/variant comparison.
9. End-to-end streaming prototype only if later engine evidence passes.
10. Icon/build staging polish as an independent slice.
