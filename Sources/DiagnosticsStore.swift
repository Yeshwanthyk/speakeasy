import Foundation
import os

struct OutcomeCounters: Codable, Equatable, Sendable {
    var eventsPosted = 0
    var clipboardUpdated = 0
    var clipboardWriteFailed = 0
    var transcriptPersisted = 0
    var transcriptPersistenceFailed = 0
    var noSpeech = 0
    var emptyAudio = 0
    var captureInterrupted = 0
    var transcriptionFailed = 0
    var timedOut = 0
    var cancelled = 0
    var warmupBlocked = 0
    var accessibilityDenied = 0

    mutating func increment(_ outcome: TranscriptionTrace.Outcome) {
        switch outcome {
        case .eventsPosted: eventsPosted += 1
        case .clipboardUpdated: clipboardUpdated += 1
        case .clipboardWriteFailed: clipboardWriteFailed += 1
        case .transcriptPersisted: transcriptPersisted += 1
        case .transcriptPersistenceFailed: transcriptPersistenceFailed += 1
        case .noSpeech: noSpeech += 1
        case .emptyAudio: emptyAudio += 1
        case .captureInterrupted: captureInterrupted += 1
        case .transcriptionFailed: transcriptionFailed += 1
        case .timedOut: timedOut += 1
        case .cancelled: cancelled += 1
        case .warmupBlocked: warmupBlocked += 1
        case .accessibilityDenied: accessibilityDenied += 1
        }
    }

    var total: Int {
        eventsPosted
            + clipboardUpdated
            + clipboardWriteFailed
            + transcriptPersisted
            + transcriptPersistenceFailed
            + noSpeech
            + emptyAudio
            + captureInterrupted
            + transcriptionFailed
            + timedOut
            + cancelled
            + warmupBlocked
            + accessibilityDenied
    }
}

struct BackendCounters: Codable, Equatable, Sendable {
    var parakeet110M = 0
    var parakeetUnified = 0
    var unknown = 0

    mutating func increment(_ backend: String) {
        switch backend {
        case "parakeet-tdt-ctc-110m": parakeet110M += 1
        case "parakeet-unified-en": parakeetUnified += 1
        case "parakeet-tdt", "parakeet-v3", "parakeet-tdt-v3",
             "nemotron", "nemotron-3", "nemotron-3.5", "nemotron-3.5-asr":
            parakeetUnified += 1
        default: unknown += 1
        }
    }

    private enum CodingKeys: String, CodingKey {
        case parakeet110M
        case parakeetUnified
        case parakeetTDT
        case nemotron
        case unknown
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parakeet110M = try container.decodeIfPresent(Int.self, forKey: .parakeet110M) ?? 0
        let unified = try container.decodeIfPresent(Int.self, forKey: .parakeetUnified) ?? 0
        let legacyTDT = try container.decodeIfPresent(Int.self, forKey: .parakeetTDT) ?? 0
        let legacyNemotron = try container.decodeIfPresent(Int.self, forKey: .nemotron) ?? 0
        parakeetUnified = unified + legacyTDT + legacyNemotron
        unknown = try container.decodeIfPresent(Int.self, forKey: .unknown) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parakeet110M, forKey: .parakeet110M)
        try container.encode(parakeetUnified, forKey: .parakeetUnified)
        try container.encode(unknown, forKey: .unknown)
    }
}

struct AggregateStats: Codable, Equatable, Sendable {
    var attemptCount = 0
    var deliveryCount = 0
    var wordCount = 0
    var characterCount = 0
    var outcomes = OutcomeCounters()
    var backends = BackendCounters()

    mutating func record(
        backend: String,
        outcome: TranscriptionTrace.Outcome,
        wordCount: Int,
        characterCount: Int
    ) {
        attemptCount += 1
        if outcome == .eventsPosted || outcome == .clipboardUpdated {
            deliveryCount += 1
        }
        self.wordCount += wordCount
        self.characterCount += characterCount
        outcomes.increment(outcome)
        backends.increment(backend)
    }
}

struct DailyStats: Codable, Equatable, Identifiable, Sendable {
    let day: String
    var aggregate: AggregateStats

    var id: String { day }
}

struct LatencySample: Codable, Equatable, Sendable {
    let captureStartMs: Double?
    let releaseToTextMs: Double?
    let releaseToPasteMs: Double?

    init(
        captureStartMs: Double?,
        releaseToTextMs: Double?,
        releaseToPasteMs: Double?
    ) {
        self.captureStartMs = captureStartMs
        self.releaseToTextMs = releaseToTextMs
        self.releaseToPasteMs = releaseToPasteMs
    }

    init(timings: TimingSnapshot) {
        self.init(
            captureStartMs: timings.captureStartMs,
            releaseToTextMs: timings.releaseToTextMs,
            releaseToPasteMs: timings.releaseToPasteMs
        )
    }

    var isEmpty: Bool {
        captureStartMs == nil && releaseToTextMs == nil && releaseToPasteMs == nil
    }
}

struct DiagnosticsDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var lifetime: AggregateStats
    var dailyBuckets: [DailyStats]
    var latencySamples: [LatencySample]

    init(
        lifetime: AggregateStats = AggregateStats(),
        dailyBuckets: [DailyStats] = [],
        latencySamples: [LatencySample] = [],
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.lifetime = lifetime
        self.dailyBuckets = dailyBuckets
        self.latencySamples = latencySamples
    }
}

