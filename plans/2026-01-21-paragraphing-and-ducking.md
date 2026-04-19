# Paragraphing and Ducking Implementation Plan

## Plan Metadata
- Created: 2026-01-21
- Ticket: None
- Status: draft; not implemented
- Owner: yesh
- Assumptions:
  - Paragraphing is always on (no settings UI or toggle).
  - Ducking is implemented with macOS 14+ voice-processing APIs only; no pause/mute fallback on macOS 12-13.
  - Minimal latency impact is prioritized; formatting is post-processing only.

## Progress Tracking
- [ ] Phase 1: Transcript formatting
- [ ] Phase 2: Audio ducking via voice processing

## Overview
Add paragraphing as a low-latency post-processing step before paste, and add true audio ducking on macOS 14+ by enabling voice processing and setting other-audio ducking configuration.

## Current State
- Transcription results are trimmed and pasted as-is in `AppCoordinator.handleTranscriptionResult`.
- Audio capture uses `AVAudioEngine` input tap without voice processing.
- Build uses `swiftc` with explicit framework links and `Package.swift` linker settings; `NaturalLanguage` is not linked.

### Key Discoveries
- Transcription output is pasted directly:
  - `Sources/AppCoordinator.swift:230-238`
  - Current snippet:
    ```swift
    private func handleTranscriptionResult(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feedback.error("No speech detected")
            return
        }

        if accessibilityChecker.ensureAccessibilityPrompted() {
            paster.paste(trimmed)
        } else {
            logger.error("Accessibility permission missing")
            feedback.error("Accessibility permission required")
        }
    }
    ```
- Audio capture starts the engine and installs a tap without voice processing:
  - `Sources/AudioCapture.swift:69-105`
  - Current snippet:
    ```swift
    func start() {
        let startTime = CFAbsoluteTimeGetCurrent()
        ...
        let inputNode = engine.inputNode
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: inputFormat
        ) { [weak self] pcmBuffer, _ in
            self?.handle(buffer: pcmBuffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Failed to start engine: \(error.localizedDescription)")
        }
        ...
    }
    ```
- macOS target is 12.0, so ducking must be availability-gated:
  - `Package.swift:6-8`
    ```swift
    platforms: [
        .macOS(.v12)
    ],
    ```
- AVAudioEngine voice-processing ducking config is macOS 14+:
  - SDK header `AVAudioIONode.h` (macOS SDK) declares `voiceProcessingOtherAudioDuckingConfiguration` and `AVAudioVoiceProcessingOtherAudioDuckingConfiguration` as `API_AVAILABLE(macos(14.0))`.

## Desired End State
- Transcription text is formatted into paragraphs before paste using an NLTokenizer-based formatter.
- Formatting is fast, synchronous, and does not block ASR; it runs after transcription completes.
- Audio ducking is enabled during recording on macOS 14+ via voice processing config; failures log and fall back to no ducking.
- Builds include `NaturalLanguage` in both `Package.swift` and `build.sh`.

### Verification
- `swift test` passes.
- `./build.sh` succeeds.
- Manual: record multi-sentence speech and verify paragraph breaks; play music and confirm ducking while recording on macOS 14+.

## Out of Scope
- UI/setting toggles for paragraphing or ducking.
- Punctuation/restoration model inference.
- Media pause/mute fallback for macOS 12-13.
- Streaming or partial transcription formatting.

## Breaking Changes
None.

## Dependency and Configuration Changes

### Additions
None.

### Updates
None.

### Removals
None.

### Configuration Changes
**File**: `Package.swift`

**Before**:
```swift
linkerSettings: [
    .linkedFramework("AppKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Carbon"),
    .linkedFramework("ApplicationServices")
]
```

**After**:
```swift
linkerSettings: [
    .linkedFramework("AppKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Carbon"),
    .linkedFramework("ApplicationServices"),
    .linkedFramework("NaturalLanguage")
]
```
**Impact**: Ensures `TranscriptFormatter` links against `NaturalLanguage` for `swift test` and SwiftPM builds.

**File**: `build.sh`

**Before**:
```bash
swiftc -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -L "$RUST_DIR/target/release" \
  ...
```

