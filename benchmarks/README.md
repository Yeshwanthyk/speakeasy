# Speakeasy speech benchmark

This harness measures speech models through the same exact `transcribe-cpp = 0.1.3` release used by Speakeasy. It is a standalone Rust package and is never linked into the app.

## Setup

1. Prepare a licensed/private corpus using [`fixtures/README.md`](fixtures/README.md).
2. Save it as `benchmarks/fixtures/manifest.json` with WAV files under `benchmarks/fixtures/audio/`.
3. Install the production Parakeet GGUF in Speakeasy's normal model directory, or use the pinned candidate catalog below.
4. Keep the Mac on power, disable Low Power Mode, close noisy workloads, and let thermal state settle.

Private fixture audio, local manifests, and generated results are ignored by Git.

## Commands

```bash
# Fast correctness and smoke preset
./script/benchmark.sh benchmarks/configs/quick.json

# Full development and release measurements
./script/benchmark.sh benchmarks/configs/dev.json
./script/benchmark.sh benchmarks/configs/release.json

# One fresh process/model load per fixture
./script/benchmark.sh benchmarks/configs/process-cold.json

# Streaming compute and user-perceived release latency
./script/benchmark.sh benchmarks/configs/streaming-accelerated.json
./script/benchmark.sh benchmarks/configs/streaming-realtime.json

# Validate without loading the model
cargo run --locked --manifest-path benchmarks/speech-bench/Cargo.toml -- \
  validate-fixtures benchmarks/fixtures/manifest.json

# Harness correctness suite (no model required)
./script/test_benchmark.sh

# Inspect pinned candidates without downloading anything
benchmarks/speech-bench/target/release/speech-bench catalog

# Download one candidate; the file is verified before it is installed.
# Do not run this for multi-GB candidates unless disk and memory are available.
benchmarks/speech-bench/target/release/speech-bench download moonshine-streaming-small-q8_0

# Verify an artifact that is already present
benchmarks/speech-bench/target/release/speech-bench verify-artifact \
  moonshine-streaming-small-q8_0 \
  "$HOME/.cache/wisp/benchmark-models/moonshine-streaming-small-Q8_0.gguf"
```

Each run writes strict JSONL and a Markdown summary under `benchmarks/results/`. Transcript text is never written; sample records contain a text hash and WER counts.

## Modes

- `warm`: one worker retains a loaded model/session across fixtures and repetitions.
- `process_cold`: a fresh worker loads the model for every fixture. This measures process-cold, not disk-cold; macOS page cache is not flushed.
- `streaming_accelerated`: chunks are fed as quickly as possible to isolate compute.
- `streaming_realtime`: chunks arrive at their audio cadence, exposing first-hypothesis, first-commit, and release-to-final behavior.

Workers are sequential and isolated. The driver enforces a timeout, samples peak RSS, rejects malformed stdout, and preserves failures as typed result records.

## Controlled sweeps

Start from a result produced by `production-parity.json`. Change exactly one field using a config under `configs/sweeps/`, then compare while declaring that intentional difference:

```bash
./script/benchmark.sh benchmarks/configs/sweeps/timestamps-none.json

benchmarks/speech-bench/target/release/speech-bench compare \
  benchmarks/results/CANDIDATE.jsonl \
  benchmarks/results/BASELINE.jsonl \
  --allow-change run.timestamps
```

Supported declarations cover the model, session, run, stream, and execution controls exposed by the schema. Use `build.repository` only for an intentional source change and `build.lockfiles` only for an intentional dependency change. Unknown paths fail closed. Without an explicit declaration, differing identities are incomparable.

For streaming versus batch, declare `--allow-change execution.mode`. The comparison uses streaming release-to-final against batch inference latency rather than comparing real-time streaming wall duration.

Do not bundle multiple knobs into one candidate. For close results, alternate baseline and candidate runs and require the result to reproduce.

## Compact candidate sweep

