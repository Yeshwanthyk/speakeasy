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
    var measuredWordCount = 0
    var speakingDurationMs: Double = 0
    var outcomes = OutcomeCounters()
    var backends = BackendCounters()

    init() {}

    mutating func record(
        backend: String,
        outcome: TranscriptionTrace.Outcome,
        wordCount: Int,
        characterCount: Int,
        speakingDurationMs: Double?
    ) {
        attemptCount += 1
        if outcome == .eventsPosted || outcome == .clipboardUpdated {
            deliveryCount += 1
        }
        self.wordCount += wordCount
        self.characterCount += characterCount
        if let speakingDurationMs,
           speakingDurationMs.isFinite,
           speakingDurationMs > 0,
           wordCount > 0 {
            measuredWordCount += wordCount
            self.speakingDurationMs += speakingDurationMs
        }
        outcomes.increment(outcome)
        backends.increment(backend)
    }

    private enum CodingKeys: String, CodingKey {
        case attemptCount
        case deliveryCount
        case wordCount
        case characterCount
        case measuredWordCount
        case speakingDurationMs
        case outcomes
        case backends
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        deliveryCount = try container.decodeIfPresent(Int.self, forKey: .deliveryCount) ?? 0
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? 0
        measuredWordCount = try container.decodeIfPresent(Int.self, forKey: .measuredWordCount) ?? 0
        speakingDurationMs = try container.decodeIfPresent(Double.self, forKey: .speakingDurationMs) ?? 0
        outcomes = try container.decodeIfPresent(OutcomeCounters.self, forKey: .outcomes) ?? OutcomeCounters()
        backends = try container.decodeIfPresent(BackendCounters.self, forKey: .backends) ?? BackendCounters()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encode(deliveryCount, forKey: .deliveryCount)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(characterCount, forKey: .characterCount)
        try container.encode(measuredWordCount, forKey: .measuredWordCount)
        try container.encode(speakingDurationMs, forKey: .speakingDurationMs)
        try container.encode(outcomes, forKey: .outcomes)
        try container.encode(backends, forKey: .backends)
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
    static let currentSchemaVersion = 3

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

struct ProductivitySummary: Equatable, Sendable {
    static let typingWordsPerMinute = 70.0
    static let estimatedSpeakingWordsPerMinute = 150.0

    let lifetimeWords: Int
    let lifetimeDictations: Int
    let todayWords: Int
    let todayDictations: Int
    let deliveryRate: Double?
    let estimatedTypingDurationMs: Double
    let speakingDurationMs: Double
    let timeSavedMs: Double
    let usesEstimatedSpeakingDuration: Bool
    let releaseToTextP50Ms: Double?
    let releaseToTextP95Ms: Double?
}

enum DiagnosticsFormatter {
    static func summary(document: DiagnosticsDocument, today: String) -> ProductivitySummary {
        let todayStats = document.dailyBuckets.first(where: { $0.day == today })?.aggregate
            ?? AggregateStats()
        let lifetime = document.lifetime
        let measuredWords = min(max(lifetime.measuredWordCount, 0), lifetime.wordCount)
        let unmeasuredWords = max(lifetime.wordCount - measuredWords, 0)
        let estimatedUnmeasuredSpeechMs = Double(unmeasuredWords)
            / ProductivitySummary.estimatedSpeakingWordsPerMinute
            * 60_000
        let speakingDurationMs = max(lifetime.speakingDurationMs, 0) + estimatedUnmeasuredSpeechMs
        let typingDurationMs = Double(lifetime.wordCount)
            / ProductivitySummary.typingWordsPerMinute
            * 60_000

        let deliveryRate: Double?
        if lifetime.attemptCount == 0 {
            deliveryRate = nil
        } else {
            deliveryRate = Double(lifetime.deliveryCount) / Double(lifetime.attemptCount)
        }

        return ProductivitySummary(
            lifetimeWords: lifetime.wordCount,
            lifetimeDictations: lifetime.attemptCount,
            todayWords: todayStats.wordCount,
            todayDictations: todayStats.attemptCount,
            deliveryRate: deliveryRate,
            estimatedTypingDurationMs: typingDurationMs,
            speakingDurationMs: speakingDurationMs,
            timeSavedMs: max(typingDurationMs - speakingDurationMs, 0),
            usesEstimatedSpeakingDuration: unmeasuredWords > 0,
            releaseToTextP50Ms: percentile(
                0.50,
                values: document.latencySamples.compactMap(\.releaseToTextMs)
            ),
            releaseToTextP95Ms: percentile(
                0.95,
                values: document.latencySamples.compactMap(\.releaseToTextMs)
            )
        )
    }

    static func report(document: DiagnosticsDocument, today: String) -> String {
        let summary = summary(document: document, today: today)
        let successRate = summary.deliveryRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"

        return [
            "Today: \(summary.todayDictations) attempts, \(summary.todayWords) words",
            "Lifetime: \(summary.lifetimeDictations) attempts, \(successRate) delivered",
            "Release to text: p50 \(formatted(summary.releaseToTextP50Ms)) ms, p95 \(formatted(summary.releaseToTextP95Ms)) ms"
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

    func productivitySummary(now: Date = Date()) -> ProductivitySummary {
        DiagnosticsFormatter.summary(document: document, today: Self.dayKey(for: now))
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
        let timings = trace.timingSnapshot
        let activeSpeakingDurationMs = max(
            trace.utteranceDurationMs
                - trace.prependedDurationMs
                - (trace.graceDurationMs ?? 0),
            0
        )
        let speakingDurationMs = wordCount > 0 ? activeSpeakingDurationMs : nil
        document.lifetime.record(
            backend: trace.backend,
            outcome: outcome,
            wordCount: wordCount,
            characterCount: characterCount,
            speakingDurationMs: speakingDurationMs
        )

        let day = Self.dayKey(for: Date())
        if let index = document.dailyBuckets.firstIndex(where: { $0.day == day }) {
            document.dailyBuckets[index].aggregate.record(
                backend: trace.backend,
                outcome: outcome,
                wordCount: wordCount,
                characterCount: characterCount,
                speakingDurationMs: speakingDurationMs
            )
        } else {
            document.dailyBuckets.append(
                DailyStats(
                    day: day,
                    aggregate: Self.aggregate(
                        backend: trace.backend,
                        outcome: outcome,
                        wordCount: wordCount,
                        characterCount: characterCount,
                        speakingDurationMs: speakingDurationMs
                    )
                )
            )
            if document.dailyBuckets.count > Self.maxDailyBuckets {
                document.dailyBuckets.removeFirst(document.dailyBuckets.count - Self.maxDailyBuckets)
            }
        }

        let sample = LatencySample(timings: timings)
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
        characterCount: Int,
        speakingDurationMs: Double?
    ) -> AggregateStats {
        var aggregate = AggregateStats()
        aggregate.record(
            backend: backend,
            outcome: outcome,
            wordCount: wordCount,
            characterCount: characterCount,
            speakingDurationMs: speakingDurationMs
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
