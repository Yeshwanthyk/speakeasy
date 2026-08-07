# Parakeet Performance Harness and Optimization Plan

## Orientation

Speakeasy will stay on Parakeet/transcribe.cpp. The next performance work should not begin by changing production defaults. It should begin by building a repeatable harness that can answer three questions independently:

1. **How fast and accurate is the speech engine itself?**
2. **How much latency does Speakeasy add around the engine?**
3. **Does a candidate remain better across repeated runs, model variants, machines, and future changes?**

The harness will live outside the production bridge. It will run each engine configuration in an isolated process, replay the same versioned audio fixtures, record native and end-to-end timings, score accuracy, fingerprint the complete environment, and compare only compatible runs. Production changes are promoted one at a time only after the harness shows a material win without an agreed quality, memory, or reliability regression.

The largest promising Parakeet opportunities are:

- remove capture-path allocations and callback contention;
- expose and measure native session/run options instead of assuming defaults are optimal;
- avoid unused timestamp/alignment work if the model performs it;
- evaluate Parakeet streaming so inference can overlap speech;
- compare Parakeet variants and quantizations on the same local corpus;
- change stop grace, queueing, or copies only when stage timings prove they matter.

## Settled decisions

- Apple SpeechAnalyzer is no longer active scope.
- GGUF/transcribe.cpp remains the production runtime.
- Parakeet Unified remains the baseline; other Parakeet variants and future transcribe.cpp-compatible models are candidates, not defaults.
- Benchmark dependencies and knobs will not be added to `rust/asr_bridge` or the shipped app bundle.
- The harness will pin the same transcribe.cpp version as production and record both lockfile hashes.
- The first baseline exactly reproduces current production defaults before any sweep begins.
- Batch latency and streaming latency are different modes and will be reported separately.
- Performance results are comparable only under matching model, corpus, host, backend/device, build, and configuration fingerprints.
- Transcript text is omitted from normal result files by default; hashes and scores are retained.
- Private recordings remain outside Git. Fixtures committed to the repository must have explicit provenance and compatible licenses.

## Scope

### Included

- Batch and Parakeet streaming engine benchmarks.
- Model/backend/session/run/stream option sweeps.
- Cold-process and retained-session warm runs.
- Native stage timings, wall latency, WER, memory, failures, and environment metadata.
- Quick, development, release, and targeted-sweep presets.
- Baseline comparison and regression gates.
- A later app-pipeline replay layer and live capture profiling procedure.

### Excluded initially

- Apple speech APIs.
- Cloud transcription.
- Concurrent throughput optimization; Speakeasy handles one dictation at a time.
- Automatic model downloads from the benchmark tool.
- Privileged OS page-cache eviction presented as “cold start.”
- Automatic model promotion based on one aggregate score.
- Semantic cleanup or LLM benchmarks.

## Current baseline and blind spots

Production currently fixes all native controls to defaults:

- `Model::load(...)` selects default `ModelOptions` (`rust/asr_bridge/src/lib.rs:104`).
- `model.session()` selects default `SessionOptions` (`rust/asr_bridge/src/lib.rs:108`).
- `session.run(..., &RunOptions::default())` selects default run behavior (`rust/asr_bridge/src/lib.rs:174`).
- Swift receives only text/error through the C ABI (`Sources/TranscribeCppTranscriber.swift:4-31`, `73-89`).

Consequences:

- requested and actual backend/device are not reported;
- model capabilities and effective session limits are hidden;
- native `load`, mel, encode, and decode timings are discarded;
- threads, KV precision, context size, timestamps, PNC, ITN, language, and speculative decode cannot be compared;
- the production bridge exposes no streaming lifecycle;
- the ignored real-model Rust test only loads a model and transcribes silence (`rust/asr_bridge/src/lib.rs:282-312`);
- `TranscriptionTrace` measures app stages but has no fixture corpus, WER, native timings, memory, or durable report (`Sources/TranscriptionTrace.swift`).

The capture path also has known measurable costs:

