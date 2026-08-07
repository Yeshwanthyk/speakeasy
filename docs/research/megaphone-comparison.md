# Megaphone → Speakeasy: transferable ideas without sacrificing latency or simplicity

**Research date:** 2026-08-06
**Megaphone revision inspected:** [`5a9136b3ac8c766e24a5d79ac056df4d427968f1`](https://github.com/Kuberwastaken/megaphone/tree/5a9136b3ac8c766e24a5d79ac056df4d427968f1)
**Speakeasy revision compared:** [`dd4d5d03509392fbe7b29ca5db86abc495cf4b71`](https://github.com/Yeshwanthyk/speakeasy/tree/dd4d5d03509392fbe7b29ca5db86abc495cf4b71)

## Executive summary

Megaphone's best transferable ideas are not its large settings surface or its central `AppState`. They are four narrow mechanisms:

1. **Do optional work during speech, never after it if it can be avoided.** Megaphone begins streaming recognition and prewarms its cleanup model when recording starts, then imposes a short cleanup deadline with a deterministic fallback.
2. **Separate recognition hints from exact corrections.** Dictionary terms bias recognition; deterministic `heard -> written` mappings repair stubborn output afterward.
3. **Keep bounded, inspectable run records.** Megaphone's 20-entry local run log preserves raw/final text, outcome, context, settings, and optional audio, enabling retry and test-case export.
4. **Make learned behavior conservative and reversible.** Terms require three observations before activation, have caps, can be enabled/starred/rejected, and remain local.

Speakeasy should adopt these as small independent layers around its existing hot path. It should **not** copy Megaphone's 3,755-line state owner, per-dictation capture-session construction, Core Data history, synchronous audio copies, or dual per-buffer conversions. Speakeasy already has a stronger minimal core: a prepared audio engine with pre-roll, retained GGUF session, zero-copy native handoff, explicit state machine, asynchronous history writes, and detailed latency traces ([architecture](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/ARCHITECTURE.md#L1-L50)).

## What was inspected

This report is based on Megaphone's source rather than its marketing claims. The main execution path was traced through:

- [`App.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/App.swift#L1-L25) and [`AppDelegate.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppDelegate.swift#L1-L71)
- [`AppState.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L215-L265), especially recording, recognition, cleanup, persistence, and paste
- [`AudioRecorder.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L71-L124) and [`SpeechAnalyzerService.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SpeechAnalyzerService.swift#L108-L168)
- [`AppleFoundationModelsPostProcessor.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppleFoundationModelsPostProcessor.swift#L271-L321), [`TranscriptTidier.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/TranscriptTidier.swift#L1-L96), and [`DictionaryStore.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L1-L74)
- [`PipelineHistoryItem.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/PipelineHistoryItem.swift#L1-L75), [`PipelineHistoryStore.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/PipelineHistoryStore.swift#L1-L80), and the run-log UI in [`SettingsView.swift`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SettingsView.swift#L1635-L1838)
- Build and compatibility handling in the [`Makefile`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Makefile#L1-L113)

## Architecture

### Megaphone's execution shape

```text
shortcut / mouse / menu
        │
        ▼
AppState (session state + orchestration + most settings)
        │
        ├── AudioRecorder ──► 16 kHz WAV ───────────────┐
        │        └──────► 24 kHz PCM chunks             │ fallback
        │                         │                      │
        │                         ▼                      ▼
        │             SpeechAnalyzerStreamingSession   file analysis
        │                         └──────────┬───────────┘
        │                                    ▼
        ├── captured app/caret context ─► raw transcript
        │                                    │
        ├── exact / basic deterministic cleanup
        │                                    │
        ├── optional Foundation Models cleanup/command
        │                                    │
        └── paste + bounded run log + optional saved audio
```

The app shell is a SwiftUI `MenuBarExtra` backed by an `AppDelegate`, while `AppState` owns the recorder, hotkey manager, overlay, context service, history store, session tasks, and published UI state ([app shell](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/App.swift#L3-L17), [owned services/state](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L612-L685)). This is effective for shipping a feature-rich app quickly, but it couples unrelated concerns and makes the main orchestration file 3,755 lines. It is not a shape Speakeasy should emulate.

When recording starts, Megaphone starts its streaming speech session, creates an ID for a cleanup session, prewarms Foundation Models when needed, and starts microphone capture off the main thread ([record-start overlap](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2285-L2376)). At stop, it first attempts to commit the streaming transcript and falls back to whole-file analysis if setup or streaming failed ([fallback order](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2860-L2888)). It then runs command/macro handling or cleanup, persists a run record, and pastes the result ([pipeline completion](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2970-L3128)).

### Speakeasy's current shape

Speakeasy is narrower and has cleaner boundaries:

- `AppCoordinator` explicitly owns `idle -> startingCapture -> recording -> transcribing(token) -> idle`, with a separate model warmup state ([state definitions](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/AppCoordinator.swift#L39-L104)).
- `AudioCapture` is prepared before use; `AppCoordinator` stops it and runs inference on a user-interactive serial queue rather than the main thread ([prepare/warmup](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/AppCoordinator.swift#L176-L210), [stop path](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/AppCoordinator.swift#L474-L583)).
- The retained Rust session receives a borrowed pinned `[Float]` buffer through a small synchronous ABI ([Swift boundary](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/TranscribeCppTranscriber.swift#L67-L87), [Rust borrowed slice](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/rust/asr_bridge/src/lib.rs#L123-L166)).
- `TranscriptStore` is a 50-item JSON ring whose writes happen on a utility serial queue, explicitly outside the paste hot path ([store](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/TranscriptStore.swift#L1-L73)).

**Implication:** extend Speakeasy by adding small protocols/value types at its existing boundaries. Do not replace the coordinator with a broad observable state object.

## Asset handling

### Speech/model assets

Megaphone delegates model inventory to Apple's Speech framework. It:

1. resolves the requested locale against `SpeechTranscriber.supportedLocales`;
2. asks `AssetInventory` for an installation request only when the locale is absent;
3. downloads/installs through that request;
4. releases reservations for stale locales and reserves the current locale;
5. continues if reservation fails but installed assets remain usable.

This behavior is all in [`SpeechAnalyzerService.ensureAssets`](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SpeechAnalyzerService.swift#L136-L168). `SpeechModelManager` exposes `unknown`, unavailable, unsupported, needs-download, downloading, installed, and failed states to setup/settings ([status model](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SpeechAnalyzerService.swift#L480-L578)). The application does not own model filenames, revisions, checksums, or promotion.

Speakeasy necessarily owns more because its GGUF files come from Hugging Face. Its catalog pins repository revision, byte count, and SHA-256 ([artifact catalog](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/ModelPathResolver.swift#L97-L132)); installation stages the file, verifies size and checksum, and atomically replaces/promotes it ([installer](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/ASRModelInstaller.swift#L46-L120)). Megaphone offers no safer or simpler transferable replacement for this. Speakeasy should keep its current verified catalog.

**Transferable part:** adopt Megaphone's *observable lifecycle vocabulary* for model UI—checking, download required, downloading, verifying/warming, ready, failed—without changing Speakeasy's ownership or integrity checks.

### Audio assets and history retention

Megaphone writes a normalized 16 kHz WAV during every recording while separately emitting 24 kHz PCM chunks for streaming recognition ([dual outputs](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L92-L124), [file write](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L343-L415), [stream emission](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L806-L851)). Finished audio is copied under Application Support and linked from a history row; trimming/deleting history also removes the corresponding audio ([audio persistence](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L1049-L1146), [bounded append](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L3204-L3244)).

This enables replay and retry, but Speakeasy should not persist audio by default. It changes the privacy/storage contract and adds disk I/O. If debugging requires it, use an **opt-in diagnostic capture** with an explicit byte/time quota and asynchronous move, not a permanent part of every successful dictation.

### Bundle assets

Megaphone's build is intentionally dependency-light: `swiftc` compiles source files directly, the bundle copies one selected `.icns`, and the DMG uses checked-in artwork ([build inputs](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Makefile#L1-L38), [bundle assembly](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Makefile#L79-L104)). A macOS 13-compatible launcher execs a macOS 26 core so unsupported systems can show a useful message rather than fail at launch ([launcher/core split](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Makefile#L19-L24)). This compatibility shim is only relevant if Speakeasy later adopts APIs newer than its minimum deployment target.

## Implemented UX and features

Megaphone implements substantially more product surface than Speakeasy:

| Area | Megaphone implementation | Relevance to Speakeasy |
|---|---|---|
| Invocation | Customizable hold and toggle shortcuts, mouse button, cancel, menu action | **High:** hold-to-talk is useful, but add only after preserving Speakeasy's state-machine invariants. |
| Feedback | Recording/transcribing overlay, live level, sounds, delayed “initializing” state | **Medium:** the delayed initializing indicator is good; it avoids flashing transient states ([timer](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2293-L2334)). |
| Recovery | Cancel, paste again, revert cleaned text to raw, “scratch that,” retry failed run | **High:** paste again and raw/final history are cheap and useful; audio retry is heavier. |
| Recognition | Streaming SpeechAnalyzer, locale picker, dictionary hints | Architecture-specific; dictionary/correction concepts transfer. |
| Cleanup | Exact, deterministic Basic, deadline-bounded Smart cleanup | **High:** deterministic correction is the safest first slice. |
| Commands | Voice macros, selected-text edit mode, wake phrase, named transforms, screen context | **Low initially:** valuable but expands permission, state, safety, and latency concerns. |
| Clipboard/paste | Preserve clipboard, optional clipboard-history behavior, delayed paste/Enter | **Medium:** independent quality-of-life work, not ASR architecture. |
| Setup/settings | Permission wizard, microphone selection, model status, updater | **Medium:** model progress and microphone selection are more relevant than the full settings app. |
| History | Menu snippets plus detailed local run log | **High if kept bounded and lightweight.** |

The menu exposes start/stop, paste again, cleanup revert, recent history, one-click dictionary addition, shortcut selection, microphone selection, setup/settings, and update controls ([menu implementation](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/MenuBarView.swift#L100-L365)). This breadth is informative, but Speakeasy's sparse lazy-built menu is a deliberate performance/simplicity advantage ([Speakeasy menu](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/MenuBarController.swift#L1-L18), [lazy rebuild](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/MenuBarController.swift#L76-L145)). Prefer one submenu or one small settings window over progressively crowding the menu.

## Dictionary and exact-correction extensibility

Megaphone has a useful two-layer model.

### Layer 1: recognition and cleanup vocabulary

A `DictionaryEntry` tracks stable ID, term, manual/learned source, suggested/active/rejected status, enabled state, observation count, star, usage count, and timestamps ([entry schema](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L1-L74)). Active terms are ranked starred-first, then by usage, then alphabetically before being projected into newline-delimited hints ([ranking/projection](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L66-L74), [active terms](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L175-L183)). Those terms feed both the SpeechAnalyzer `AnalysisContext` and the cleanup prompt ([speech context](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SpeechAnalyzerService.swift#L108-L129), [cleanup hint](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppleFoundationModelsPostProcessor.swift#L751-L804)).

Learning is conservative: a term activates after three observations; non-rejected learned entries are capped at 300 and suggestions at 100; rejected terms suppress re-suggestion; candidate extraction favors acronyms, internal capitals, numbers, technical separators, and mid-sentence names ([thresholds/caps](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L139-L143), [observation logic](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L294-L336), [candidate learner](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L477-L536)). Import/export is local JSON and merges rather than replacing local entries ([document](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L88-L131), [merge](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L339-L425)).

### Layer 2: deterministic exact correction

Separate text mappings accept `spoken -> replacement`, `spoken => replacement`, or a Unicode arrow. Parsing ignores comments/malformed entries and deduplicates the spoken side. Application is case/diacritic insensitive, matches whole boundaries, prefers longer phrases, and runs as part of deterministic cleanup ([parser and application](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/TranscriptTidier.swift#L8-L96)).

### Recommended Speakeasy shape

Start with exact corrections, not automatic learning:

```swift
struct TranscriptCorrection: Codable, Identifiable, Sendable {
    let id: UUID
    var heard: String
    var written: String
    var isEnabled: Bool
}

protocol TranscriptPostProcessing: Sendable {
    func process(_ transcript: String) -> String
}
```

- Parse and compile enabled mappings when settings change, **not per dictation**.
- Apply one deterministic pass after hallucination filtering and before history/paste.
- Persist a small versioned JSON file on a utility queue, matching `TranscriptStore`'s current behavior.
- Keep recognition hints behind a separate `RecognitionHintsProviding` boundary. Speakeasy's current C ABI always uses `RunOptions::default()` ([bridge](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/rust/asr_bridge/src/lib.rs#L155-L166)); do not promise model bias until transcribe.cpp and each selected model are proven to support it consistently.
- Add learning only after there is a correction/edit signal. Learning from ASR's own final output, as Megaphone does, can reinforce recognition mistakes despite its threshold.

This keeps the normal cost to a bounded in-memory text transformation and no additional model invocation.

## History, stats, and testability

### What Megaphone implements

Megaphone persists at most 20 runs in a programmatically defined Core Data store. A row records intent, selection, timestamp, raw/final transcript, prompts, context, statuses, vocabulary, optional audio filename, and destination-app metadata ([record schema](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/PipelineHistoryItem.swift#L3-L75), [Core Data model](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/PipelineHistoryStore.swift#L278-L343)). The run-log UI can expand pipeline stages, play audio, copy raw/final text, retry failed transcription, delete, and export a case ([run entry](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SettingsView.swift#L1689-L2039)). Export produces a ZIP containing JSON plus available audio/screenshot assets ([exporter](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/TestCaseExporter.swift#L1-L152)).

This is a strong debugging/evaluation loop: a bad dictation can become a reproducible fixture without searching logs.

Megaphone does **not** implement a general aggregate stats dashboard. It stores cleanup/command elapsed time inside human-readable status strings and exposes dictionary observation/usage counts ([status formatting](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2588-L2628), [usage count](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/DictionaryStore.swift#L236-L249)). It does not provide structured p50/p95 capture or release-to-paste metrics.

### Better minimal evolution for Speakeasy

Speakeasy already has the more useful performance substrate: `TranscriptionTrace` captures press-to-capture, release-to-stop, inference, and release-to-paste timings, and debug builds aggregate p50/p95 values ([trace fields/logging](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/TranscriptionTrace.swift#L3-L151), [debug summary](https://github.com/Yeshwanthyk/speakeasy/blob/dd4d5d03509392fbe7b29ca5db86abc495cf4b71/Sources/TranscriptionTrace.swift#L162-L199)). Preserve and extend that rather than adopting Megaphone's string statuses.

A small next step is to version `TranscriptStore` from `[String]` to `[TranscriptRecord]`:

```swift
struct TranscriptRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let rawText: String
    let finalText: String
    let model: String
    let outcome: Outcome
    let timings: Timings?
}
```

Recommended constraints:

- Keep the current 50-item ring and utility-queue atomic JSON write.
- Make migration from `[String]` explicit and lossless.
- Keep transcripts local and add no analytics/network service.
- Do not persist audio by default.
- Store numeric timings, not formatted strings, so local p50/p95 remains possible.
- Add “Copy raw,” “Copy final,” and “Export diagnostic JSON” before building a full settings/run-log UI.
- If test-case audio is needed, offer a one-run “Retain next recording for diagnostics” control.

This captures Megaphone's reproducibility benefit without Core Data, audio retention, or a large UI layer.

## Performance tradeoffs

### Ideas worth copying

1. **Overlap setup with speech.** Megaphone starts streaming recognition and cleanup prewarm before capture completes ([start overlap](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2340-L2376)). Speakeasy already overlaps capture preparation and model warmup at launch; future optional work should follow the same principle.
2. **Deadline + deterministic fallback.** Smart cleanup gets 2.5 seconds for ordinary text and 4 seconds for long text; failures return deterministic output instead of blocking/failing dictation ([policy](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2822-L2856)). The response/timeout race is cancellation-aware ([race](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppleFoundationModelsPostProcessor.swift#L712-L748)).
3. **Delay transient loading UI.** Megaphone only shows initializing state after 200 ms, avoiding visual churn on fast starts ([timer](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2293-L2312)).
4. **Bound every adaptive collection.** History, learned terms, suggestions, prompt vocabulary, and recent-text windows all have caps. This controls storage, prompt cost, and search time.
5. **Deterministic routing before model routing.** Voice macros and named transforms are exact normalized matches rather than an extra classifier call ([transform matching](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/TransformStore.swift#L21-L92)).

### Ideas not to copy

1. **Cold capture graph per dictation.** Megaphone constructs and starts an `AVCaptureSession` in `startRecording` and tears it down at stop ([session creation/start](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L567-L670), [stop](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L676-L693)). Speakeasy's already-prepared engine, pre-roll, and adaptive stop grace are better for capture-start and end-of-speech latency.
2. **Multiple per-buffer conversions/copies.** Megaphone converts capture audio for its 16 kHz file, converts again to 24 kHz `Data`, then copies and converts those chunks again into SpeechAnalyzer's preferred format ([24 kHz allocation](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AudioRecorder.swift#L806-L851), [analyzer copy/conversion](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/SpeechAnalyzerService.swift#L428-L467)). If Speakeasy later gains streaming GGUF support, feed one canonical capture representation into the engine rather than reproducing this chain.
3. **Synchronous audio copy on the stop path.** Megaphone copies the temporary WAV into Application Support before launching the main transcription task ([call site](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L2938-L2950), [copy](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/AppState.swift#L1100-L1118)). Speakeasy should keep diagnostic persistence off the release-to-text path.
4. **Synchronous Core Data setup and `performAndWait`.** Megaphone synchronously loads/rebuilds its persistent store and uses a synchronous view context ([store initialization](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/PipelineHistoryStore.swift#L4-L60), [synchronous loader](https://github.com/Kuberwastaken/megaphone/blob/5a9136b3ac8c766e24a5d79ac056df4d427968f1/Sources/PipelineHistoryStore.swift#L236-L263)). Speakeasy's bounded JSON snapshot is sufficient.
5. **Optional model cleanup in the mandatory path.** Megaphone mitigates this with a deadline, but even 2.5 seconds is large relative to Speakeasy's low-latency goal. If semantic cleanup is ever added, make it opt-in and consider pasting deterministic output first rather than delaying all text.

## Recommended adoption order

### 1. Exact Corrections — adopt

Smallest, highest-confidence feature. Add versioned local mappings and a precompiled deterministic postprocessor between accepted ASR output and `TranscriptStore`/paste. Add boundary, phrase-order, case, Unicode, malformed-input, and no-op tests. Expected latency impact should be negligible and measurable with existing `TranscriptionTrace`.

### 2. Structured transcript records — adopt

Evolve the existing JSON ring to hold raw/final text, model, outcome, and numeric timings. Keep asynchronous atomic writes. Add raw/final copy and JSON export; avoid Core Data and audio retention.

### 3. Manual dictionary terms — evaluate per model

Add the store/UI independently, but only connect terms to inference after confirming a stable transcribe.cpp `RunOptions` capability across Parakeet Unified, Parakeet TDT, and Nemotron. Until then, dictionary terms can power exact corrections or a future postprocessor without pretending to bias recognition.

### 4. Local aggregate stats — adopt from existing traces

Persist or aggregate only numeric operational data already captured: count, success/no-speech/error outcomes, capture-start p50/p95, release-to-text p50/p95, and model. Keep it local and bounded. Megaphone does not offer a better stats mechanism than Speakeasy already has.

### 5. Learned suggestions — defer

Only learn from explicit user corrections, accepted replacements, or repeated mismatch evidence. Do not infer correctness solely from ASR output. Preserve suggested/active/rejected states and caps if this is eventually built.

### 6. Streaming inference / semantic cleanup / command mode — defer behind benchmarks

These can improve experience, but they are different architectural projects. Require before/after latency distributions, memory/energy measurements, cancellation behavior, and fallback proof. Do not let them complicate the deterministic dictation path.

## Key conclusions

- **Megaphone validates overlap and fallback as the core latency pattern:** stream/prewarm during speech; deadline optional work; always retain a boring deterministic result.
- **Speakeasy should keep its existing capture and native inference architecture.** Its prepared engine, pre-roll, retained session, zero-copy ABI, and structured traces are better aligned with low latency than Megaphone's per-recording capture graph and repeated audio conversions.
- **Exact correction is the best first transfer.** It is deterministic, model-independent, local, testable, reversible, and nearly free at runtime.
- **Structured bounded history is the second-best transfer.** Preserve raw/final text and numeric trace data in Speakeasy's existing asynchronous JSON store; do not import Core Data or default audio retention.
- **A dictionary should remain modular.** Manual terms and exact mappings can ship before recognition bias; automatic learning should wait for explicit correction signals.
- **Avoid feature-surface imitation.** Megaphone's extensive commands, context, overlays, updater, and settings are implemented, but copying them together would undermine Speakeasy's strongest characteristic: a small, legible, measurable hot path.