The pinned catalog is [`models/catalog.json`](models/catalog.json). It contains
the exact Hugging Face revision, filename, byte count, SHA-256, license, and
native-streaming status for the six requested artifacts. A config that names a
`model.catalog_id` is rejected before model loading unless the local file
matches both the catalog byte count and SHA-256. The result's engine identity
also records the expected and actual artifact values.

Candidate configs live under [`configs/candidates/`](configs/candidates/):

- Every candidate has a five-repetition warm batch correctness/performance run.
- Moonshine Small and Medium also have realtime native-stream configs.
- The warm run records load time, wall latency, peak RSS, text hashes, WER
  counts, truncation, native capabilities, and actual backend.
- Run each candidate on the same corpus and host. The configs do not download
  models and fail clearly when an artifact is absent.

Run the candidate configs after downloading only the artifacts you intend to
measure:

```bash
for config in benchmarks/configs/candidates/*.json; do
  ./script/benchmark.sh "$config"
done

# Or build once and run the complete warm/cold/Moonshine candidate sweep.
./script/benchmark_compact_sweep.sh
```

Do not promote a candidate from the catalog alone. Promotion requires a
successful warm batch result, a process-cold load/RSS result, matching artifact
identity, repeated latency evidence, and corpus quality evidence. Moonshine
stream runs additionally require final stream text to match the batch quality
gate; committed-prefix revisions are retained as telemetry because the model
family may re-attend earlier text. Medium decoder truncation or any worker
crash, hang, load error, or stream-contract error is a failed gate.

## Promotion gates

A candidate must have no crash, hang, truncation, load failure, or typed worker error. Initial regression limits are:

- warm p50: no worse than `max(5%, 10 ms)`;
- warm p95: no worse than `max(10%, 25 ms)`;
- process-cold model load p50: no worse than `max(15%, 500 ms)`;
- peak RSS: no worse than 10% plus a 128 MiB floor;
- corpus micro-WER: no worse than 0.5 percentage points.

Promotion also requires a meaningful gain: at least 10% p95 or 5% p50 for native options, and at least 20% or 50 ms release-to-final improvement for streaming. Review bucket-level quality manually until bucket gates are added to the reporter.

## App-aware Smart Cleanup

The app-aware cleanup benchmark is separate from the speech-engine harness. It
uses synthetic text and destination contexts. It records hashes and invariant
checks, not transcript or model output text.

```bash
# Instant deterministic path
./script/benchmark_smart_cleanup.sh basic 10

# macOS 26 Apple Foundation Models path
./script/benchmark_smart_cleanup.sh smart 10
```

The Smart run requires an eligible Mac with Apple Intelligence enabled and its
model ready. It reports the client process only. Apple's model service can run
out of process, so the benchmark's RSS and CPU values do not represent the
complete system cost. Compare modes on the same Mac and power state.

## App capture profiling

The engine harness intentionally excludes microphones, Accessibility, paste, and UI scheduling. Profile those separately with Instruments using a release app build:

1. Record one short dictation to establish first-use allocation behavior.
2. Record 20 identical-duration dictations while collecting Allocations and Time Profiler traces.
3. Filter stacks to `AudioCapture.consume`, `flushBackBuffer`, `beginRecording`, and `endRecording`.
4. Confirm the audio callback's p99 duration remains below 5 ms and that stop-to-buffer-return stays bounded for long recordings.
5. Compare hotkey-to-capture-ready and stop-to-buffer-return separately from engine inference.

`endRecording()` transfers the completed buffer in O(1) rather than copying it under the capture lock. Validate allocation behavior with Instruments on real hardware; unit tests do not substitute for that trace.

## Baselines

See [`baselines/README.md`](baselines/README.md). Baselines are local-hardware evidence, not universal numbers. CI checks schemas, scoring, process isolation, formatting, and linting; it never asserts wall-clock performance on shared runners.

## Future models

Add another engine adapter only when a concrete local GGUF/artifact, redistribution license, transcribe.cpp compatibility story, and reproducible settings exist. Every model uses the same fixture decoder, scoring, result protocol, fingerprints, and reliability gates. Do not prewire an unverified Cohere or cloud dependency into Speakeasy.
