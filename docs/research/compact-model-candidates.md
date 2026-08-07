# Compact speech model candidates

**Research date:** 2026-08-06

**Repository:** `wisp`, branch `perf/parakeet-benchmark-harness`

**Unramble revision:** [`1827c582b908f0bdd7fc566011b012e828413d17`](https://github.com/mrinalwadhwa/unramble/tree/1827c582b908f0bdd7fc566011b012e828413d17)

**Runtime under review:** local `transcribe-cpp` crate `0.1.3`, with Metal enabled in [`benchmarks/speech-bench/Cargo.toml`](../../benchmarks/speech-bench/Cargo.toml)

## Executive result

All six requested artifacts have public GGUF locations and are covered by the
locally installed `transcribe-cpp 0.1.3` model families for **batch** inference:

- `moonshine_streaming`: Small and Medium are native streaming candidates.
- `parakeet`: TDT+CTC 110M and TDT 1.1B are offline-only variants.
- `cohere`: Q4_K_M is supported for offline inference, but has a hard roughly
  400-second input limit and no native stream extension.
- `whisper`: Small Q4_K_M is supported for offline multilingual transcription,
  but transcribe.cpp explicitly marks Whisper as non-streaming.

The highest-value compact streaming experiment is Moonshine Streaming Small.
The lowest-risk compact batch experiment is Parakeet TDT+CTC 110M. Cohere is
the quality and language-coverage candidate, not a compact-memory candidate:
its Q4_K_M GGUF is about 1.56 GB and its Unramble streaming shape is a rolling
window of repeated batch calls, not a transcribe.cpp stream.

These are benchmark candidates, not approved application catalog entries.
Published WER and memory estimates below are screening evidence only. Wisp
still needs exact-artifact, same-host, same-corpus measurements before a model
can be promoted.

## Wisp and runtime contract

The current Wisp harness is already generic for batch model loading:

- [`transcribe_cpp_013.rs`](../../benchmarks/speech-bench/src/engine/transcribe_cpp_013.rs#L120-L246)
  resolves an arbitrary model path, hashes the file, loads it through
  `Model::load_with`, creates a session, and records the runtime architecture,
  variant, capabilities, device, and post-load free memory.
- The batch path calls `Session::run` with borrowed `&[f32]` PCM and does not
  contain Parakeet-specific inference code despite the `ParakeetEngine` type
  name ([same file](../../benchmarks/speech-bench/src/engine/transcribe_cpp_013.rs#L257-L284)).
- The existing stream path checks `supports_streaming`, begins one native stream,
  feeds 16 kHz chunks, finalizes, and records first-hypothesis, first-commit,
  feed, and release-to-final timings ([same file](../../benchmarks/speech-bench/src/engine/transcribe_cpp_013.rs#L286-L384)).
- `native_stream_options` currently exposes only Parakeet cache-aware and
  buffered extensions. `StreamFamily::Auto` passes no family extension
  ([same file](../../benchmarks/speech-bench/src/engine/transcribe_cpp_013.rs#L436-L494)).
- The current stream adapter requires committed text to remain append-only
  ([same file](../../benchmarks/speech-bench/src/engine/transcribe_cpp_013.rs#L323-L335)).
  The transcribe.cpp 0.1.3 streaming tests explicitly warn that re-attending
  models such as Moonshine can revise the best-effort committed prefix; `full`
  is authoritative ([crate streaming test](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/tests/streaming.rs#L56-L64)).

The installed `transcribe-cpp-sys 0.1.3` build includes `arch/cohere`,
`arch/moonshine_streaming`, `arch/parakeet`, and `arch/whisper` in its CMake
source list ([v0.1.3 CMake source list](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/transcribe-cpp-sys/src/CMakeLists.txt#L36-L87)).
The Rust API exposes `MoonshineStreaming`, `ParakeetStream`, and
`ParakeetBuffered` stream extensions, but no Cohere or Whisper stream extension
([v0.1.3 family options](https://github.com/handy-computer/transcribe.cpp/blob/v0.1.3/transcribe-cpp/src/family.rs#L36-L78)).

## Exact artifacts and screening matrix

The byte counts are from the Hugging Face model APIs on the research date. The
revision pins are the current commit of each public GGUF repository. The links
target the exact file and revision.

| Candidate | Exact GGUF location and revision | File bytes | Model license | Native transcribe.cpp streaming | Planning memory envelope* | Adapter work in Wisp |
|---|---|---:|---|---|---:|---|
| Moonshine Streaming Small Q8_0 | [`handy-computer/moonshine-streaming-small-gguf/moonshine-streaming-small-Q8_0.gguf`](https://huggingface.co/handy-computer/moonshine-streaming-small-gguf/blob/41444173ed8210852a883e046fadcfba3e7bfbae/moonshine-streaming-small-Q8_0.gguf), revision `41444173ed8210852a883e046fadcfba3e7bfbae` | 198,506,848 | MIT | Yes; 80 ms feed cadence, about 240 ms cumulative encoder right-context, 20 ms emit unit | 0.3–0.5 GB | Batch: catalog/config only. Stream: add a Moonshine stream-family option or use defaults, and remove the unconditional append-only committed-prefix assumption. |
| Moonshine Streaming Medium Q8_0 | [`handy-computer/moonshine-streaming-medium-gguf/moonshine-streaming-medium-Q8_0.gguf`](https://huggingface.co/handy-computer/moonshine-streaming-medium-gguf/blob/c722a9455a40a1844c3d25267dc84eff61d8dd84/moonshine-streaming-medium-Q8_0.gguf), revision `c722a9455a40a1844c3d25267dc84eff61d8dd84` | 295,793,568 | MIT | Yes; same family contract | 0.4–0.7 GB | Same stream changes as Small. Add a degeneration/truncation assertion to the benchmark gate: the upstream/runtime doc records one known repeated-digit decode loop for Medium. |
| Parakeet TDT+CTC 110M Q8_0 | [`handy-computer/parakeet-tdt_ctc-110m-gguf/parakeet-tdt_ctc-110m-Q8_0.gguf`](https://huggingface.co/handy-computer/parakeet-tdt_ctc-110m-gguf/blob/9d66d34f9e1594075c5dd72c90c0f4c321b29f21/parakeet-tdt_ctc-110m-Q8_0.gguf), revision `9d66d34f9e1594075c5dd72c90c0f4c321b29f21` | 135,373,280 | CC-BY-4.0 | No; offline-only | 0.2–0.4 GB | Batch: catalog/config only. The hybrid checkpoint defaults to TDT. Selecting its CTC head would require a transcribe.cpp/runtime option that the current Rust adapter does not expose. |
| Cohere Transcribe 03-2026 Q4_K_M | [`handy-computer/cohere-transcribe-03-2026-gguf/cohere-transcribe-03-2026-Q4_K_M.gguf`](https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/blob/dfa4adebb64f3076b7b6b90b721275cc069cb421/cohere-transcribe-03-2026-Q4_K_M.gguf), revision `dfa4adebb64f3076b7b6b90b721275cc069cb421` | 1,558,162,944 | Apache-2.0 | No; no Cohere stream extension and roughly 400 s per-call input ceiling | 1.8–2.4 GB | Batch: catalog/config only. Streaming would be a new rolling-window session/assembler above repeated batch `run` calls, with explicit overlap reconciliation and 400 s splitting. |
| Parakeet TDT 1.1B Q8_0 | [`handy-computer/parakeet-tdt-1.1b-gguf/parakeet-tdt-1.1b-Q8_0.gguf`](https://huggingface.co/handy-computer/parakeet-tdt-1.1b-gguf/blob/8c21810615694c53a4f4745996190fcca880f8e5/parakeet-tdt-1.1b-Q8_0.gguf), revision `8c21810615694c53a4f4745996190fcca880f8e5` | 1,267,288,736 | CC-BY-4.0 | No; offline-only | 1.5–2.0 GB | Batch: catalog/config only. Preserve its lowercase/no-punctuation output contract in scoring and do not request streaming. |
| Whisper Small Q4_K_M | [`handy-computer/whisper-small-gguf/whisper-small-Q4_K_M.gguf`](https://huggingface.co/handy-computer/whisper-small-gguf/blob/c0214bd34be9296695486f838e0142f900803159/whisper-small-Q4_K_M.gguf), revision `c0214bd34be9296695486f838e0142f900803159` | 171,630,656 | Apache-2.0 on the first-party HF model card | No; transcribe.cpp uses 30-second chunking, not live stream | 0.3–0.5 GB | Batch: catalog/config only for transcription. Language selection and segment timestamps are supported; translation and Whisper-specific decode options need separate API/config work. |

\* The envelope is an engineering planning estimate, not an observed Wisp
measurement or a vendor guarantee. It starts with the exact GGUF size and adds
decoder/session/backend working space. The promotion measurement must use the
harness's recorded `memory_free_after_load` and `memory_total`, plus process
RSS if available. Do not compare these estimates as benchmark results.

### Candidate-specific source facts

#### Moonshine Streaming Small and Medium

The first-party Useful Sensors model card identifies an English-only
sequence-to-sequence model with a streaming sliding-window encoder and an
autoregressive decoder. It lists Small as 123M parameters and Medium as 245M,
with intended use on constrained edge devices and a sub-1 GB memory budget
([Small card](https://huggingface.co/moonshine-ai/moonshine-streaming-small#model-details),
[Medium card](https://huggingface.co/moonshine-ai/moonshine-streaming-medium#model-details)).
The same card warns that decoder latency grows with output length and that
hallucinated/repeated text is a known limitation ([card limitations](https://huggingface.co/moonshine-ai/moonshine-streaming-small#known-limitations)).

The transcribe.cpp family docs provide the runtime-specific contract: Q8_0
screening sizes are 189 MB / 2.54% LibriSpeech test-clean WER for Small and
282 MB / 2.16% for Medium; both support
`transcribe_stream_begin`/`feed`/`finalize`, but only English transcription and
no timestamps, VAD, translation, or language detection ([Small runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/moonshine-streaming-small.md#capabilities),
[Medium runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/moonshine-streaming-medium.md#capabilities)).
The runtime docs also state that Medium has a known upstream repeated-digit
non-termination case, bounded by an output truncation error
([Medium runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/moonshine-streaming-medium.md#download)).

**Decision:** benchmark Small first for the compact streaming tier; benchmark
Medium as the quality/latency tradeoff, with truncation counted as failure.
The current Wisp stream metrics need a Moonshine-specific committed/full-text
policy before a pass/fail result is trustworthy.

#### Parakeet TDT+CTC 110M Q8_0

NVIDIA's first-party card lists the hybrid FastConformer encoder with TDT and
CTC heads and CC-BY-4.0 licensing ([model card](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m)).
The transcribe.cpp port uses TDT by default, exposes timestamps, and explicitly
marks this model as offline-only. Its Q8_0 GGUF is 135 MB and its published
transcribe.cpp LibriSpeech test-clean result is 2.43% WER ([runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-tdt_ctc-110m.md#what-its-for)).

**Decision:** this is the cleanest compact batch baseline. Benchmark TDT first.
Only add CTC selection if the experiment needs a head-to-head comparison; the
current `RunOptions`/`StreamOptions` surface has no Parakeet decoder-head
selector.

#### Cohere Transcribe 03-2026 Q4_K_M

Cohere's first-party card describes a 2B conformer encoder plus Transformer
decoder, 14 languages, 16 kHz audio input, and Apache-2.0 licensing
([model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026#model-details)).
The transcribe.cpp port lists Q4_K_M at 1.55 GB and 1.25% LibriSpeech
test-clean WER, with a roughly 400-second input ceiling due to the encoder
position table ([runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/cohere-transcribe-03-2026.md#download)).
The port is numerically validated against the Transformers reference, so this
is a viable GGUF batch candidate without adopting MLX
([validation contract](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/cohere-transcribe-03-2026.md#numerical-validation)).

**Decision:** include as a quality/multilingual batch comparison, not as a
compact-memory or native-stream candidate. A live UX experiment must either
accept 30-second-plus release work or implement a separate rolling recognizer.

#### Parakeet TDT 1.1B Q8_0

NVIDIA's first-party card describes an approximately 1.1B-parameter English
FastConformer TDT model and marks it CC-BY-4.0 ([model card](https://huggingface.co/nvidia/parakeet-tdt-1.1b)).
The transcribe.cpp port reports lowercase, unpunctuated offline output; Q8_0
is 1.27 GB and the port's LibriSpeech test-clean result is 1.38% WER
([runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-tdt-1.1b.md#what-its-for)).

**Decision:** benchmark only if the corpus shows that its quality improvement
justifies the memory/load cost. It is a useful quality ceiling, not a compact
tier.

#### Whisper Small Q4_K_M

The first-party OpenAI model card lists Whisper Small as a multilingual
encoder-decoder model trained on 680k hours, with Apache-2.0 licensing on the
HF checkpoint ([model card](https://huggingface.co/openai/whisper-small)).
The transcribe.cpp port supports 99-language auto-detection, translation on
multilingual checkpoints, segment timestamps, and long audio via 30-second
windows. It explicitly says real-time streaming is not supported. Q4_K_M is
listed at 164 MB / 3.40% WER in the port's publication table; the exact current
GGUF file is 171,630,656 bytes ([runtime doc](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/whisper-small.md#capabilities)).

**Decision:** keep as the multilingual compact batch control. Do not use it as
the streaming control. The current Wisp task enum only exposes transcription,
so translation should not be inferred from the artifact's capability.

## What Unramble actually does

Unramble's local composition wires `CohereMLXEngine` into
`LocalStreamingProvider`; it does not load the Cohere GGUF through
transcribe.cpp ([pinned composition](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/DictationCompositionFactory.swift#L34-L93)).
Its model script downloads a pinned MLX Safetensors pack from
`beshkenadze/cohere-transcribe-03-2026-mlx-4bit`, alongside a Qwen formatter
and adapters ([pinned model script](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/scripts/models.sh#L10-L27)).
The Qwen adapter is a list-formatting model; it is not an ASR candidate.

The Cohere MLX engine uses a serialized `generate` call with `maxTokens: 2048`
and a forced English language hint ([pinned engine](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Engines/CohereMLXEngine.swift#L51-L71)).
Its recognition session is a rolling batch algorithm: 30-second windows,
25-second stride, 5-second overlap, and a special short-tail re-run that
attaches a small tail to the last full window ([pinned engine](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Engines/CohereMLXEngine.swift#L167-L231)).

The provider accumulates PCM, feeds incremental recognition work on a cycle,
keeps partial text internal, and returns one final transcript for one injection
([pinned provider](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/LocalStreamingProvider.swift#L3-L16)).
It rejects/reports stale generations, avoids feeding sustained silence, and
finishes the admitted tail before returning ([provider lifecycle](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Sources/UnrambleKit/Services/LocalStreamingProvider.swift#L508-L633)).
The tests prove 30-second/25-second window advancement, overlap preservation,
short-tail behavior, dense-output rejection, and repeated-decoder-loop
rejection ([rolling-session tests](https://github.com/mrinalwadhwa/unramble/blob/1827c582b908f0bdd7fc566011b012e828413d17/UnrambleKit/Tests/UnrambleKitTests/CohereRollingRecognitionSessionTests.swift#L5-L113)).

This is a valuable orchestration pattern for a future Cohere experiment, but it
is not evidence that Cohere has native streaming support in transcribe.cpp.

## Adapter work summary

| Work item | Required for batch benchmark? | Required for native streaming benchmark? |
|---|---:|---:|
| Add exact GGUF path, pinned revision, expected byte count, and SHA-256 to the benchmark fixture/config | Yes | Yes |
| Run generic `Model::load_with` / `Session::run` and record architecture, variant, capabilities, and memory | Already present; verify with each artifact | Already present |
| Moonshine family option for `min_decode_interval_ms` | No | Recommended; current `Auto` defaults work, but cadence is not configurable |
| Moonshine full-vs-committed text policy | No | Required; current append-only assertion can reject valid re-attending behavior |
| Parakeet TDT+CTC decoder-head selector | No for default TDT | Not applicable; the model is offline-only |
| Cohere rolling-window/overlap assembler | No | Required for a live experiment; not a native transcribe.cpp stream |
| Whisper language/translation options | No for transcription | Not applicable; runtime is offline-only |
| New model-specific native loader | No | No; all requested architectures are already compiled into local 0.1.3 |

The first benchmark slice should therefore be configuration plus artifact
verification, not a new engine. Keep batch and stream results in separate
gates. For Moonshine, compare final `full` text against batch text and treat
the committed prefix as telemetry unless the adapter learns the model-specific
reconciliation contract.

## License handling

The model licenses above are the licenses shown by the first-party Hugging Face
model cards or the transcribe.cpp model documentation. They are separate from
the runtime license: transcribe.cpp itself is MIT ([runtime license](https://github.com/handy-computer/transcribe.cpp/blob/main/LICENSE)).
Before shipping an artifact, preserve the model license and attribution in the
app's model attribution bundle. Do not infer that the MIT runtime changes the
license of NVIDIA, Cohere, Moonshine, or OpenAI model weights.

## Recommended wave-1 order

1. **Moonshine Streaming Small Q8_0** — smallest native-stream candidate and
   the best test of whether streaming reduces release-to-final latency within a
   sub-GB planning envelope.
2. **Parakeet TDT+CTC 110M Q8_0** — smallest simple batch candidate and a useful
   low-memory/low-latency control.
3. **Moonshine Streaming Medium Q8_0** — quality upgrade over Small, gated on
   its known decoder-loop/truncation behavior and larger decode cost.
4. **Whisper Small Q4_K_M** — multilingual batch control; no live-stream claim.
5. **Parakeet TDT 1.1B Q8_0** — quality ceiling, but not compact.
6. **Cohere Transcribe 03-2026 Q4_K_M** — multilingual quality candidate; use
   batch first and only build rolling streaming after the batch result justifies
   the roughly 1.56 GB artifact and added assembler complexity.

## Proof still required

This note establishes source compatibility and adapter shape. It does not prove
Wisp runtime performance, RSS, thermal behavior, accuracy on the Wisp corpus,
or browser/deployed behavior. For each exact file, the next proof should:

1. download the pinned GGUF and verify byte count plus SHA-256;
2. run the existing worker in a cold process and retained-session mode;
3. record `architecture`, `variant`, `supports_streaming`, effective session
   limits, backend, load time, and post-load free memory;
4. score batch text against the same corpus and normalization;
5. for Moonshine only, run the native stream path after its committed/full-text
   policy is made model-aware, then compare final stream text to batch text;
6. count input-too-long, output-truncated, load, and stream-contract failures
   separately from WER.
