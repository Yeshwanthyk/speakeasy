# Hot-Path Constant-Cost Audit

Inspired by phonon's detokenizer find (-134 ms/utterance hiding in a property
accessor): audit every constant per-dictation cost at wisp's boundaries.
Measured medians on the development machine (debug build unless noted), via
`HotPathPerformanceTests` which also enforces generous regression ceilings.

## Baseline vs after optimization

| Segment | Before | After | Change |
|---|---:|---:|---|
| SpeechGate.analyze, 30 s audio | 36.7 ms | **0.83 ms** | -97% (vDSP energy scan; ZCR gated by coarse floor pre-scan) |
| PhoneticCorrector.correct, 300-word utterance | 2.26 ms | **1.34 ms** | -41% (per-call skeleton cache: normalize each unique word once) |
| PhoneticCorrector.correct, typical sentence | 0.097 ms | 0.073 ms | noise |
| PostProcessor pipeline (commands + corrections + phonetic) | 0.074 ms | 0.077 ms | unchanged |
| HallucinationFilter.verdict, typical text | 0.011 ms | 0.012 ms | unchanged |
| FloatRingBuffer.readLast (300 ms preroll) | 0.387 ms | 0.388 ms | unchanged |

Release builds shift all numbers down further; the guards catch
order-of-magnitude regressions either way.

## Findings

1. **Speech gate dominated key-up latency.** The original per-sample Swift
   loop paid bounds checks across 480k samples. Frame energy now goes through
   `vDSP.meanSquare`, and zero-crossing counting runs only for frames whose
   energy clears a coarse (~16-frame sample) floor pre-scan - silence-heavy
   recordings skip nearly all sign-flip work. Voicing decisions are
   byte-identical to the scalar implementation (all SpeechGateTests pass
   unchanged).
2. **Phonetic skeleton normalization was O(windows x tokens).**
   `normalize()` performs Unicode folding; caching skeletons per unique word
   within a `correct()` call removes the multiplier on long utterances.
3. **Already clean:** correction rules compile at init (no regex construction
   on the dictation path); store persistence is Task-based off main;
   pasteboard snapshot/write/verify is required semantics at sub-ms cost;
   FFI boundary overhead is now visible per run through cross-reported
   `AsrTimings` (see NativeASRTimings logging).
4. **Noted, not fixed (out of scope):** `FloatRingBuffer.write` holds its
   lock for a whole callback chunk on the render thread; contention risk is
   theoretical today because `readLast` fires once per utterance start, but
   an RT-safe single-writer design is worth revisiting if capture ever gains
   concurrent readers.
