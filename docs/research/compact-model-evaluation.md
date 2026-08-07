# Compact model evaluation plan

**Status:** harness support added; no candidate promoted.

The candidate catalog and configs are deliberately separate from production
model selection. See [`benchmarks/models/catalog.json`](../../benchmarks/models/catalog.json)
and the [candidate configs](../../benchmarks/configs/candidates/). No model file
is checked into this repository and no model is downloaded by the test suite.

## Required evidence per candidate

| Gate | Required evidence | Failure examples |
|---|---|---|
| Artifact integrity | Catalog ID, exact revision, expected/actual byte count, expected/actual SHA-256, verified result record | Wrong file, partial download, mutable/unpinned URL |
| Correctness | Same corpus manifest and normalization version, successful samples, micro-WER and bucket review | Load error, crash, timeout, truncation, unacceptable WER |
| Latency | Repeated warm wall/native timings plus process-cold model-load timings | High p50/p95, unstable repeats, missing timing |
| Memory | Peak RSS and post-load device free memory on the identified host | Missing memory evidence or unacceptable working set |
| Streaming | Only for Moonshine: realtime first hypothesis/commit/release-to-final and final-text quality comparison | Revisions treated as authoritative, stream failure, Medium decoder loop |

The existing result protocol records the measurements without storing transcript
text. A catalog-aware model load fails before native loading when the file does
not match its pinned size or SHA-256. This prevents a result with a mislabeled
artifact from becoming promotion evidence.

## Run order

1. Run `./script/test_benchmark.sh`.
2. Download or provide one exact artifact and run its warm batch config.
3. Run the same candidate with a process-cold configuration when collecting
   load and cold-memory evidence.
4. For Moonshine, run its realtime streaming config and compare final text and
   quality with the batch run. Do not infer native streaming for Parakeet,
   Cohere, or Whisper from their batch result.
5. Save the JSONL and Markdown results as a host-specific baseline only after
   reviewing all four gates. Until then, mark the candidate unpromoted.

The catalog entries are screening candidates from the compact-model research
report. They are not application defaults, and the planning memory envelopes
in that report are not observed Wisp measurements.