enum DiagnosticsFormatter {
    static func report(document: DiagnosticsDocument, today: String) -> String {
        let todayStats = document.dailyBuckets.first(where: { $0.day == today })?.aggregate
            ?? AggregateStats()
        let textP50 = percentile(
            0.50,
            values: document.latencySamples.compactMap(\.releaseToTextMs)
        )
        let textP95 = percentile(
            0.95,
            values: document.latencySamples.compactMap(\.releaseToTextMs)
        )

        let successRate: String
        if document.lifetime.attemptCount == 0 {
            successRate = "—"
        } else {
            successRate = String(
                format: "%.0f%%",
                Double(document.lifetime.deliveryCount) / Double(document.lifetime.attemptCount) * 100
            )
        }

        return [
            "Today: \(todayStats.attemptCount) attempts, \(todayStats.deliveryCount) delivered",
            "Lifetime: \(document.lifetime.attemptCount) attempts, \(successRate) delivered",
            "Release to text: p50 \(formatted(textP50)) ms, p95 \(formatted(textP95)) ms"
        ].joined(separator: "\n")
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    private static func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }
}

/// Bounded, content-free local diagnostics. The store records only fixed
/// counters, numeric aggregates, day keys, and a small ring of timing samples.
@MainActor
final class DiagnosticsStore {
    static let maxDailyBuckets = 31
    static let maxLatencySamples = 256

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "diagnostics")
    private let fileURL: URL
    private let writer = OrderedSnapshotWriter(label: "com.speakeasy.diagnostics.write")
    private var document: DiagnosticsDocument
    private var recordedTraceIDs: Set<UUID> = []
    private var recordedTraceOrder: [UUID] = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        let loaded = Self.load(from: self.fileURL)
        self.document = loaded.document
        if loaded.shouldPersist {
            scheduleWrite()
        }
    }

    func snapshot() -> DiagnosticsDocument {
        document
    }

    func report(now: Date = Date()) -> String {
        DiagnosticsFormatter.report(document: document, today: Self.dayKey(for: now))
    }

    /// Records one terminal trace. Repeated calls with the same trace ID are
    /// ignored, which protects counters from timeout/late-result races.
    @discardableResult
    func record(
        trace: TranscriptionTrace,
        outcome: TranscriptionTrace.Outcome,
        text: String? = nil
    ) -> Task<Bool, Never> {
        guard recordedTraceIDs.insert(trace.id).inserted else {
            return Task { true }
        }
        recordedTraceOrder.append(trace.id)
        if recordedTraceOrder.count > Self.maxLatencySamples * 2 {
            let removed = recordedTraceOrder.removeFirst()
            recordedTraceIDs.remove(removed)
        }

        let wordCount = text?.split(whereSeparator: { $0.isWhitespace }).count ?? 0
        let characterCount = text?.count ?? 0
        document.lifetime.record(
            backend: trace.backend,
            outcome: outcome,
            wordCount: wordCount,
            characterCount: characterCount
        )

        let day = Self.dayKey(for: Date())
        if let index = document.dailyBuckets.firstIndex(where: { $0.day == day }) {
            document.dailyBuckets[index].aggregate.record(
                backend: trace.backend,
                outcome: outcome,
                wordCount: wordCount,
                characterCount: characterCount
            )
        } else {
            document.dailyBuckets.append(
                DailyStats(
                    day: day,
                    aggregate: Self.aggregate(
                        backend: trace.backend,
                        outcome: outcome,
                        wordCount: wordCount,
                        characterCount: characterCount
                    )
                )
            )
            if document.dailyBuckets.count > Self.maxDailyBuckets {
                document.dailyBuckets.removeFirst(document.dailyBuckets.count - Self.maxDailyBuckets)
            }
        }

        let sample = LatencySample(timings: trace.timingSnapshot)
        if !sample.isEmpty {
            document.latencySamples.append(sample)
            if document.latencySamples.count > Self.maxLatencySamples {
                document.latencySamples.removeFirst(
                    document.latencySamples.count - Self.maxLatencySamples
                )
            }
        }

        return scheduleWrite()
    }

    private static func aggregate(
        backend: String,
        outcome: TranscriptionTrace.Outcome,
        wordCount: Int,
        characterCount: Int
    ) -> AggregateStats {
        var aggregate = AggregateStats()
        aggregate.record(
            backend: backend,
            outcome: outcome,
            wordCount: wordCount,
            characterCount: characterCount
        )
        return aggregate
    }

    @discardableResult
    private func scheduleWrite() -> Task<Bool, Never> {
        let snapshot = document
        let url = fileURL
        return writer.enqueue { [logger] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                logger.error("Failed to persist diagnostics: \(String(describing: error))")
                return false
            }
        }
    }

    private struct LoadResult {
        let document: DiagnosticsDocument
        let shouldPersist: Bool
    }

    private static func load(from url: URL) -> LoadResult {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(DiagnosticsDocument.self, from: data),
            (1...DiagnosticsDocument.currentSchemaVersion).contains(decoded.schemaVersion)
        else {
            return LoadResult(document: DiagnosticsDocument(), shouldPersist: false)
        }

        var bounded = DiagnosticsDocument(
            lifetime: decoded.lifetime,
            dailyBuckets: decoded.dailyBuckets,
            latencySamples: decoded.latencySamples
        )
        if bounded.dailyBuckets.count > maxDailyBuckets {
            bounded.dailyBuckets = Array(bounded.dailyBuckets.suffix(maxDailyBuckets))
        }
        if bounded.latencySamples.count > maxLatencySamples {
            bounded.latencySamples = Array(bounded.latencySamples.suffix(maxLatencySamples))
        }
        return LoadResult(document: bounded, shouldPersist: bounded != decoded)
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        return base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("stats.json")
    }
}
