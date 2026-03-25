import Foundation
import os

struct TranscriptionTrace {
    enum Outcome: String {
        case pasted
        case noSpeech
        case emptyAudio
        case transcriptionFailed
        case timedOut
        case warmupBlocked
        case accessibilityDenied
    }

    private static let transcriptionSampleRate: Double = 16_000

    let id: UUID
    let hotkeyPressedAt: UInt64
    var captureStartAt: UInt64?
    var hotkeyReleasedAt: UInt64?
    var stopReturnedAt: UInt64?
    var transcriptionStartedAt: UInt64?
    var transcriptionEndedAt: UInt64?
    var pasteRequestedAt: UInt64?
    var sampleCount: Int

    init(id: UUID = UUID(), hotkeyPressedAt: UInt64 = Self.timestamp()) {
        self.id = id
        self.hotkeyPressedAt = hotkeyPressedAt
        self.sampleCount = 0
    }

    static func timestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    var utteranceDurationMs: Double {
        Double(sampleCount) / Self.transcriptionSampleRate * 1000
    }

    var hotkeyPressToCaptureStartMs: Double? {
        Self.durationMs(from: hotkeyPressedAt, to: captureStartAt)
    }

    var hotkeyReleaseToStopReturnMs: Double? {
        Self.durationMs(from: hotkeyReleasedAt, to: stopReturnedAt)
    }

    var transcriptionDurationMs: Double? {
        Self.durationMs(from: transcriptionStartedAt, to: transcriptionEndedAt)
    }

    var transcriptionEndToPasteRequestMs: Double? {
        Self.durationMs(from: transcriptionEndedAt, to: pasteRequestedAt)
    }

    var hotkeyReleaseToTextMs: Double? {
        Self.durationMs(from: hotkeyReleasedAt, to: transcriptionEndedAt)
    }

    var hotkeyReleaseToPasteRequestMs: Double? {
        Self.durationMs(from: hotkeyReleasedAt, to: pasteRequestedAt)
    }

    mutating func markCaptureStarted(at: UInt64 = Self.timestamp()) {
        captureStartAt = at
    }

    mutating func markHotkeyReleased(at: UInt64 = Self.timestamp()) {
        hotkeyReleasedAt = at
    }

    mutating func markStopReturned(sampleCount: Int, at: UInt64 = Self.timestamp()) {
        self.sampleCount = sampleCount
        stopReturnedAt = at
    }

    mutating func markTranscriptionStarted(at: UInt64 = Self.timestamp()) {
        transcriptionStartedAt = at
    }

    mutating func markTranscriptionEnded(at: UInt64 = Self.timestamp()) {
        transcriptionEndedAt = at
    }

    mutating func markPasteRequested(at: UInt64 = Self.timestamp()) {
        pasteRequestedAt = at
    }

    func log(
        logger: Logger,
        outcome: Outcome,
        textLength: Int? = nil,
        extra: String? = nil
    ) {
        var parts = [
            "trace_id=\(id.uuidString)",
            "outcome=\(outcome.rawValue)",
            "samples=\(sampleCount)",
            String(format: "utterance_ms=%.1f", utteranceDurationMs)
        ]

        if let value = hotkeyPressToCaptureStartMs {
            parts.append(String(format: "press_to_capture_start_ms=%.1f", value))
        }
        if let value = hotkeyReleaseToStopReturnMs {
            parts.append(String(format: "release_to_stop_ms=%.1f", value))
        }
        if let value = transcriptionDurationMs {
            parts.append(String(format: "transcription_ms=%.1f", value))
        }
        if let value = transcriptionEndToPasteRequestMs {
            parts.append(String(format: "transcription_end_to_paste_ms=%.1f", value))
        }
        if let value = hotkeyReleaseToTextMs {
            parts.append(String(format: "release_to_text_ms=%.1f", value))
        }
        if let value = hotkeyReleaseToPasteRequestMs {
            parts.append(String(format: "release_to_paste_ms=%.1f", value))
        }
        if let textLength {
            parts.append("text_chars=\(textLength)")
        }
        if let extra, !extra.isEmpty {
            parts.append(extra)
        }

        logger.info("\(parts.joined(separator: " "), privacy: .public)")
    }

    private static func durationMs(from start: UInt64?, to end: UInt64?) -> Double? {
        guard let start, let end, end >= start else {
            return nil
        }

        return Double(end - start) / 1_000_000
    }
}

#if DEBUG
final class TranscriptionDebugSummary {
    private let lock = UnfairLock()
    private var captureStartLatenciesMs: [Double] = []
    private var releaseToTextLatenciesMs: [Double] = []

    func record(trace: TranscriptionTrace) -> String? {
        guard
            let captureStart = trace.hotkeyPressToCaptureStartMs,
            let releaseToText = trace.hotkeyReleaseToTextMs
        else {
            return nil
        }

        return lock.withLock {
            captureStartLatenciesMs.append(captureStart)
            releaseToTextLatenciesMs.append(releaseToText)

            let captureP50 = Self.percentile(0.5, values: captureStartLatenciesMs)
            let captureP95 = Self.percentile(0.95, values: captureStartLatenciesMs)
            let releaseP50 = Self.percentile(0.5, values: releaseToTextLatenciesMs)
            let releaseP95 = Self.percentile(0.95, values: releaseToTextLatenciesMs)

            return String(
                format: "debug_latency_summary count=%d capture_start_p50_ms=%.1f capture_start_p95_ms=%.1f release_to_text_p50_ms=%.1f release_to_text_p95_ms=%.1f",
                captureStartLatenciesMs.count,
                captureP50,
                captureP95,
                releaseP50,
                releaseP95
            )
        }
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sorted = values.sorted()
        let rawIndex = Int((Double(sorted.count - 1) * percentile).rounded())
        let boundedIndex = min(sorted.count - 1, max(0, rawIndex))
        return sorted[boundedIndex]
    }
}
#endif