- `beginRecording()` reserves capacity for the six-minute maximum after each ownership swap, roughly 22 MiB (`Sources/AudioCapture.swift:336-350`, `410-420`).
- `flushBackBuffer()` swaps in a zero-capacity buffer, allowing later callback allocations (`Sources/AudioCapture.swift:474-490`).
- each callback passes through conversion plus state, timing, ring, and back-buffer synchronization (`Sources/AudioCapture.swift:493-646`).
- stop waits for adaptive grace plus 20 ms timeout padding (`Sources/AudioCapture.swift:390-408`).
- the full utterance is scanned once for RMS before inference and crosses a main-queue round trip before transcription is enqueued (`Sources/AppCoordinator.swift:477-554`).

These are hypotheses until the harness and Instruments establish their contribution.

## Target benchmark flow

```text
speech-bench driver
  -> validate corpus/config
  -> fingerprint repo, host, build, model, and corpus
  -> expand a bounded matrix
  -> launch one worker process at a time
       -> initialize transcribe.cpp
       -> load one model with typed ModelOptions
       -> probe actual backend/device/capabilities
       -> create one session with typed SessionOptions
       -> warm if requested
       -> replay batch or streaming fixtures serially
       -> emit strict JSONL samples
       -> exit
  -> score/aggregate
  -> compare with a compatible baseline
  -> write JSON + Markdown summary
```

A worker process is the isolation boundary because model loading is part of the cold measurement, Metal must be initialized after process launch, and transcribe.cpp 0.1.x permits only one active run/batch/stream per loaded model.

## Repository shape

Create a standalone package:

```text
benchmarks/
  README.md
  .gitignore
  configs/
    production-parity.json
    quick.json
    release.json
  fixtures/
    manifest.example.json
    README.md
  baselines/
    README.md
  results/                       # ignored
  speech-bench/
    Cargo.toml
    Cargo.lock
    src/
      main.rs                    # driver CLI
      bin/speech-bench-worker.rs
      config.rs
      environment.rs
      fixtures.rs
      protocol.rs
      metrics.rs
      score.rs
      report.rs
      engine/
        mod.rs
        transcribe_cpp_013.rs
script/
  benchmark.sh
```

The package depends on exact `transcribe-cpp = 0.1.3`, with Metal enabled, and owns its own target directory. It does not link into `Speakeasy.app` and does not change `rust/asr_bridge`.

Add a mechanical check that production and benchmark packages resolve the same transcribe.cpp version. Exact model, lockfile, build flag, and runtime identities are still recorded because matching version numbers alone are insufficient.

## Fixture corpus

Version the manifest independently from the audio location:

```json
{
  "schema": "speakeasy.fixtures.v1",
  "corpus_id": "speakeasy-en-v1",
  "normalization_version": "wer-en-v1",
  "fixtures": [
    {
      "id": "medium-001",
      "audio": "audio/medium-001.wav",
      "audio_sha256": "...",
      "reference": "Schedule the design review for Thursday.",
      "sample_rate_hz": 16000,
      "channels": 1,
      "frames": 74240,
      "duration_ms": 4640,
      "bucket": "medium",
      "locale": "en-US",
      "conditions": ["clean"],
      "tags": ["calendar", "punctuation"]
    }
  ]
}
```

Initial release corpus:

- 20 short utterances, approximately 0.5–2 seconds;
- 20 medium utterances, approximately 2–8 seconds;
- 10 long utterances, approximately 8–35 seconds;
- separate silence/noise/malformed controls excluded from WER totals;
- proper names, technical terms, commands, numbers, punctuation, quiet speech, leading/trailing silence, accents, and realistic background noise;
- trailing plosive/fricative cases for later stop-grace validation.

All engine comparisons use the identical decoded 16 kHz mono Float32 PCM. Fixture order is deterministic from a recorded seed.

## Typed configuration surface

The harness exposes requested values and reports effective values. Unsupported combinations fail or skip explicitly; they never silently collapse to defaults.