**After**:
```bash
swiftc -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -framework NaturalLanguage \
  -L "$RUST_DIR/target/release" \
  ...
```
**Impact**: App build links the formatter dependency.

## Error Handling Strategy
- Formatting: return trimmed text if tokenizer returns no sentences or output is empty.
- Ducking: if voice processing enablement or configuration fails, log once and continue recording without ducking.
- No new user-facing errors; use existing `Logger` for diagnostics.

## Implementation Approach
- Add a lightweight `TranscriptFormatter` using `NLTokenizer` for sentence and word counts, mirroring VoiceInk’s low-cost heuristic without additional models.
- Integrate formatting in `AppCoordinator.handleTranscriptionResult` after trimming and before paste.
- Enable voice processing and set ducking configuration in `AudioCapture.start()` guarded by `#available(macOS 14.0, *)`.
- Avoid touching audio pipeline on macOS < 14 to preserve latency.

## Phase Dependencies and Parallelization
- Dependencies: None; Phases 1 and 2 can be done independently.
- Parallelizable: Phase 1 and Phase 2 can run in parallel after shared discovery (already done).

---

## Phase 1: Transcript formatting

### Overview
Add a post-processing formatter and wire it into `AppCoordinator` before pasting.

### Prerequisites
- [ ] None
- [ ] Open Questions resolved

### Change Checklist
- [ ] Add `TranscriptFormatter` with NLTokenizer-based paragraphing.
- [ ] Apply formatting in `AppCoordinator.handleTranscriptionResult`.
- [ ] Link `NaturalLanguage` in `Package.swift` and `build.sh`.
- [ ] Add unit tests for formatting behavior.

### Changes

#### 1. TranscriptFormatter (new file)
**File**: `Sources/TranscriptFormatter.swift`
**Location**: new file

**Add**:
```swift
import Foundation
import NaturalLanguage

struct TranscriptFormatter {
    private static let targetWordCount = 50
    private static let maxSentencesPerParagraph = 4
    private static let minWordsForSignificantSentence = 4

    static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let language = NLLanguageRecognizer.dominantLanguage(for: trimmed) ?? .english

        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = trimmed
        sentenceTokenizer.setLanguage(language)

        var sentences: [String] = []
        sentenceTokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        guard !sentences.isEmpty else { return trimmed }

        var paragraphs: [String] = []
        var index = 0

        while index < sentences.count {
            var chunk: [String] = []
            var wordCount = 0
            var significantCount = 0

            for i in index..<sentences.count {
                let sentence = sentences[i]
                let words = countWords(in: sentence, language: language)
                chunk.append(sentence)
                wordCount += words
                if words >= minWordsForSignificantSentence {
                    significantCount += 1
                }
                if wordCount >= targetWordCount {
                    break
                }
            }

            var finalChunk = chunk
            if significantCount > maxSentencesPerParagraph {
                finalChunk = []
                var significantSeen = 0
                for sentence in chunk {
                    finalChunk.append(sentence)
                    let words = countWords(in: sentence, language: language)
                    if words >= minWordsForSignificantSentence {
                        significantSeen += 1
                        if significantSeen >= maxSentencesPerParagraph {
                            break
                        }
                    }
                }
            }

            if finalChunk.isEmpty {
                finalChunk = [sentences[index]]
            }

            paragraphs.append(finalChunk.joined(separator: " "))
            index += finalChunk.count
        }

        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func countWords(in sentence: String, language: NLLanguage) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        tokenizer.setLanguage(language)

        var count = 0
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
```

**Why**: Provides deterministic paragraphing without model inference.

#### 2. AppCoordinator formatting hook
**File**: `Sources/AppCoordinator.swift`
**Location**: lines 230-238

**Before**:
```swift
private func handleTranscriptionResult(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        feedback.error("No speech detected")
        return
    }

    if accessibilityChecker.ensureAccessibilityPrompted() {
        paster.paste(trimmed)
    } else {
        logger.error("Accessibility permission missing")
        feedback.error("Accessibility permission required")
    }
}
```

