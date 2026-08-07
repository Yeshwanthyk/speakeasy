# Compact speech-model benchmark synthesis

**Measured:** 2026-08-07  
**Host:** Apple M4 Pro (`Mac16,8`), Metal `MTL0`, 24 GB RAM, macOS 26.6  
**Runtime:** `transcribe-cpp 0.1.3`  
**Corpus:** `speakeasy-synthetic-directional-v1`, five English fixtures  
**Evidence:** 230 primary samples across 14 configurations, plus 100 interleaved winner/baseline recheck samples

## Decision

**Parakeet TDT+CTC 110M Q8_0 is the clear compact winner in this directional corpus.**

Across two interleaved A/B rechecks against production Parakeet Unified, it reproduced:

- 53% lower warm p50;
- 55% lower warm p95;
- 71% lower model-load time;
- 69% lower peak RSS;
- synthetic WER improving from 9.26% to 1.85%;
- zero failures, truncations, crashes, or driver errors.

Both A/B comparisons passed the harness regression gates. This makes Parakeet 110M the only candidate worth advancing to a representative human-speech corpus and an application canary. It is not yet sufficient evidence to silently replace the production default because the current corpus has only five synthetic utterances.

## Warm batch results

| Model | Artifact | p50 | p95 | Load p50 | Peak RSS | Micro-WER | Decision |
|---|---:|---:|---:|---:|---:|---:|---|
| **Parakeet TDT+CTC 110M Q8** | 135 MB | **22.34 ms** | **42.45 ms** | **60.82 ms** | **281.8 MiB** | **1.85%** | Advance |
| Production Parakeet Unified Q8 | 731 MB | 47.52 ms | 95.23 ms | 208.34 ms | 915.5 MiB | 9.26% | Current default |
| Moonshine Streaming Small Q8 | 199 MB | 56.28 ms | 174.26 ms | 87.56 ms | 490.5 MiB | 9.26% | Reject for batch |
| Parakeet TDT 1.1B Q8 | 1.27 GB | 72.11 ms | 137.48 ms | 323.10 ms | 1,397.9 MiB | 3.70% | Reject; 110M dominates |
| Moonshine Streaming Medium Q8 | 296 MB | 92.28 ms | 274.95 ms | 111.10 ms | 739.4 MiB | 9.26% | Reject |
| Cohere Transcribe 03-2026 Q4_K_M | 1.56 GB | 125.09 ms | 241.11 ms | 417.89 ms | 1,624.7 MiB | 9.26% | Reject for default tier |
| Whisper Small Q4_K_M | 172 MB | 169.25 ms | 231.21 ms | 82.39 ms | 353.6 MiB | 9.26% | Reject for English default |

Parakeet 110M values are means of the two interleaved rechecks. Production values use the paired A/B runs from the same recheck sequence.

## Reproduced A/B evidence

| Run | Production p50/p95 | Parakeet 110M p50/p95 | Production RSS | 110M RSS | Production WER | 110M WER |
|---|---:|---:|---:|---:|---:|---:|
| A | 47.52 / 94.59 ms | 22.29 / 44.26 ms | 915.1 MiB | 282.2 MiB | 9.26% | 1.85% |
| B | 47.51 / 95.86 ms | 22.39 / 40.63 ms | 915.8 MiB | 281.4 MiB | 9.26% | 1.85% |

## Streaming result

Moonshine moved work under the recording window, but did not improve release latency versus the current fast batch path:

| Model | First hypothesis p50 | First commit p50 | Release-to-final p50 | Release-to-final p95 | RSS | WER |
|---|---:|---:|---:|---:|---:|---:|
| Moonshine Small | 534.90 ms | 1,022.53 ms | 66.29 ms | 168.87 ms | 521.9 MiB | 9.26% |
| Moonshine Medium | 553.66 ms | 1,035.45 ms | 97.13 ms | 247.49 ms | 775.4 MiB | 9.26% |

Production Parakeet batch p50/p95 was 47.52/95.23 ms. Moonshine Small's finalization therefore remained slower at both p50 and p95, while quality did not improve. Neither Moonshine model earns production streaming work from this evidence.

## Candidate decisions

1. **Parakeet TDT+CTC 110M:** advance. Best latency, memory, artifact size, and measured quality.
2. **Moonshine Small:** retain only as a future streaming research candidate. It reduced memory but lost release latency and quality did not improve.
3. **Moonshine Medium:** reject. Small was faster and lighter with the same measured WER.
4. **Cohere:** reject for the default path. It doubled load time, added 78% RSS, and was 2.5× slower at p95 without a corpus-quality gain. Reconsider only for a separately justified multilingual corpus.
5. **Parakeet 1.1B:** reject. It improved synthetic WER, but the 110M model was both more accurate and substantially faster/lighter in this corpus.
6. **Whisper Small:** reject for English dictation. It is compact but much slower with no measured quality gain. Reconsider only for translation or language coverage.

## Evidence boundary

These results are directional, not a final production promotion packet:

- five synthetic fixtures repeated five times support stable latency but weak quality generalization;
- cold runs contain five samples per model;
- no accents, spontaneous speech, microphone noise, proper-name set, technical vocabulary, or adversarial silence set is represented;
- all runs used one M4 Pro under one power/thermal environment;
- model artifacts and result records were fully fingerprinted and every primary run completed without failure or truncation.

## Next gate

Run production Parakeet and Parakeet 110M on a versioned human-speech corpus covering short/long utterances, accents, names, numbers, formatting commands, technical vocabulary, quiet speech, and silence/noise. If the 110M model stays within +0.5 percentage points of production WER while preserving at least a 15% p95 or 20% RSS win, add it transactionally as the compact/default candidate with production Parakeet retained as last-known-good fallback.

Raw evidence is under `benchmarks/results/compact-candidates/` (ignored from Git because fixture/result data is local).