### Model options

- backend: `auto`, `cpu`, `cpu_accel`, `metal`;
- GPU device index;
- model path, size, SHA-256;
- architecture, variant, capabilities;
- actual backend and device.

Vulkan/CUDA remain schema values for portability but are rejected by the current macOS Metal build when unavailable.

### Session options

- CPU threads: `0` for upstream default, then bounded candidate values;
- KV precision: `auto`, `f16`, `f32`;
- decoder context cap: `0` for model maximum or a positive candidate.

Always report effective context, effective maximum audio, and estimated maximum KV bytes.

### Run options

- task: transcribe only in the initial Parakeet matrix;
- timestamps: production `auto` versus candidate `none` first;
- PNC: `default`, then supported on/off experiments;
- ITN: `default`, then supported on/off experiments;
- language hint when supported;
- special-tag retention;
- speculative draft count: family default `-1`, disabled `0`, then bounded supported values.

Translation and target-language matrices are separate quality projects, not part of the English latency baseline.

### Stream options

- commit policy: `auto`, `on_finalize`, `stable_prefix`;
- stable-prefix agreement count;
- feed chunk size;
- accelerated versus real-time pacing;
- Parakeet cache-aware `att_context_right`;
- Parakeet buffered `left_ms`, `chunk_ms`, and `right_ms` when the model accepts that extension.

All family-specific controls are capability/extension-probed before execution.

## Benchmark modes

### Process-cold

For every trial:

1. start a fresh worker;
2. initialize backends;
3. load the model;
4. create a session;
5. run one fixture;
6. exit.

Report process spawn, backend initialization, model load, session creation, first run, and native load timing separately. Call this **process-cold**, not disk-cold; the OS page cache is not forcibly cleared.

### Warm retained session

1. start a fresh worker;
2. load one model and create one session;
3. perform Speakeasy's one-second silent warmup;
4. discard but record warmup metrics;
5. run fixtures serially on the retained session;
6. keep first measured run separate from steady-state summaries.

Presets:

- `quick`: 5 representative fixtures × 5 repetitions;
- `dev`: full corpus × 10 repetitions;
- `release`: full corpus × 30 repetitions minimum, 50 preferred for meaningful p95;
- `sweep`: selected fixtures and exactly one bounded option family.

### Streaming

Run both:

- **accelerated replay**: feed chunks without sleeping to measure compute throughput;
- **real-time replay**: feed chunks at audio cadence to measure recording-time work, first hypothesis/commit, and release-to-final latency.

Batch inference and streaming release latency are reported side by side but never merged into one percentile.

## Metrics

Each sample records:

### Identity

- repository SHA and dirty-state hash;
- harness schema/version;
- production and benchmark Cargo lock hashes;
- transcribe.cpp compiled/runtime version, commit, and header hash;
- build features and `TRANSCRIBE_CMAKE_ARGS`;
- macOS/Darwin, hardware model, CPU count, memory, Xcode/SDK/Rust versions;
- power source, Low Power Mode, and thermal state when available;
- model name, bytes, SHA-256, architecture, variant, capabilities;
- requested and actual backend/device;
- every requested/effective option;
- corpus/manifest hashes, repetition count, order seed, pacing mode.

### Timing

- process spawn;
- backend initialization;
- model load;
- session creation;
- warmup;
- batch run wall time;
- stream begin, first changed result, first committed text, finalize;
- native `load_ms`, `mel_ms`, `encode_ms`, `decode_ms`;
- audio duration, real-time factor, and audio-seconds processed per wall-second.

### Memory and stability

- worker RSS baseline, post-load, post-warmup, post-run, and peak;
- session KV estimate;
- timeout, crash, signal, typed error, and truncated/aborted state;
- post-run RSS drift across repetitions.

### Accuracy

Implement deterministic local edit-distance scoring:

1. Unicode NFKC;
2. lowercase;
3. normalize apostrophes and whitespace;
4. remove punctuation for primary lexical WER;
5. tokenize on whitespace;
6. do not silently rewrite numbers or abbreviations.