**After**:
```swift
private func handleTranscriptionResult(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        feedback.error("No speech detected")
        return
    }

    let formatted = TranscriptFormatter.format(trimmed)
    let output = formatted.isEmpty ? trimmed : formatted

    if accessibilityChecker.ensureAccessibilityPrompted() {
        paster.paste(output)
    } else {
        logger.error("Accessibility permission missing")
        feedback.error("Accessibility permission required")
    }
}
```

**Why**: Inserts paragraphing while preserving empty-check logic and ensuring a safe fallback.

#### 3. Link `NaturalLanguage` for SwiftPM
**File**: `Package.swift`
**Location**: lines 21-26

**Before**:
```swift
linkerSettings: [
    .linkedFramework("AppKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Carbon"),
    .linkedFramework("ApplicationServices")
]
```

**After**:
```swift
linkerSettings: [
    .linkedFramework("AppKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Carbon"),
    .linkedFramework("ApplicationServices"),
    .linkedFramework("NaturalLanguage")
]
```

**Why**: Required to link NLTokenizer usage in tests and SwiftPM builds.

#### 4. Link `NaturalLanguage` for `build.sh`
**File**: `build.sh`
**Location**: lines 19-27

**Before**:
```bash
swiftc -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -L "$RUST_DIR/target/release" \
  -lparakeet_bridge \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/"*.swift \
  -o "$BIN_DIR/$APP_NAME"
```

**After**:
```bash
swiftc -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework Carbon \
  -framework ApplicationServices \
  -framework NaturalLanguage \
  -L "$RUST_DIR/target/release" \
  -lparakeet_bridge \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/"*.swift \
  -o "$BIN_DIR/$APP_NAME"
```

**Why**: Ensures the app binary links to NaturalLanguage when built outside SwiftPM.

#### 5. Tests for formatting
**File**: `Tests/WispTests/TranscriptFormatterTests.swift`
**Location**: new file

**Add**:
```swift
import XCTest
@testable import Wisp

final class TranscriptFormatterTests: XCTestCase {
    func testParagraphSplitAfterFourSignificantSentences() {
        let text = """
        Alpha beta gamma delta. One two three four. Five six seven eight. Nine ten eleven twelve. Thirteen fourteen fifteen sixteen.
        """
        let expected = """
        Alpha beta gamma delta. One two three four. Five six seven eight. Nine ten eleven twelve.

        Thirteen fourteen fifteen sixteen.
        """

        XCTAssertEqual(TranscriptFormatter.format(text), expected)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(TranscriptFormatter.format("   "), "")
    }
}
```

**Why**: Validates deterministic paragraph splitting and empty-input behavior.

### Edge Cases to Handle
- [ ] Empty input: formatter returns empty; `AppCoordinator` still handles "No speech detected".
- [ ] No sentence boundaries: formatter returns trimmed input.
- [ ] Very long text: chunking prevents one giant paragraph.

### Success Criteria

**Automated**:
```bash
swift test
```

**Before proceeding to next phase**:
```bash
swift test
./build.sh
```

**Manual**:
- [ ] Record 5+ full sentences; pasted text has blank-line paragraph breaks.
- [ ] Single short sentence remains unchanged.

### Rollback
```bash
git restore -- Sources/AppCoordinator.swift Sources/TranscriptFormatter.swift Package.swift build.sh Tests/WispTests/TranscriptFormatterTests.swift
```

### Notes
- None.

---

## Phase 2: Audio ducking via voice processing

### Overview
Enable voice processing on macOS 14+ and configure other-audio ducking before the engine starts.

### Prerequisites
- [ ] Phase 1 automated checks pass (if done sequentially)
- [ ] Phase 1 manual verification complete (if done sequentially)

### Change Checklist
- [ ] Add ducking configuration in `AudioCapture`.
- [ ] Call ducking config before `engine.start()`.
- [ ] Ensure failure logs and continues without ducking.

### Changes

#### 1. AudioCapture ducking configuration
**File**: `Sources/AudioCapture.swift`
**Location**: near lines 31-36 and 69-100

**Before**:
```swift
private var frontBuffer = ContiguousArray<Float>()
private var backBuffer = ContiguousArray<Float>()
private var isRecording = false
private var conversionBuffer: AVAudioPCMBuffer?
private var didReachLimit = false
```

