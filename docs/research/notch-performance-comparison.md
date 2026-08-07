# Notch recording indicator: performance comparison

- Date: 2026-08-07
- Baseline commit: `7f6eb4c2949e274ba650214832427a84fe8d7218`
- Candidate branch: `feat/notch-recording-indicator`

## Verdict

The notch indicator adds a measurable but small UI cost and does not degrade the speech pipeline.

- Sustained recording adds **0.05 CPU-seconds over 10 seconds**, equivalent to about **0.5 percentage points of one logical core** in this isolated harness.
- Median peak resident memory increases by **0.58 MiB**.
- The 60 Hz probe measures a small scheduling cost: candidate p95 lateness is **1.45 ms**, compared with **0.89 ms** before the change. It remains far below one 16.67 ms frame.
- The speech benchmark's built-in comparison **passes all regression gates**, with identical WER and slightly faster measured p50/p95 in the comparable warm run.

The implementation is performant enough to keep as-is. The relative CPU percentages look large only because the baseline process uses roughly one tenth of a CPU-second during the entire ten-second run; the absolute increase is small.

## Environment and method

Both measurements ran on the same Apple M4 Pro Mac with 24 GiB RAM, macOS 26.6 (25G72), on AC power at 100% charge.

The pre-change UI harness was compiled from the detached baseline worktree. The candidate harness was compiled with `-O` and a macOS 12 deployment target. Each scenario ran five times for ten seconds; tables report medians. `/usr/bin/time -lp` supplied CPU, instruction, cycle, and resident-memory measurements. A separate 60 Hz main-run-loop timer measured scheduling lateness.

Two UI scenarios were measured:

1. **Recording:** the indicator remains visible for all ten seconds. This is the direct apples-to-apples comparison.
2. **Lifecycle:** recording for five seconds, then processing for five seconds. Before this change the glow was hidden at the five-second transition, so the candidate deliberately does more work in the second half.

The candidate uses a fixed representative RMS level in the harness. Production reads the existing constant-space microphone snapshot; it does not add work to the real-time audio callback.

## UI results

### Sustained recording (direct comparison)

| Metric, median of 5 | Screen-edge glow | Notch indicator | Change |
|---|---:|---:|---:|
| CPU time / 10 s | 0.10 s | 0.15 s | +0.05 s (+50.0%) |
| Approx. one-core utilization | 1.0% | 1.5% | +0.5 percentage points |
| Peak RSS | 35.98 MiB | 36.56 MiB | +0.58 MiB (+1.61%) |
| Instructions retired | 413.3 M | 470.0 M | +56.7 M (+13.71%) |
| Cycles | 252.6 M | 369.8 M | +117.2 M (+46.40%) |
| Tick p95 lateness | 0.892 ms | 1.453 ms | +0.561 ms |
| Median per-run maximum tick lateness | 1.070 ms | 3.136 ms | +2.066 ms |
| Show call | 15.91 ms | 20.09 ms | +4.19 ms |
| Hide call | 0.222 ms | 0.292 ms | +0.070 ms |

The candidate's five maximum tick-lateness values were 1.94–6.36 ms. The baseline included a 70.84 ms outlier, while its other runs were 0.83–6.96 ms. The p95 shift is measurable but remains under 1.5 ms and does not approach a dropped 60 Hz frame.

Cycle counts are noisier than instructions and wall scheduling at this workload size. Instructions are the more stable signal: the five-bar, 30 Hz animation adds about 57 million instructions over ten seconds, while the complete harness process remains at 1.5% of one core.

### Recording-to-processing lifecycle

| Metric, median of 5 | Old lifecycle | New lifecycle | Change |
|---|---:|---:|---:|
| CPU time / 10 s | 0.11 s | 0.18 s | +0.07 s (+63.64%) |
| Peak RSS | 36.09 MiB | 36.61 MiB | +0.52 MiB (+1.43%) |
| Instructions retired | 418.6 M | 472.0 M | +53.4 M (+12.77%) |
| Tick p95 lateness | 0.748 ms | 1.532 ms | +0.784 ms |
| Median per-run maximum tick lateness | 1.194 ms | 4.629 ms | +3.435 ms |
| Recording → next state call | 0.276 ms (hide) | 1.344 ms (processing) | +1.068 ms |
| Final hide call | 0.262 ms | 0.402 ms | +0.140 ms |

This lifecycle comparison is intentionally conservative: the old UI was absent for the final five seconds, whereas the new UI continues a processing animation. Even with twice the visible duration, the absolute CPU difference is still 0.07 seconds over the run.

## Speech pipeline control

The standalone quick preset performs 25 transcriptions per run. It does not instantiate the overlay, so it acts as a control for accidental changes to model execution, output quality, or shared dependencies.

| Run | Wall p50 | Wall p95 | RTF p50 / p95 | Model load | Peak RSS | Micro-WER |
|---|---:|---:|---:|---:|---:|---:|
| Baseline A | 47.86 ms | 95.36 ms | .019 / .039 | 7475.76 ms* | 918.0 MiB | 9.26% |
| Baseline B | 50.55 ms | 101.39 ms | .020 / .039 | 219.88 ms | 916.0 MiB | 9.26% |
| Candidate A | 52.98 ms | 96.75 ms | .021 / .040 | 358.57 ms | 905.3 MiB | 9.26% |
| Candidate B | 47.04 ms | 93.05 ms | .019 / .040 | 195.79 ms | 913.0 MiB | 9.26% |

`*` Baseline A paid a cold/cache-sensitive model-load cost and is not comparable to the warm load measurements.

Across the two runs, the midpoint moved from 49.21 to 50.01 ms at p50 (+1.64%) and from 98.38 to 94.90 ms at p95 (-3.53%). These small opposing changes are normal run-to-run variation. Candidate B versus warm baseline B improved p50 by 6.94%, p95 by 8.23%, and warm load by 10.96%; peak RSS fell 0.33%; WER was unchanged. The benchmark comparator passed every configured regression gate after declaring the intentional repository source change.

## Why the cost stays bounded

- The indicator uses one small borderless panel with a fixed set of Core Animation layers, not a full-screen glow surface.
- A 30 Hz main-run-loop timer exists only while recording or processing.
- It reads the existing locked microphone-level snapshot; it does not allocate or publish from the audio callback.
- Display selection happens only when recording starts. The selected display remains pinned through processing, so there are no per-frame app or display queries.
- Reduced Motion removes waveform travel/pulsing behavior.
- The panel is click-through and nonactivating, so it does not alter focus or the delivery target.

## Recommendation

Keep this implementation. There is no evidence of a user-visible responsiveness, speech-latency, memory, or quality regression.

If later battery or Instruments traces show an energy concern, the first low-risk optimization is to reduce the visual timer from 30 Hz to 20–24 Hz and give it a coalescing tolerance. That should be evidence-driven; the current absolute overhead does not justify complicating the design now.

## Raw artifacts

Generated benchmark artifacts are intentionally Git-ignored:

- `benchmarks/results/notch-2026-08-07/ui-baseline/`
- `benchmarks/results/notch-2026-08-07/ui-candidate/`
- `benchmarks/results/notch-2026-08-07/ui-comparison.json`
- `benchmarks/results/notch-2026-08-07/baseline-speech-{a,b}.{jsonl,md}`
- `benchmarks/results/notch-2026-08-07/candidate-speech-{a,b}.{jsonl,md}`
- `benchmarks/results/notch-2026-08-07/speech-comparison.md`
