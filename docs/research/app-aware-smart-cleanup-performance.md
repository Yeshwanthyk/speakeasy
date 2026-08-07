# App-aware Smart Cleanup: scope and performance comparison

- Date: 2026-08-07
- Baseline commit: `921e44d718eaec3b8c684c632072742400d2cb3f`
- Candidate branch: `feat/app-aware-smart-cleanup`
- Megaphone reference: `5a9136b3ac8c766e24a5d79ac056df4d427968f1`
- Test Mac: Apple M4 Pro, 24 GiB RAM, macOS 26.6, Apple Intelligence available

## Verdict

The feature has two different performance results.

- **Exact and Basic do not have a meaningful regression.** The existing maximum-correction benchmark moved from 33.64 to 34.84 microseconds at p50. The processor source did not change. The 3.57% difference is small run-to-run noise and stays below the 10% gate.
- **Smart adds a clear wait after speech recognition.** The on-device model took 404.32 ms at p50 and 584.42 ms at p95 across 60 synthetic app-aware cleanups. The slowest request took 1.15 seconds. This passes the 1.5-second p95 goal and the 2.5-second hard deadline, but it is large relative to Speakeasy's current latency.
- The Smart benchmark had **zero fallbacks** and **zero required-anchor failures**. It preserved the names, numbers, versions, paths, and command terms checked by the fixtures.
- No work was added to the audio callback or ASR engine. Smart context capture and model prewarm start after recording begins. Exact and Basic do neither.

This result supports keeping all three modes. It does not support treating Smart as free. Smart should be a clear user choice unless the added formatting value proves worth about 0.4–0.6 seconds on typical requests.

## Complexity cost

Matching Megaphone's Smart Cleanup is not a small feature. The branch adds 1,882 net production-source lines, including 517 net lines in `AppCoordinator`. The coordinator grows from 1,498 to 2,015 lines. Tests, the benchmark, notices, and this report bring the full commit to 3,454 added lines and 63 removed lines.

The optimized app binary grows from 1,704,768 to 2,018,256 bytes: 313,488 bytes, or 18.39%. The app does not bundle a language model. Apple's model remains an operating-system service.

The implementation keeps this complexity outside the audio callback and behind three dedicated files, typed protocols, hard bounds, and focused tests. Even so, this is a real maintenance cost. If the real-use trial does not show a strong formatting gain, the simpler choice is to keep Basic and drop Smart rather than carry a large optional subsystem.

## What matches Megaphone

The candidate implements Megaphone's plain-dictation cleanup shape:

1. **Exact** returns the trimmed recognizer text.
2. **Basic** runs Speakeasy's current deterministic spoken commands and personal corrections.
3. **Smart** sends the raw recognizer text to Apple's on-device Foundation Models framework.
4. Smart captures the destination app name, bundle ID, focused window title, selected text, and up to 240 characters before the caret.
5. It classifies email, work chat, casual chat, document, code or terminal, and neutral writing.
6. It detects known Markdown surfaces separately.
7. It prewarms one model session while the user speaks.
8. It uses a 2.5-second deadline through 500 characters and 4 seconds above 500 characters.
9. It validates output and uses Basic on model, timeout, availability, or validation failure.

Speakeasy keeps stronger safety rules than Megaphone:

- Context is read from the PID and bundle captured when recording starts.
- Paste still checks that same target before posting Command-V.
- Secure text fields expose neither selection nor value to cleanup.
- Context and prompts are never stored or logged.
- Screen Recording and OCR are not used.
- Cancellation and shutdown suppress late model output.

## Baselines

### Existing installed-app diagnostics

The baseline contains 40 real local dictations. It is not a controlled corpus, but it describes current user-visible latency on this Mac.

| Metric | Samples | p50 | p95 |
|---|---:|---:|---:|
| Hotkey release to ASR text | 40 | 278.84 ms | 559.52 ms |
| Hotkey release to paste request | 35 | 327.26 ms | 606.37 ms |
| Hotkey press to capture start | 40 | 0.79 ms | 2.23 ms |

### Maximum deterministic correction pass

The optimized harness used all 128 supported corrections. Each of 10 processes handled 50,000 mixed transcripts. Both runs produced the same checksum.

| Metric | Baseline | Candidate | Change |
|---|---:|---:|---:|
| Time per transcript, p50 | 33.637 µs | 34.838 µs | +1.200 µs (+3.57%) |
| Time per transcript, p95 | 33.797 µs | 35.295 µs | +1.498 µs (+4.43%) |
| Throughput, p50 | 29,729/s | 28,705/s | -3.45% |
| Peak RSS, p50 | 6.703 MiB | 6.719 MiB | +0.016 MiB |