Report substitutions, deletions, insertions, micro/corpus WER, macro fixture WER, bucket/condition WER, short-command exact match, and a secondary punctuation/case-sensitive score.

## Result protocol

Worker stdout is strict JSONL; native logs go to stderr. Use three records:

- `run_start`: full environment/config/model/corpus fingerprint;
- `sample`: one fixture iteration with timings, memory, score, text hash, stream metrics, and error;
- `run_end`: counts, aggregates, comparison status, and deltas.

Raw transcript text is included only with an explicit `--include-text` diagnostic option. Default results retain text hashes and WER operation counts.

## Comparable baselines and regression gates

A run is comparable only if these match:

- host fingerprint;
- model SHA-256;
- corpus manifest/audio hashes;
- harness schema and normalization version;
- actual backend/device;
- session/run/stream configuration;
- build features and lockfiles.

Otherwise report `incomparable` and never label the delta a regression.

Initial gates:

| Metric | Gate |
|---|---:|
| New crash, hang, load failure, or transcript truncation | zero |
| Warm p50 inference | no worse than max(5%, 10 ms) |
| Warm p95 inference | no worse than max(10%, 25 ms) |
| Process-cold model-load p50 | no worse than max(15%, 500 ms) |
| Peak RSS | no worse than 10% and 128 MiB |
| Corpus micro-WER | no worse than +0.5 percentage points |
| Any duration-bucket WER | no worse than +1.5 percentage points |
| Streaming finalization p95 | candidate must materially beat batch release-to-text |

For promoting an optimization, require a meaningful win rather than merely passing the regression gate:

- native option change: at least 10% p95 or 5% p50 improvement;
- quant/model change: at least 15% p95 improvement or 20% RSS reduction;
- streaming: at least 20% medium/long release-to-final p95 improvement or 50 ms on representative short utterances;
- capture-path change: zero callback allocations plus a measurable callback/start/stop improvement;
- no quality regression above the agreed gates.

Use repeated interleaved A/B order for close candidates. Do not promote based on one run or a different hardware fingerprint.

## Implementation chunks

### Chunk 1 — Package, protocol, and environment fingerprint

Behavior:

- Build standalone driver and worker executables.
- Validate configuration.
- Emit `run_start`/`run_end` JSONL.
- Capture repository, lockfile, toolchain, host, and model identity.

Files:

- `benchmarks/speech-bench/Cargo.toml`
- `benchmarks/speech-bench/src/main.rs`
- `benchmarks/speech-bench/src/bin/speech-bench-worker.rs`
- `config.rs`, `environment.rs`, `protocol.rs`
- `benchmarks/configs/production-parity.json`
- `script/benchmark.sh`

Verification:

- schema round-trip tests;
- unknown fields/options fail clearly;
- stdout remains valid JSONL when native logs are enabled;
- production `./build.sh` output is byte-identical apart from expected nondeterministic signing metadata and has no benchmark dependency.

Risk: environment fingerprints can become overstrict. Keep identity fields explicit and versioned.

### Chunk 2 — Fixtures, WAV validation, and WER scorer

Behavior:

- Load and validate canonical WAV fixtures.
- Verify manifest hashes and metadata.
- Score deterministic WER and bucket aggregates.

Files:

- `fixtures.rs`, `score.rs`
- `benchmarks/fixtures/manifest.example.json`
- `benchmarks/fixtures/README.md`

Verification:

- reject stereo/wrong-rate/malformed WAV;
- golden edit-distance cases for substitutions/deletions/insertions;
- Unicode, punctuation, apostrophe, numbers, and empty-reference cases;
- fixture hash mismatch fails before model load.

Risk: normalization can hide meaningful errors. Preserve both normalized and punctuation-sensitive scores.

### Chunk 3 — Production-parity transcribe.cpp adapter

Behavior:

- Load Parakeet with exact production defaults.
- Probe capabilities/backend/device/session limits.
- Run retained-session batch inference.
- Export native stage timings and result identity.