**After**:
```swift
private var frontBuffer = ContiguousArray<Float>()
private var backBuffer = ContiguousArray<Float>()
private var isRecording = false
private var conversionBuffer: AVAudioPCMBuffer?
private var didReachLimit = false
private var didConfigureDucking = false
```

**Why**: Track whether ducking configuration has already been attempted.

#### 2. Configure voice processing before engine start
**File**: `Sources/AudioCapture.swift`
**Location**: inside `start()` before `installTap`

**Before**:
```swift
// Install tap and start engine on-demand
let inputNode = engine.inputNode
inputNode.installTap(
    onBus: 0,
    bufferSize: Self.tapBufferSize,
    format: inputFormat
) { [weak self] pcmBuffer, _ in
    self?.handle(buffer: pcmBuffer)
}
```

**After**:
```swift
configureDuckingIfAvailable()

// Install tap and start engine on-demand
let inputNode = engine.inputNode
inputNode.installTap(
    onBus: 0,
    bufferSize: Self.tapBufferSize,
    format: inputFormat
) { [weak self] pcmBuffer, _ in
    self?.handle(buffer: pcmBuffer)
}
```

**Why**: Voice processing must be enabled while the engine is stopped; this ensures it is set before starting.

#### 3. Add ducking helper method
**File**: `Sources/AudioCapture.swift`
**Location**: new private method near end of file

**Add**:
```swift
private func configureDuckingIfAvailable() {
    guard #available(macOS 14.0, *) else { return }
    guard !didConfigureDucking else { return }
    didConfigureDucking = true

    var error: NSError?
    let enabled = engine.inputNode.setVoiceProcessingEnabled(true, error: &error)
    if !enabled {
        if let error {
            logger.error("Voice processing enable failed: \(error.localizedDescription)")
        } else {
            logger.error("Voice processing enable failed with unknown error")
        }
        return
    }

    let config = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: true,
        duckingLevel: .max
    )
    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = config
}
```

**Why**: Enables true OS-level ducking for other audio during recording on macOS 14+.

### Edge Cases to Handle
- [ ] macOS < 14: method is a no-op, no latency or behavior change.
- [ ] Voice processing enable fails: log and record without ducking.

### Success Criteria

**Automated**:
```bash
swift test
```

**Before proceeding to next phase**:
```bash
./build.sh
```

**Manual**:
- [ ] On macOS 14+, start playback in another app, begin recording, and verify other audio is ducked.
- [ ] Stop recording and confirm other audio returns to normal.

### Rollback
```bash
git restore -- Sources/AudioCapture.swift
```

### Notes
- None.

---

## Testing Strategy

### Unit Tests to Add/Modify

**File**: `Tests/WispTests/TranscriptFormatterTests.swift`

```swift
// Added in Phase 1, verifies paragraph splitting and empty input behavior.
```

### Integration Tests
- [ ] None (audio ducking requires OS-level manual verification).

### Manual Testing Checklist
1. [ ] Record multi-sentence speech; verify paragraph breaks in pasted output.
2. [ ] Record a single short sentence; ensure no change in output.
3. [ ] On macOS 14+, play music and start recording; verify ducking occurs and ends when recording stops.

## Deployment Instructions
No deployment steps beyond build/run.

## Anti-Patterns to Avoid
- Enabling/disabling voice processing while the engine is running (unsupported).
- Running formatting before trimming (can create empty paragraphs).
- Introducing a model-based punctuator in the critical path (adds latency).

## Open Questions (must resolve before implementation)
- [ ] Ducking strategy -> Answer: true ducking via voice processing on macOS 14+, no fallback.
- [ ] Paragraphing toggle -> Answer: always-on (no settings UI).
- [ ] Ducking defaults -> Answer: `enableAdvancedDucking = true`, `duckingLevel = .max`.

## References
- `Sources/AppCoordinator.swift:230-238`
- `Sources/AudioCapture.swift:69-105`
- `Package.swift:6-26`
- `build.sh:19-27`
- SDK header: `AVAudioIONode.h` (voice processing ducking config, macOS 14+)
