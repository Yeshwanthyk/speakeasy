import Foundation

/// Monotonic-revision gate for live partial transcripts.
///
/// During recording, incremental transcription produces candidate previews
/// whose quality varies near word boundaries. A preview may never shrink the
/// visible transcript: once words have been shown, a later hypothesis must
/// contain at least as many words before replacing it. The final batch pass
/// remains the source of truth regardless of what the preview last showed,
/// so an over-eager late rejection can only affect perception, never the
/// delivered text.
struct PreviewRevisionPolicy: Sendable {
    /// Returns the preview text to display, or nil when `candidate` must not
    /// replace `previous`. Accepts any non-empty first preview; afterwards a
    /// candidate needs at least the previous normalized word count.
    func revised(previous: String?, candidate: String) -> String? {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }

        guard let previous else {
            return trimmedCandidate
        }

        let candidateWords = Self.significantWordCount(trimmedCandidate)
        let previousWords = Self.significantWordCount(previous)
        guard candidateWords >= previousWords else {
            return nil
        }
        return trimmedCandidate
    }

    private static func significantWordCount(_ text: String) -> Int {
        TranscriptPostProcessor.tokens(in: text)
            .filter(\.hasLetterOrNumber)
            .count
    }
}

/// Owns live-preview scheduling and state for one active recording.
///
/// Cost bounds keep previews strictly subordinate to dictation latency:
/// passes fire no more often than `minimumIntervalMs`, only after enough new
/// audio accumulated to plausibly change the transcript, and only one pass
/// is ever in flight - the native session serializes inference anyway, so a
/// second queued preview would just delay the final pass.
final class LivePreviewController: @unchecked Sendable {
    static let defaultMinimumIntervalMs: Double = 700
    static let defaultMinimumGrowthSamples: Int = 8_000 // 0.5 s at 16 kHz

    private let lock = UnfairLock()
    private let policy = PreviewRevisionPolicy()
    private var minimumIntervalMs: Double
    private var minimumGrowthSamples: Int

    private var lastPassAtMs: Double?
    private var lastPassSampleCount = 0
    private var passInFlight = false
    private var currentText: String?
    private(set) var adoptedCount = 0

    init(
        minimumIntervalMs: Double = LivePreviewController.defaultMinimumIntervalMs,
        minimumGrowthSamples: Int = LivePreviewController.defaultMinimumGrowthSamples
    ) {
        precondition(minimumIntervalMs >= 0)
        precondition(minimumGrowthSamples >= 0)
        self.minimumIntervalMs = minimumIntervalMs
        self.minimumGrowthSamples = minimumGrowthSamples
    }

    /// Whether a preview pass may start right now.
    func shouldTranscribe(nowMs: Double, bufferedSampleCount: Int) -> Bool {
        lock.withLock {
            if passInFlight {
                return false
            }
            if let lastPassAtMs, nowMs - lastPassAtMs < minimumIntervalMs {
                return false
            }
            return bufferedSampleCount - lastPassSampleCount >= minimumGrowthSamples
                || lastPassSampleCount == 0 && bufferedSampleCount >= minimumGrowthSamples
        }
    }

    /// Marks a pass as started so further ticks stay idle until it settles.
    func beginPass(nowMs: Double, bufferedSampleCount: Int) {
        lock.withLock {
            lastPassAtMs = nowMs
            lastPassSampleCount = bufferedSampleCount
            passInFlight = true
        }
    }

    /// Ends a pass, adopting the candidate through the revision policy.
    /// Returns the current preview text after the attempt.
    @discardableResult
    func finishPass(candidate: String?) -> String? {
        lock.withLock {
            passInFlight = false
            guard let candidate,
                  let revised = policy.revised(previous: currentText, candidate: candidate) else {
                return currentText
            }
            currentText = revised
            adoptedCount += 1
            return currentText
        }
    }

    /// Audio window changed after a background commit; retain the visible
    /// revision while restarting growth accounting for the new tail.
    func rebaseAudioCursor() {
        lock.withLock { lastPassSampleCount = 0 }
    }

    /// Current preview text, if any preview has been adopted.
    var previewText: String? {
        lock.withLock { currentText }
    }

    /// Clears all per-recording state.
    func reset() {
        lock.withLock {
            lastPassAtMs = nil
            lastPassSampleCount = 0
            passInFlight = false
            currentText = nil
            adoptedCount = 0
        }
    }
}