Files:

- `engine/mod.rs`
- `engine/transcribe_cpp_013.rs`
- `metrics.rs`

Verification:

- same model + fixture produces the same normalized text as the production bridge;
- requested/effective controls are recorded;
- unsupported options fail rather than default silently;
- timeout kills only the worker and leaves the driver usable.

Risk: direct transcribe.cpp use can drift from the bridge. The production-parity test and exact dependency pin are mandatory.

### Chunk 4 — Cold/warm runner, RSS sampling, presets, and report

Behavior:

- Run isolated process-cold trials.
- Reuse retained sessions for warm trials.
- Sample RSS externally.
- Produce JSON and Markdown summaries with p50/p95 and WER.

Files:

- driver orchestration in `main.rs`
- `metrics.rs`, `report.rs`
- `quick.json`, `release.json`
- `benchmarks/README.md`

Verification:

- killed/hung worker becomes a typed sample failure;
- first run remains separate from steady state;
- percentile tests use deterministic datasets;
- incomparable baselines cannot pass/fail a regression gate.

Risk: p95 is unstable with too few repetitions. Release mode uses at least 30, preferably 50.

### Chunk 5 — Typed option sweeps

Behavior:

- Add model/session/run configuration.
- Expand bounded one-factor matrices.
- Guard every option by capabilities.

First sweeps, in order:

1. timestamps `auto` versus `none`;
2. backend `auto` versus explicit Metal and CPU accelerators;
3. thread count around upstream default;
4. KV `auto/f16/f32`;
5. context cap only after real transcript lengths are known;
6. speculative draft default versus disabled, then supported bounded values;
7. PNC/ITN only with quality scoring.

Verification:

- matrix cardinality cap prevents accidental combinatorial runs;
- requested/effective config appears in every sample;
- candidate reports include per-bucket accuracy and latency.

Risk: interactions exist. Start one factor at a time, then test only winning interactions.

### Chunk 6 — Parakeet streaming benchmark

Behavior:

- Probe streaming capability and accepted extension kind.
- Replay accelerated and real-time chunks.
- Record first hypothesis, first commit, buffered audio, revisions, finalization, and final text.
- Compare final batch/stream text and WER.

Files:

- streaming support in `transcribe_cpp_013.rs`
- stream config/protocol/metrics additions

Verification:

- finalize/reset/cancel paths;
- no duplicate/missing audio across chunk boundaries;
- chunk-size and stable-prefix matrices are bounded;
- stream failure does not poison the next isolated worker;
- batch and stream use identical decoded PCM.

Risk: streaming holds the model's compute lease and changes production ownership. This chunk benchmarks only; production integration is a later decision.

### Chunk 7 — Baselines, comparison, and developer loop

Behavior:

- Save a named compatible baseline.
- Compare candidate to baseline.
- Print concise wins/regressions and machine-readable gate status.

Commands:

```sh
./script/benchmark.sh quick
./script/benchmark.sh release --save-baseline m4-pro-parakeet-unified-q8
./script/benchmark.sh sweep timestamps --baseline m4-pro-parakeet-unified-q8
./script/benchmark.sh compare results/candidate.jsonl --baseline m4-pro-parakeet-unified-q8
```

Verification:

- model/corpus/config/host mismatch reports `incomparable`;
- thresholds test both relative and absolute noise floors;
- report generation is deterministic from JSONL.

Risk: baselines become stale. Never auto-rebase; require an explicit reviewed baseline update.

### Chunk 8 — App correlation and capture profiling

Behavior:

- Correlate winning engine config with existing `TranscriptionTrace` stages.
- Add an opt-in fixture replay integration target for coordinator/post-processing timing.
- Document an Instruments Allocations/System Trace procedure for the real audio callback.

Initial proof:

- twenty short live recordings;
- zero steady-state callback allocations;
- callback p99 under 5 ms;
- capture-ready p95 under 10 ms;
- transcription-end to paste-request p95 under 10 ms;
- no first/end-frame loss across supported devices.

