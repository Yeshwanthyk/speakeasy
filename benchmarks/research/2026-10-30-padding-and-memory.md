# Short-clip padding and retained-session memory

Measured 2026-10-30 to decide whether to adopt two ideas from Hex: padding short clips to 1.5 s, and rotating the native session to bound memory. Both were rejected for the default model.

## Setup

- Model: `parakeet-tdt-ctc-110m-q8_0` (catalog pin, SHA-256 verified), `transcribe-cpp 0.1.3`, warm mode, one repetition.
- Hardware: Linux x86_64, 4 vCPU, CPU backend. This is not Metal: absolute latency and memory differ on a Mac, but the same model and graph are used.
- Corpus (133 clips): 73 LibriSpeech dev-clean clips (`hf-internal-testing/librispeech_asr_dummy`, CC-BY-4.0), and 60 short commands synthesized with flite (`slt` and `kal` voices, 0.5–1.5 s). The synthesized voices are robotic, so only differences between variants are meaningful, not absolute WER.
- Variants differ only in audio: `base`; `pad200`, which appends 200 ms of silence; and `pad1500`, which appends silence up to 1.5 s, as Hex does.

## Padding results

| Variant | All WER | LibriSpeech WER | LibriSpeech exact | Synthesized WER | Synthesized exact |
|---|---:|---:|---:|---:|---:|
| base | 6.49% | 4.43% | 45/73 | 18.85% (short) | 44/58 |
| pad200 | 6.42% | 4.35% | 46/73 | 19.67% (short) | 42/58 |
| pad1500 | 6.57% | 4.43% | 45/73 | 19.67% (short) | 43/58 |

Every difference is one or two utterances. Padding to 1.5 s does not help the 110M model on this corpus, and it slightly hurts short synthesized clips. Speakeasy keeps sending unpadded audio. Re-run before changing the default model.

## Memory results

| Run | Peak RSS |
|---|---:|
| Short and medium clips (the corpus above) | 373 MiB |
| One 62 s input | 493 MiB |
| The same 62 s input ×6 in one session | 504 MiB |
| 23 s, 62 s, 62 s, and 130 s inputs in one session | 803 MiB |

Memory tracks the longest single input, roughly quadratically, through offline full attention. It does not grow across repeated runs. Speakeasy already caps a native call at 60 s windows, and meeting segments at 30 s, so session rotation is unnecessary.

## Reproduce

The corpus builder and comparison scripts were scratch tools kept outside the repository. To repeat the experiment:

1. Build a corpus in the `speakeasy.fixtures.v1` format.
2. Point a copy of `benchmarks/configs/candidates/parakeet-tdt-ctc-110m-q8_0.json` at each variant's manifest.
3. Run `speech-bench run`, then compare per-bucket WER from the JSONL results.
