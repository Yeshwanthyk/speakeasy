# Unramble → Speakeasy: deep comparison, model expansion, and performance-safe roadmap

**Research date:** 2026-08-06
**Unramble inspected:** [`1827c582b908f0bdd7fc566011b012e828413d17`](https://github.com/mrinalwadhwa/unramble/tree/1827c582b908f0bdd7fc566011b012e828413d17), cloned at `/tmp/unramble`
**Speakeasy inspected:** [`dd4d5d03509392fbe7b29ca5db86abc495cf4b71`](https://github.com/Yeshwanthyk/speakeasy/tree/dd4d5d03509392fbe7b29ca5db86abc495cf4b71), branch `perf/parakeet-benchmark-harness` with pre-existing WIP
**Discovery:** four independent GPT-5.6 Luna high-effort scouts plus direct source, model-card, runtime, and test inspection
**Scope:** recommendations only; no application implementation was requested or performed

## Executive synthesis

Speakeasy should copy **Unramble's recovery, streaming, deterministic cleanup, diagnostics, and lifecycle proof patterns**—not its full product or runtime stack.

The central recommendation is:

```text
Keep Speakeasy's prepared 16 kHz capture and retained transcribe.cpp session
  + make successful text recoverable before paste
  + add cheap deterministic cleanup and stronger degeneration guards
  + benchmark streaming on the three models Speakeasy already ships
  + trial new GGUF models through the existing isolated harness
  + promote only fingerprinted winners
```

The most important model conclusion is that Speakeasy **does not need to adopt Unramble's MLX runtime to test Cohere**. The exact `transcribe-cpp 0.1.3` source already embedded by Speakeasy registers `cohere`, `moonshine_streaming`, `whisper`, `qwen3_asr`, and other GGUF families alongside Parakeet. A public Cohere Transcribe 03-2026 GGUF exists. This allows Cohere to enter as a normal benchmark candidate without adding MLX dependencies, raising the deployment floor to macOS 14, or creating a second native runtime.

Recommended order:

1. **Create a real numerical production-parity baseline.** The harness exists, but no fixture corpus, result, or baseline artifact exists yet.
2. **Land correctness improvements that should cost effectively zero:** durable transcript-before-paste, truthful paste/model-switch state, repeated-loop detection, bounded diagnostics, and deterministic spoken formatting commands.
3. **Benchmark existing Parakeet Unified and Nemotron streaming before adding another model.** This is the highest-probability route to lower release-to-final latency.
4. **Benchmark new models without cataloguing them:** Moonshine Streaming Small/Medium for low memory and streaming latency; Parakeet TDT+CTC 110M for a compact tier; Cohere Q4_K_M for a quality/multilingual tier.
5. **Only then add user-visible model choices.** Keep Parakeet Unified as the fallback/default until a candidate wins on the target corpus and machine.

## What each project is optimized for

### Speakeasy's current strength

Speakeasy has a narrow, legible path:

```text
Hyper+S
  → prepared AVAudioEngine
  → bounded pre-roll + adaptive stop grace
  → one contiguous 16 kHz Float32 buffer
  → retained transcribe.cpp GGUF session
  → borrowed PCM across the Rust boundary
  → simple filtering
  → bounded local history
  → paste
```

The authoritative state machine is `idle → startingCapture → recording → transcribing(token) → idle`; the token prevents stale completion. Capture is prepared while idle, conversion is reused, route changes invalidate old tap generations, native inference is off-main and serialized, and history writes are asynchronous. See [`ARCHITECTURE.md`](../../ARCHITECTURE.md), [`Sources/AppCoordinator.swift`](../../Sources/AppCoordinator.swift), [`Sources/AudioCapture.swift`](../../Sources/AudioCapture.swift), and [`rust/asr_bridge/src/lib.rs`](../../rust/asr_bridge/src/lib.rs).

These are the baseline invariants to preserve.

### Unramble's current strength

Unramble has a much broader, more defensive pipeline:

```text
press/release timestamp
  → session-owned activation
  → prepared/cached AUHAL transport
  → timestamped 16 kHz PCM routing
  → local rolling Cohere or cloud Realtime
  → bounded deterministic/model formatting
  → exact release-boundary drain
  → session/revision-owned transcript buffer
  → serialized app-aware injection
  → explicit retry/failure/idle transition
```

Representative sources:

- [`HotkeyPipelineDriver.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/HotkeyPipelineDriver.swift)
- [`DictationPipeline.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/DictationPipeline.swift)
- [`TimestampedAudioFrameRouter.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/TimestampedAudioFrameRouter.swift)
- [`LocalStreamingProvider.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/LocalStreamingProvider.swift)
- [`TranscriptBuffer.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/TranscriptBuffer.swift)
- [`AppTextInjector.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/AppTextInjector.swift)

Unramble's breadth also creates costs: roughly 98,000 Swift lines across app/core/tests, large coordinators, a second model for constrained list formatting, many modes, and substantial lifecycle machinery. Speakeasy should take narrow mechanisms, not reshape itself into Unramble.

## Current model inventory

### Speakeasy production catalog

The authoritative catalog is [`Sources/ModelPathResolver.swift`](../../Sources/ModelPathResolver.swift):

| Model | Artifact bytes | Current use |
|---|---:|---|
| Parakeet Unified EN 0.6B Q8_0 | 731,357,568 | Default English model; the artifact/runtime supports buffered streaming, but production uses batch. |
| Parakeet TDT v3 0.6B Q8_0 | 739,508,576 | 25-European-language batch option. |
| Nemotron Streaming 3.5 0.6B Q8_0 | 751,094,240 | Multilingual option; the artifact/runtime supports streaming, but production uses batch. |

All three are downloaded from immutable revisions, verified by expected bytes and SHA-256 during installation, and loaded through one retained `transcribe-cpp 0.1.3` session. The app's bridge currently hides capabilities and always calls `RunOptions::default()`.

### Unramble production and latent models

| Role | Model | Production status |
|---|---|---|
| Local ASR | Cohere Transcribe 03-2026, 4-bit MLX | Active, but hard-coded to English in the current composition. Uses 30-second windows with 25-second stride. |
| Local formatting | Qwen3 0.6B 4-bit + list LoRA | Active only for strongly signaled lists; unloaded after use. It is not a general mandatory polisher. |
| Local TTS | Kokoro 82M BF16 | Active for Read Aloud when assets are present; not ASR. |
| Local ASR | Nemotron 0.6B Core ML | Implemented and tested, but not wired into production composition. |
| Cloud ASR | `gpt-4o-mini-transcribe` | Active in cloud mode and exact-WAV fallback. |
| Cloud session/polish | `gpt-realtime-2.1` | Active in cloud mode. |
| Cloud TTS | `gpt-4o-mini-tts` | Active in cloud Read Aloud. |

Evidence: [`DictationCompositionFactory.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/DictationCompositionFactory.swift), [`CohereMLXEngine.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Engines/CohereMLXEngine.swift), [`NemotronEngine.swift`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Engines/NemotronEngine.swift), and [`scripts/models.sh`](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/scripts/models.sh).

## Models Speakeasy should evaluate

### First: no new model—stream what is already installed

Before expanding the catalog, benchmark:

1. **Parakeet Unified buffered streaming** at controlled left/chunk/right windows.
2. **Nemotron 3.5 cache-aware streaming** with its supported feed cadence and commit policy.
3. The same artifacts in current batch mode as the baseline.

This avoids a new download, license, model-selection, and quality variable. It also directly targets the operator-visible metric: work performed during speech rather than after release. Unramble validates the product shape—recognize incrementally, keep partials internal, finalize once, inject once—but Speakeasy's own runtime and harness should define the implementation.

### Ranked new-model candidates

The artifact identities below came from the public Hugging Face API on 2026-08-06. They are **benchmark-ready candidates, not approved catalog entries**. A real `transcribe-cpp 0.1.3` load and corpus run remains mandatory.

| Rank | Candidate | Concrete artifact | Why evaluate | Main risk |
|---:|---|---|---|---|
| 1 | Moonshine Streaming Small Q8_0 | 123M, 198,506,848 bytes, MIT; revision `41444173ed8210852a883e046fadcfba3e7bfbae`; SHA-256 `d03670f69629b649085d0f44a63d97668b4119117cc9611a4e4ad94341713dfc` | Strong compact/streaming tier. Upstream reports 2.54% LibriSpeech test-clean WER and 189 MB display size. | English-only; lower published accuracy than Parakeet Unified; production needs a streaming ABI. |
| 2 | Moonshine Streaming Medium Q8_0 | 245M, 295,793,568 bytes, MIT; revision `c722a9455a40a1844c3d25267dc84eff61d8dd84`; SHA-256 `f7c9564249b508f6012927ec4f9e536087da53a7047f858ca9975bea5f75299e` | Better reported quality than Small (2.16%) while still far smaller than current models. | Decoder may dominate long-utterance latency; English-only. |
| 3 | Parakeet TDT+CTC 110M Q8_0 | 135,373,280 bytes, CC-BY-4.0; revision `9d66d34f9e1594075c5dd72c90c0f4c321b29f21`; SHA-256 `7dd44c74a331d788a4e5f8b16913b3feb29ced22cf5613aad0e0f6cd30516296` | Lowest-integration-risk compact tier in the same model family. Upstream reports 2.43% WER. | Batch-only in the current runtime; quality regression versus the default is likely. |
| 4 | Cohere Transcribe 03-2026 Q4_K_M | 2B, 1,558,162,944 bytes, Apache-2.0; revision `dfa4adebb64f3076b7b6b90b721275cc069cb421`; SHA-256 `0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb` | Directly captures Unramble's ASR choice without adopting MLX. Supports 14 languages and upstream reports 1.25% WER. | Larger disk/RSS, autoregressive decoder, about 400-second per-call limit, no native streaming path. |
| 5 | Parakeet TDT 1.1B Q8_0 | 1,267,288,736 bytes, CC-BY-4.0; revision `8c21810615694c53a4f4745996190fcca880f8e5`; SHA-256 `8479e1ed0b7244e293ed81f547c69074a38c00e17511d8ecae2d273bc7b2ceda` | A simple higher-quality English tier; upstream reports 1.38% WER. | More memory/load cost and likely slower than the default; modest quality delta may not justify it. |
| 6 | Whisper Small Q4_K_M | 171,630,656 bytes, Apache-2.0; revision `c0214bd34be9296695486f838e0142f900803159`; SHA-256 `b204d2005a3e5d4fe6153bd61e5e8b32e757ff7b017ac8f61c6f051c2f80e939` | Broad language/translation coverage with a compact artifact and mature long-form behavior. | Lower English quality than current Parakeet; requires capability/language/Whisper-option plumbing. |

Primary model sources:

- [Moonshine Streaming family](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/moonshine-streaming.md)
- [Parakeet family](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md)
- [Cohere Transcribe 03-2026 GGUF](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/cohere-transcribe-03-2026.md)
- [Whisper family](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/whisper.md)

Published WER and hardware timings are screening evidence only. They are not comparable to Speakeasy until every candidate runs on the same private/public corpus, host, build, backend, normalization, and options.

### Models/runtimes not worth adding now

- **Cohere through MLX:** avoid. GGUF Cohere preserves Speakeasy's runtime, deployment, packaging, and benchmark shape.
- **Unramble's Core ML Nemotron:** avoid. Speakeasy already has a Nemotron 3.5 GGUF and should benchmark its streaming path first.
- **Qwen3 0.6B as mandatory cleanup:** avoid. It adds model load, memory, latency, and faithfulness risk after ASR.
- **Kokoro:** only relevant if Read Aloud becomes an approved feature; it does not improve dictation.
- **OpenAI cloud mode:** defer pending a product/privacy decision. It expands capabilities but changes Speakeasy's local/offline contract and failure model.
- **Voxtral Realtime / large speech-language models:** defer. Their memory and packaging cost conflict with the current baseline until smaller candidates are exhausted.
- **Qwen3-ASR/FunASR/other registered runtime families:** future candidate pool, not a first wave. Runtime registration alone is not evidence of a useful Speakeasy artifact.

## Transferable features

### Tier 0 — adopt before model expansion

#### 1. Durable transcript before delivery

Speakeasy currently checks Accessibility before appending a successful transcript and logs `.pasted` before delivery is known. Unramble stores text first, serializes injection, and retains session-owned recovery state.

Adopt:

- Store accepted text before Accessibility/Cmd-V delivery.
- Return a typed delivery result.
- Add `Paste Last Dictation`/`Copy Last Dictation` recovery.
- Record `pasteSucceeded`, `pasteFailed`, and `accessibilityDenied` truthfully.

Do not add synchronous persistence to release-to-paste; keep the current utility-queue snapshot write.

#### 2. Last-known-good model switching

Speakeasy currently swaps/persists the replacement before warmup completes. Preserve the old transcriber until replacement download, verification, load, and warmup all succeed; then atomically swap and persist.

Also unify artifact verification so existing same-sized files are not trusted by byte count alone.

#### 3. Stronger transcript degeneration guards

Speakeasy's `HallucinationFilter` catches a small exact-response set. Unramble additionally rejects:

- output too dense to fit the audio duration;
- long repeated n-gram decoder loops;
- repeated long sentences;
- known near-silence inventions.

These are cheap, deterministic, model-independent, and veto-only. Add them before the model matrix expands because every model family has different failure surfaces.

#### 4. Deterministic spoken-format commands

Adopt a deliberately small subset of Unramble's first polish stage:

- `new paragraph`, `new line`;
- `question mark`, `exclamation point`;
- `comma`, `colon`, `semicolon` with article/determiner guards;
- `dot dot dot`, common brackets, slash, underscore, and symbols.

Compile rules once. Run one bounded pass after ASR/degeneration validation and before history/paste. Keep raw and final text separate internally. Do not copy the 3,000+ line `PolishPipeline` wholesale.

#### 5. Bounded, content-free diagnostics

Combine Speakeasy's numeric `TranscriptionTrace` with Unramble's ten-entry mic diagnostics and privacy tests:

- model kind and actual backend;
- capture start/stop/recovery outcome;
- ambient/peak RMS and utterance duration;
- release-to-text and release-to-delivery;
- typed failure stage;
- no transcript text or retained audio.

Persist only if bounded and asynchronous. Add a copyable diagnostic report and a release privacy test.

#### 6. Test-lane ownership

Unramble's most transferable infrastructure is its fail-closed test inventory. Speakeasy's SwiftPM target excludes `AppDelegate.swift`, `TranscribeCppTranscriber.swift`, and `main.swift`, so ordinary Swift tests do not prove startup or the production ABI.

Adopt:

- deterministic Swift/Rust/harness lane;
- app-only build/typecheck lane;
- opt-in real-model fixture lane;
- live microphone/device lane;
- a suite inventory that fails when a new test is unassigned.

### Tier 1 — benchmark or add as isolated slices

#### 7. Production streaming with one final injection

Borrow the shape, not Unramble's entire seam-reconciliation implementation:

```text
recording begins
  → start one model-owned stream
  → feed canonical 16 kHz chunks off-main
  → keep partial hypotheses internal
release
  → publish exact capture boundary
  → drain admitted chunks
  → finalize once
  → if stream fails, batch the preserved exact PCM once
  → validate and inject once
```

Required invariants:

- session token/generation ownership for every feed/finalize/fallback;
- no provisional paste;
- no duplicate delivery;
- exact PCM available for fallback;
- explicit reset/cancel before the next session;
- append-only committed text or a final-only commit policy;
- route changes still abort discontinuous recordings.

#### 8. Push-to-talk, hands-free toggle, and cancel

Unramble supports hold-to-dictate, hands-free transfer, and Escape cancellation. This is high operator value and does not require inference changes, but it should be implemented as a thin input driver over Speakeasy's existing authoritative coordinator—not as a second state owner.

#### 9. Microphone selection and preview

Unramble's explicit input-device selection, preview meter, and compatibility diagnostics improve setup and route-change diagnosis. Keep preview data on a newest-value bounded stream and never let UI backpressure or level rendering enter the audio callback.

#### 10. Stronger, app-aware delivery

Useful pieces from Unramble:

- preserve/restore clipboard contents;
- detect whether a target consumed the paste;
- serialize automatic and retry injection;
- app-specific fallback ordering;
- insert/replace using UTF-16-safe cursor/selection calculations.

Start with truthful paste result + clipboard preservation. Direct Accessibility value replacement and per-character keystrokes should remain fallbacks because they can be slow or disruptive.

#### 11. One failed-capture replay lease

Retain one in-memory PCM buffer only after a failed/timed-out transcription and expose explicit retry. Clear it on success, dismissal, new recording, or exit. Never auto-replay a timed-out inference while the old native call might still complete.

### Tier 2 — defer until the simple path is proven

- Narrow Qwen list formatting with lexical/order/boundary validation.
- Read Aloud.
- Optional cloud mode.
- Broader context-aware cleanup.

These can be valuable, but none should block ordinary local dictation.

## Features to reject from the Speakeasy roadmap

Do not copy:

- Unramble's full conversation-call/coding-agent orchestration.
- Mandatory model cleanup after every dictation.
- Cloud credentials/networking bundled with local performance work.
- Default audio retention.
- A second model runtime merely to access a model already available as GGUF.
- The entire AUHAL ownership/timestamp router unless Instruments and reproducible device failures prove Speakeasy's simpler prepared engine is insufficient.
- A continuously animated HUD or polling loop before lightweight status/menu state is inadequate.
- Unbounded history, stats, traces, prompt context, or retry queues.

## Performance contract

### The immediate blocker: no numerical baseline exists

The branch contains a strong standalone benchmark harness, but there is currently:

- no `benchmarks/fixtures/manifest.json`;
- no fixture audio corpus;
- no `benchmarks/results/` artifact;
- no named baseline;
- no real-model equivalence run against the production bridge.

Therefore “maintain baseline performance” is currently an architectural intent, not a measurable release gate. The next performance task is to create the baseline—not tune code or add catalog entries.

### Required baseline packet

On one named target Mac:

1. Prepare a versioned corpus with short, medium, long, silence/noise, proper names, technical terms, numbers, punctuation, accents, and trailing-plosive/fricative cases.
2. Run `production-parity`, warm retained-session, process-cold, streaming-accelerated, and streaming-realtime presets.
3. Save raw JSONL plus Markdown summary outside or inside Git according to the baseline policy.
4. Record repo dirty hash, lockfiles, model SHA, corpus hashes, host, power/thermal state, actual backend/device, and all effective options.
5. Run interleaved A/B for close candidates.

### Promotion gates

Use the existing harness policy as the minimum:

| Metric | Maximum accepted regression / required win |
|---|---|
| Crash, hang, truncation, load failure, typed worker error | Zero new failures |
| Warm inference p50 | No worse than `max(5%, 10 ms)` |
| Warm inference p95 | No worse than `max(10%, 25 ms)` |
| Process-cold model-load p50 | No worse than `max(15%, 500 ms)` |
| Peak RSS | No worse than 10% with a 128 MiB floor |
| Corpus micro-WER | No worse than +0.5 percentage points |
| Duration-bucket WER | No worse than +1.5 percentage points |
| Native option promotion | At least 10% p95 or 5% p50 gain |
| New model/quant promotion | At least 15% p95 or 20% RSS gain unless it opens an explicitly approved language/quality tier |
| Streaming promotion | At least 20% medium/long release-to-final p95 or 50 ms on representative short utterances |

App-level gates remain:

- status item visible p95 under 100 ms independent of model load;
- hotkey-to-visible-feedback p95 under 25 ms;
- prepared hotkey-to-capture-ready p95 under 10 ms;
- zero steady-state audio-callback allocations;
- no first-frame or release-tail loss;
- deterministic postprocessing p95 under 5 ms at maximum configured rules;
- transcription-end-to-delivery request p95 under 10 ms;
- after 1,000 short sessions, no unbounded state and RSS returns within 5% of post-warmup baseline.

## Recommended implementation sequence

### Increment 0 — baseline and bridge truth

- Commit/stabilize the benchmark WIP.
- Create the fixture corpus and first named production-parity baseline.
- Add production-bridge equivalence against the harness adapter.
- Expose model architecture, variant, capabilities, actual backend/device, session limits, and native timings through the Rust boundary.
- Generate the C header rather than manually mirroring ABI structs.

No production behavior change.

### Increment 1 — output durability

- Store accepted text before delivery.
- Add typed paste result and recovery action.
- Make trace outcomes truthful.
- Preserve async history persistence.

This is the highest-value, lowest-risk feature transfer.

### Increment 2 — deterministic quality layer

- Add repeated-loop/density/silence-invention vetoes.
- Add bounded spoken formatting commands.
- Preserve raw/final text separately.
- Add adversarial faithfulness tests and a <5 ms postprocess gate.

No model invocation.

### Increment 3 — model lifecycle truth

- Show the app shell before model work.
- Verify existing artifacts consistently.
- Keep the previous model selected until replacement warmup succeeds.
- Add bounded content-free diagnostics and privacy tests.

### Increment 4 — existing-model streaming experiment

- Benchmark Parakeet Unified and Nemotron streaming.
- Add production streaming only for the measured winner.
- Preserve exact PCM batch fallback and inject once.

### Increment 5 — compact model tier

- Benchmark Moonshine Streaming Small/Medium and Parakeet TDT+CTC 110M.
- Add at most one compact model if it wins the approved latency/RSS objective with acceptable WER.

### Increment 6 — quality/multilingual tier

- Benchmark Cohere Q4_K_M and, only if needed, Whisper Small.
- Add only if a named operator need justifies the disk/RSS/quality tradeoff.
- Never silently replace Parakeet Unified for existing users.

### Increment 7 — invocation and setup UX

- Push-to-talk/hands-free/cancel.
- Microphone selector/preview.
- Clipboard-preserving, app-aware delivery.

Each remains an independent slice with app-level trace proof.

## Final recommendation

The strongest Unramble-inspired Speakeasy is not “Unramble with fewer screens.” It is Speakeasy with:

- the same prepared, minimal capture hot path;
- recoverable and truthful delivery;
- stronger deterministic output quality;
- one bounded diagnostic story;
- streaming work moved under the recording window when benchmarks prove it;
- a small, evidence-backed model ladder:
  - **Default:** Parakeet Unified;
  - **Compact candidate:** Moonshine Streaming Small/Medium or Parakeet 110M;
  - **Quality/multilingual candidate:** Cohere Q4_K_M;
  - **Fallback:** last-known-good verified model.

The next move should be **baseline first, then Increment 1**, not adding a model directly to `ASRModelKind`.

## Verification performed during this research

- Speakeasy `swift test`: **100 passed, 0 failed**.
- Speakeasy `./script/test_benchmark.sh`: **20 passed across harness/worker tests, 1 real-model test ignored, 0 failed**; confirmed `transcribe-cpp 0.1.3` parity.
- No model-backed performance run was possible because the real fixture manifest/corpus and baseline result are absent.
- Unramble `make test` built and ran thousands of assertions with no observed failure, but did not terminate after roughly 14 minutes; it was stopped while its Swift Testing helper remained live, so this is **not** a clean-suite pass.
- `/tmp/unramble` remained an unmodified source clone during inspection.

## Licensing notes

- Unramble source is Apache-2.0. Adapted source must retain required license/attribution notices and mark modifications.
- Candidate model licenses differ: Cohere/Whisper Apache-2.0, Moonshine MIT, Parakeet CC-BY-4.0. Speakeasy must preserve model-specific attribution and redistribution obligations.
- Artifact availability, revision, bytes, and SHA-256 should be rechecked immediately before catalog implementation; the values above are research-time evidence, not a permanent supply-chain manifest.
