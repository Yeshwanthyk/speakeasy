import Foundation
import os

/// One completed dictation pass as a persistent, comparable record.
///
/// Records are the durable counterpart of `TranscriptionTrace`: built only
/// when every mandatory milestone fired, so a missing segment is never
/// silently treated as zero. Wall-clock time anchors records to sessions;
/// durations use monotonic uptime nanoseconds captured at each milestone.
struct E2ETraceRecord: Codable, Equatable, Sendable {
    let id: UUID
    /// Wall-clock time of the pass, for correlating with user sessions.
    let recordedAt: Date
    let backend: String
    let outcome: String
    /// True when text reached the clipboard or was pasted.
    let succeeded: Bool
    /// Final delivered character count; nil when nothing was delivered.
    let deliveredCharacterCount: Int?
    let utteranceMs: Double
    let hotkeyPressToCaptureStartMs: Double?
    let hotkeyReleaseToStopReturnMs: Double?
    let captureStopToTranscriptionStartMs: Double?
    let transcriptionMs: Double?
    let transcriptionEndToPasteRequestMs: Double?
    /// Key-up through paste request; the release latency users perceive.
    /// Deliberately excludes speaking time.
    let hotkeyReleaseToPasteRequestMs: Double?
    var idleGapSinceLastNativeInferenceMs: Double? = nil
    var nativeTotalMs: Double? = nil
    var nativeWaitMs: Double? = nil
    var rewarmStarted: Bool? = nil
    var rewarmInFlightAtFinalStart: Bool? = nil
    var segmentCount: Int? = nil
    var committedAudioSeconds: Double? = nil
    var tailSeconds: Double? = nil
    var segmentWaitMs: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAt = "recorded_at"
        case backend
        case outcome
        case succeeded
        case deliveredCharacterCount = "delivered_character_count"
        case utteranceMs = "utterance_ms"
        case hotkeyPressToCaptureStartMs = "press_to_capture_start_ms"
        case hotkeyReleaseToStopReturnMs = "release_to_stop_return_ms"
        case captureStopToTranscriptionStartMs = "stop_return_to_transcription_start_ms"
        case transcriptionMs = "transcription_ms"
        case transcriptionEndToPasteRequestMs = "transcription_end_to_paste_request_ms"
        case hotkeyReleaseToPasteRequestMs = "release_to_paste_request_ms"
        case idleGapSinceLastNativeInferenceMs = "idle_gap_since_last_native_inference_ms"
        case nativeTotalMs = "native_total_ms"
        case nativeWaitMs = "native_wait_ms"
        case rewarmStarted = "rewarm_started"
        case rewarmInFlightAtFinalStart = "rewarm_in_flight_at_final_start"
        case segmentCount = "segment_count"
        case committedAudioSeconds = "committed_audio_seconds"
        case tailSeconds = "tail_seconds"
        case segmentWaitMs = "segment_wait_ms"
    }
}

/// Builds completeness-gated records from in-memory traces.
enum E2ETraceRecordFactory {
    /// Milestones that must exist for a successful delivery to be recorded.
    private static let mandatoryForSuccess: [KeyPath<TranscriptionTrace, UInt64?>] = [
        \.captureStartAt,
        \.hotkeyReleasedAt,
        \.stopReturnedAt,
        \.transcriptionStartedAt,
        \.transcriptionEndedAt,
        \.pasteRequestedAt
    ]

    /// Returns nil when mandatory milestones are missing — an incomplete
    /// pass must not pollute latency summaries with fabricated segments.
    static func record(
        from trace: TranscriptionTrace,
        outcome: TranscriptionTrace.Outcome,
        deliveredText: String?
    ) -> E2ETraceRecord? {
        let succeeded = outcome == .eventsPosted || outcome == .clipboardUpdated
        if succeeded {
            for keyPath in mandatoryForSuccess where trace[keyPath: keyPath] == nil {
                return nil
            }
        }

        return E2ETraceRecord(
            id: trace.id,
            recordedAt: Date(),
            backend: trace.backend,
            outcome: outcome.rawValue,
            succeeded: succeeded,
            deliveredCharacterCount: succeeded ? (deliveredText ?? "").count : nil,
            utteranceMs: trace.utteranceDurationMs,
            hotkeyPressToCaptureStartMs: trace.hotkeyPressToCaptureStartMs,
            hotkeyReleaseToStopReturnMs: trace.hotkeyReleaseToStopReturnMs,
            captureStopToTranscriptionStartMs: duration(
                from: trace.stopReturnedAt,
                to: trace.transcriptionStartedAt
            ),
            transcriptionMs: trace.transcriptionDurationMs,
            transcriptionEndToPasteRequestMs: trace.transcriptionEndToPasteRequestMs,
            hotkeyReleaseToPasteRequestMs: trace.hotkeyReleaseToPasteRequestMs,
            idleGapSinceLastNativeInferenceMs: trace.idleGapSinceLastNativeInferenceMs,
            nativeTotalMs: trace.nativeTimings?.totalMs,
            nativeWaitMs: trace.nativeTimings?.waitMs,
            rewarmStarted: trace.rewarmStarted,
            rewarmInFlightAtFinalStart: trace.rewarmInFlightAtFinalStart,
            segmentCount: trace.segmentCount,
            committedAudioSeconds: trace.committedAudioSeconds,
            tailSeconds: trace.tailSeconds,
            segmentWaitMs: trace.segmentWaitMs
        )
    }

