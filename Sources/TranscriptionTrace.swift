import Foundation
import os

struct TranscriptionTrace: Sendable {
    enum Outcome: String, Codable, Sendable, CaseIterable {
        case eventsPosted
        case clipboardUpdated
        case clipboardWriteFailed
        case transcriptPersisted
        case transcriptPersistenceFailed
        case noSpeech
        case emptyAudio
        case captureInterrupted
        case transcriptionFailed
        case timedOut
        case cancelled
        case warmupBlocked
        case accessibilityDenied
    }

    private static let transcriptionSampleRate: Double = 16_000

    let id: UUID
    let backend: String
    let hotkeyPressedAt: UInt64
    var captureStartAt: UInt64?
    var hotkeyReleasedAt: UInt64?
    var stopReturnedAt: UInt64?
    var transcriptionStartedAt: UInt64?
    var transcriptionEndedAt: UInt64?
    var pasteRequestedAt: UInt64?
    var sampleCount: Int
    var prependedSampleCount: Int
    var graceDurationMs: Double?
    /// Gap measured at key-down, before any rewarm can reset the clock.
    var idleGapSinceLastNativeInferenceMs: Double?
    var rewarmStarted = false
    var rewarmInFlightAtFinalStart = false
    var nativeTimings: NativeASRTimings?
    var segmentCount: Int?
    var committedAudioSeconds: Double?
    var tailSeconds: Double?
    var segmentWaitMs: Double?
    var stageChanges: [StageChange] = []

    init(
        id: UUID = UUID(),
        hotkeyPressedAt: UInt64 = Self.timestamp(),
        backend: String = "unknown"
    ) {
        self.id = id
        self.backend = backend
        self.hotkeyPressedAt = hotkeyPressedAt
        self.sampleCount = 0
        self.prependedSampleCount = 0
    }

    static func timestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    var utteranceDurationMs: Double {
        Double(sampleCount) / Self.transcriptionSampleRate * 1000
    }

    var prependedDurationMs: Double {
        Double(prependedSampleCount) / Self.transcriptionSampleRate * 1000
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

    mutating func markStopReturned(
        sampleCount: Int,
        prependedSampleCount: Int = 0,
        graceDurationMs: Double? = nil,
        at: UInt64 = Self.timestamp()
    ) {
        self.sampleCount = sampleCount
        self.prependedSampleCount = prependedSampleCount
        self.graceDurationMs = graceDurationMs
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

    func log(logger: Logger, outcome: Outcome) {
        var parts = [
            "trace_id=\(id.uuidString)",
            "outcome=\(outcome.rawValue)",
            "samples=\(sampleCount)",
            String(format: "utterance_ms=%.1f", utteranceDurationMs)
        ]

        if prependedSampleCount > 0 {
            parts.append("preroll_samples=\(prependedSampleCount)")
            parts.append(String(format: "preroll_ms=%.1f", prependedDurationMs))
        }
        if let graceDurationMs {
            parts.append(String(format: "grace_ms=%.1f", graceDurationMs))
        }
        parts.append("rewarm_started=\(rewarmStarted)")
        parts.append("rewarm_in_flight_at_final_start=\(rewarmInFlightAtFinalStart)")
        if let idleGapSinceLastNativeInferenceMs {
            parts.append(String(format: "idle_gap_ms=%.1f", idleGapSinceLastNativeInferenceMs))
        }
        if let nativeTimings {
            parts.append(String(format: "native_total_ms=%.1f native_wait_ms=%.1f", nativeTimings.totalMs, nativeTimings.waitMs))
        }
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
        logger.info("\(parts.joined(separator: " "), privacy: .public)")
    }

    var timingSnapshot: TimingSnapshot {
        TimingSnapshot(
            captureStartMs: hotkeyPressToCaptureStartMs,
            releaseToStopMs: hotkeyReleaseToStopReturnMs,
            transcriptionMs: transcriptionDurationMs,
            releaseToTextMs: hotkeyReleaseToTextMs,
            releaseToPasteMs: hotkeyReleaseToPasteRequestMs,
            transcriptionEndToPasteMs: transcriptionEndToPasteRequestMs,
            utteranceMs: utteranceDurationMs
        )
    }

    private static func durationMs(from start: UInt64?, to end: UInt64?) -> Double? {
        guard let start, let end, end >= start else {
            return nil
        }

        return Double(end - start) / 1_000_000
    }
}