Do not change capture buffer ownership, locks, or stop grace until this profile identifies a material contribution.

## Optimization queue after the baseline

Run hypotheses in this order:

1. **Capture allocation stability:** stop six-minute capacity allocation and preserve reusable front/back capacities without changing sample ownership.
2. **Timestamp work:** test `timestamps = none` because Speakeasy consumes text only.
3. **Session options:** threads, KV type, and context cap.
4. **Backend selection:** confirm Auto actually binds the best Metal path on target hardware.
5. **Speculative decode:** only when capability-probed.
6. **Parakeet streaming:** likely largest release-to-text opportunity for medium/long speech.
7. **Parakeet quant/model variants:** compare Q8 against future compatible quantizations with explicit quality gates.
8. **RMS/queue path:** avoid the full-buffer scan or main-queue bounce only if stage timing exceeds 5 ms p95 or 5% of release-to-text.
9. **Stop grace:** tune only if it exceeds 10% of release-to-text and tail-sensitive fixtures remain perfect.
10. **Post-processing/history/paste:** optimize only if transcription-end to delivery exceeds 10 ms p95.

## CI and local split

### Normal CI

- build benchmark package;
- run schema/config/WAV/WER/report tests;
- verify benchmark and production transcribe.cpp versions match;
- run no-model capability/error tests;
- never claim performance from shared CI hardware.

### Local release gate

- target Mac on AC power, Low Power Mode off;
- no running Speakeasy process or competing benchmark worker;
- same model/corpus/config fingerprint;
- release preset with 30–50 repetitions;
- no thermal-pressure warning during measured blocks;
- save raw JSONL and Markdown report.

### Optional self-hosted performance CI

Only after one stable dedicated Mac exists. Pin the machine, model cache, power state, and OS update policy. Shared GitHub macOS runners are not valid regression baselines.

## Rollout

1. Land Chunks 1–4 without production changes.
2. Capture and review the production-parity baseline.
3. Land option-sweep support and evaluate one knob family per change.
4. Promote a native option only after the release preset passes.
5. Benchmark streaming separately; do not wire it into capture in the same change.
6. Add app/capture correlation before claiming end-user improvement.
7. Update the named baseline only when an intentional production change is accepted.

## Failure behavior

- Invalid manifest/config: fail before model load.
- Unsupported capability/extension: mark skipped with reason or fail the requested strict matrix.
- Worker timeout/crash: emit a typed failed sample; terminate the worker process; continue only when the run policy allows.
- Partial JSONL: preserve completed records and mark the run incomplete.
- Baseline mismatch: report incomparable, never pass/fail.
- Thermal/power instability: mark the run invalid for gating but retain diagnostic output.
- Model files: read-only; the harness never deletes, downloads, or mutates them.

## Residual risks

- A small local corpus can overfit optimization choices. Grow by failure category, not random volume alone.
- WER does not capture every semantic or punctuation failure. Keep exact command and punctuation-sensitive measures.
- Unified-memory RSS does not isolate Metal allocations perfectly. Treat it as consistent local evidence, not universal GPU memory.
- Streaming benchmark wins may not survive real callback scheduling; app integration needs a separate proof.
- A future transcribe.cpp-compatible model may expose different family extensions. The adapter reports capabilities rather than assuming Parakeet semantics.

## Open decisions

1. Fixture source: create a redistributable repository corpus, use an ignored private corpus, or maintain both. Recommended: both, with the public corpus as the shared gate.
2. Baseline storage: commit compact summaries only or raw JSONL too. Recommended: commit summaries/config fingerprints; archive raw JSONL outside Git.
3. Target hardware: name the primary Mac model for release gates.
4. Streaming success threshold: proposed 20% medium/long p95 or 50 ms on short utterances, with no more than +0.5 WER points.
5. Future model naming: add candidates only when a concrete transcribe.cpp-compatible artifact and license exist; do not pre-design around an unverified Cohere model.