    private static func duration(from start: UInt64?, to end: UInt64?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }
}

/// Append-only JSONL store for e2e dictation records under Application
/// Support. Writes happen on a serial queue and never block the dictation
/// path; the file stays bounded by rewriting once the in-memory window
/// wraps.
final class E2ETraceStore: @unchecked Sendable {
    /// Default retention window; overridable for tests.
    static let defaultMaxRecords = 2_000

    private let fileURL: URL
    private let maxRecords: Int
    private let ioQueue = DispatchQueue(label: "com.speakeasy.app.e2e-traces", qos: .utility)
    private var pendingRecords: [E2ETraceRecord]

    /// Loads up to `maxRecords` existing records; failures start fresh so a
    /// corrupt log never blocks dictation.
    init(fileURL: URL, maxRecords: Int = E2ETraceStore.defaultMaxRecords) {
        precondition(maxRecords >= 4, "retention window must allow a wrap")
        self.fileURL = fileURL
        self.maxRecords = maxRecords
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
        } catch {
            Logger(subsystem: "com.speakeasy.app", category: "e2e-traces")
                .error("Could not initialize dictation-e2e.jsonl: \(String(describing: error), privacy: .public)")
        }
        let records = Self.loadRecords(from: fileURL)
        if records.count > maxRecords {
            self.pendingRecords = Array(records.suffix(maxRecords))
        } else {
            self.pendingRecords = records
        }
    }

    /// Appends one record without blocking the caller.
    func append(_ record: E2ETraceRecord) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRecords.append(record)
            if self.pendingRecords.count > self.maxRecords {
                // Window wrapped: keep the newest half and rewrite once
                // instead of appending forever.
                self.pendingRecords.removeFirst(self.pendingRecords.count - self.maxRecords / 2)
                self.rewriteOnQueue(self.pendingRecords)
            } else {
                self.appendLineOnQueue(record)
            }
        }
    }

    /// Synchronous read of all retained records, oldest first.
    func allRecords() -> [E2ETraceRecord] {
        ioQueue.sync { pendingRecords }
    }

    // MARK: - IO internals

    private func appendLineOnQueue(_ record: E2ETraceRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(record) else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            Logger(subsystem: "com.speakeasy.app", category: "e2e-traces")
                .error("Could not write dictation-e2e.jsonl: \(String(describing: error), privacy: .public)")
        }
    }

    private func rewriteOnQueue(_ records: [E2ETraceRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        var payload = Data()
        for record in records {
            if let data = try? encoder.encode(record) {
                payload.append(data)
                payload.append(0x0A)
            }
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("." + fileURL.lastPathComponent + ".tmp")
            try payload.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } catch {
            // Best effort; next wrap retries.
        }
    }

    private static func loadRecords(from url: URL) -> [E2ETraceRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var records: [E2ETraceRecord] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(E2ETraceRecord.self, from: Data(line)) {
                records.append(record)
            }
        }
        return records
    }
}

/// Latency summary over completed passes. Medians over **successful
/// insertions only** — failed passes measure failure handling, not dictation
/// speed — and release latency deliberately excludes user think-time because
/// key-up starts the clock.
struct E2ESummary: Equatable, Sendable {
    struct SegmentMedian: Equatable, Sendable {
        let name: String
        let medianMs: Double
    }

    let totalPasses: Int
    let successfulPasses: Int
    let segments: [SegmentMedian]
}

enum E2ESummarizer {
    static let summarizedSegments: [(name: String, keyPath: KeyPath<E2ETraceRecord, Double?>)] = [
        ("press_to_capture_start", \.hotkeyPressToCaptureStartMs),
        ("release_to_stop_return", \.hotkeyReleaseToStopReturnMs),
        ("stop_return_to_transcription_start", \.captureStopToTranscriptionStartMs),
        ("transcription", \.transcriptionMs),
        ("transcription_end_to_paste_request", \.transcriptionEndToPasteRequestMs),
        ("release_to_paste_request", \.hotkeyReleaseToPasteRequestMs)
    ]

    static func summarize(_ records: [E2ETraceRecord]) -> E2ESummary {
        let successful = records.filter(\.succeeded)
        var segments: [E2ESummary.SegmentMedian] = []
        for (name, keyPath) in summarizedSegments {
            let values = successful.compactMap { $0[keyPath: keyPath] }
            if let median = median(values) {
                segments.append(E2ESummary.SegmentMedian(name: name, medianMs: median))
            }
        }
        return E2ESummary(
            totalPasses: records.count,
            successfulPasses: successful.count,
            segments: segments
        )
    }

    /// Median with linear interpolation for even counts.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