`Sources/TranscriptPostProcessor.swift` is unchanged. The result stays far below the 5 ms limit and shows no practical Exact or Basic cost from the new modules.

## Smart benchmark

The tracked benchmark uses six synthetic fixtures. They represent Mail, Slack, Messages, Obsidian, Terminal, and TextEdit. Ten repetitions produced 60 model requests. Results contain hashes and checks only. They do not contain transcript, context, prompt, or model-output text.

| Metric | Result |
|---|---:|
| Provider latency p50 | 404.32 ms |
| Provider latency p95 | 584.42 ms |
| Provider latency maximum | 1,146.04 ms |
| Prewarm call p50 | 0.342 ms |
| Prewarm call p95 | 0.413 ms |
| Prewarm call maximum | 4.697 ms |
| Fallbacks | 0 / 60 |
| Required-anchor failures | 0 / 60 |
| Client-process peak RSS | 22.16 MiB |

Category medians ranged from 347.31 ms for code or terminal to 576.69 ms for email. The email fixture also produced the 1.15-second maximum.

The Basic fixture process peaked at 11.98 MiB. The Smart client process therefore used about 10.17 MiB more in this small harness. Apple's language model can run in a separate system service. These RSS and CPU figures do **not** include that service, so they are lower bounds for total system cost.

A separate 18-request Smart run used 0.16 seconds of client user CPU and 0.04 seconds of client system CPU over 8.24 seconds of wall time. The client therefore spent roughly 11 ms of CPU per request, but the model service's CPU is not included.

## User-visible latency estimate

Smart is a serial step after ASR. A rough sum of the independent medians is:

- Current release-to-paste p50: 327.26 ms
- Smart provider p50: 404.32 ms
- Estimated combined p50: about 731.58 ms

A rough p95 sum is about 1.19 seconds. These sums are not a paired end-to-end measurement. The real values can differ because the installed-app samples used varied speech and the Smart benchmark used synthetic text. Prewarming also overlaps the recording period in the app.

The safe conclusion is narrower: Smart adds about **0.4 seconds at p50** and **0.58 seconds at p95** on this test set. Exact and Basic remain effectively unchanged.

## Correctness and compatibility proof

- Full Swift test suite: **239 passed, 0 failed**.
- App-aware focused suite: **99 passed, 0 failed**.
- Release Swift build passed.
- Signed app bundle build and verification passed.
- Built deployment target remains macOS 12.0.
- `FoundationModels.framework` is weak-linked.
- On macOS 12–25, or when Apple Intelligence is unavailable, Smart uses Basic fallback.
- No `AudioCapture` or Rust ASR code changed.

The test suite covers mode snapshots, target PID binding, Smart success, fallback, cancellation, shutdown, retry, timeout, stale completion, no Exact or Basic context/model work, and menu availability behavior.

## Limits of this measurement

- The 60 Smart runs used synthetic context. They did not test every live app's Accessibility behavior.
- Structural validation cannot prove that a language model preserved every meaning.
- The fixture anchors check selected important terms, not full semantic equivalence.
- Client-process RSS and CPU exclude Apple's out-of-process model service.
- No macOS 12 machine or VM was available. The binary target and weak link were inspected, but old-system launch still needs a real host test.
- The installed production app was not replaced with this branch.

## Recommendation before merge

Keep the branch for a short real-use trial. Compare Smart output against Basic in Mail, Slack, a document editor, and Terminal. Focus on whether the formatting gain is worth the measured 0.4–0.6 second wait.

If speed remains the first priority, make Basic the default and leave Smart as an explicit mode. If the output improvement is strong enough, keep Megaphone's Smart default. Do not merge until that product choice is made.

## Raw artifacts

Generated artifacts are Git-ignored under:

- `benchmarks/results/app-aware-2026-08-07/baseline/`
- `benchmarks/results/app-aware-2026-08-07/candidate-postprocess/`
- `benchmarks/results/app-aware-2026-08-07/candidate-basic-final.jsonl`
- `benchmarks/results/app-aware-2026-08-07/candidate-smart-final.jsonl`
- `benchmarks/results/app-aware-2026-08-07/candidate-smart-detail.json`

The repeatable tracked harness is:

- `benchmarks/smart-cleanup/fixtures.json`
- `benchmarks/smart-cleanup/main.swift`
- `script/benchmark_smart_cleanup.sh`
