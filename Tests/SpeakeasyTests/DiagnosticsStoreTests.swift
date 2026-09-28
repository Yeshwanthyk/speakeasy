import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class DiagnosticsStoreTests: XCTestCase {
    private func temporaryStatsURL() -> URL {
        testScratchDirectory
            .appendingPathComponent("speakeasy-diagnostics-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    private func trace(
        id: UUID = UUID(),
        backend: String = "parakeet-unified-en",
        withTimings: Bool = true
    ) -> TranscriptionTrace {
        var trace = TranscriptionTrace(id: id, hotkeyPressedAt: 1_000_000, backend: backend)
        if withTimings {
            trace.markCaptureStarted(at: 2_000_000)
            trace.markHotkeyReleased(at: 3_000_000)
            trace.markStopReturned(sampleCount: 32_000, at: 3_500_000)
            trace.markTranscriptionStarted(at: 4_000_000)
            trace.markTranscriptionEnded(at: 8_000_000)
            trace.markPasteRequested(at: 9_000_000)
        }
        return trace
    }

    func testRecordsAreDeduplicatedByTraceID() async {
        let store = DiagnosticsStore(fileURL: temporaryStatsURL())
        let trace = trace()

        let firstWrite = await store.record(
            trace: trace,
            outcome: .eventsPosted,
            text: "private phrase"
        ).value
        let duplicateWrite = await store.record(
            trace: trace,
            outcome: .eventsPosted,
            text: "private phrase"
        ).value
        XCTAssertTrue(firstWrite)
        XCTAssertTrue(duplicateWrite)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.lifetime.attemptCount, 1)
        XCTAssertEqual(snapshot.lifetime.outcomes.eventsPosted, 1)
        XCTAssertEqual(snapshot.latencySamples.count, 1)
    }

    func testPersistenceIsBoundedAndContainsNoDictatedContent() async throws {
        let url = temporaryStatsURL()
        let store = DiagnosticsStore(fileURL: url)
        let canary = "DICTATED-PRIVATE-CANARY-7F4A"

        var lastWrite: Task<Bool, Never>?
        for index in 0..<300 {
            lastWrite = store.record(
                trace: trace(id: UUID(), withTimings: true),
                outcome: index.isMultiple(of: 2) ? .eventsPosted : .noSpeech,
                text: canary
            )
        }
        let writeResult = await lastWrite?.value
        XCTAssertEqual(writeResult, true)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.lifetime.attemptCount, 300)
        XCTAssertEqual(snapshot.latencySamples.count, DiagnosticsStore.maxLatencySamples)
        XCTAssertLessThanOrEqual(snapshot.dailyBuckets.count, DiagnosticsStore.maxDailyBuckets)
        XCTAssertFalse(store.report().contains(canary))

        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(persisted.contains(canary))
        XCTAssertFalse(persisted.contains("rawText"))
        XCTAssertFalse(persisted.contains("finalText"))
    }

    func testMalformedStatsLoadAsEmptyAndDoNotLeakFallbackContent() throws {
        let url = temporaryStatsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("malformed DICTATED-PRIVATE-CANARY".utf8).write(to: url)

        let store = DiagnosticsStore(fileURL: url)

        XCTAssertEqual(store.snapshot(), DiagnosticsDocument())
        XCTAssertFalse(store.report().contains("DICTATED-PRIVATE-CANARY"))
    }

    func testUnreadableStatsAreSetAsideAndSurviveTheNextRecord() async throws {
        let url = temporaryStatsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = #"{"schemaVersion":4,"lifetime":{}}"#
        try Data(newer.utf8).write(to: url)

        let store = DiagnosticsStore(fileURL: url)
        let didPersist = await store.record(trace: trace(), outcome: .eventsPosted, text: "one").value

        XCTAssertTrue(didPersist)
        XCTAssertEqual(store.snapshot().lifetime.attemptCount, 1)
        let setAside = PersistedDocumentFile.invalidFileURL(for: url)
        XCTAssertEqual(try String(contentsOf: setAside, encoding: .utf8), newer)
    }

    func testOutOfRangeCountersAreRejected() {
        func error(_ lifetime: String, days: String = "[]") -> PersistedDocumentError? {
            let json = #"{"schemaVersion":3,"lifetime":\#(lifetime),"dailyBuckets":\#(days),"latencySamples":[]}"#
            do {
                _ = try DiagnosticsDocument.validated(from: Data(json.utf8))
                return nil
            } catch {
                return error as? PersistedDocumentError
            }
        }

        XCTAssertNil(error("{}"))
        XCTAssertEqual(error(#"{"wordCount":-1}"#), .outOfRange)
        XCTAssertEqual(error(#"{"speakingDurationMs":-5}"#), .outOfRange)
        // Summing Int.max counters used to trap in the Settings stats page.
        XCTAssertEqual(error(#"{"outcomes":{"timedOut":9223372036854775807,"cancelled":1}}"#), .outOfRange)
        XCTAssertEqual(error("{}", days: #"[{"day":"2026-09-28","aggregate":{"attemptCount":-2}}]"#), .outOfRange)
        XCTAssertEqual(error(#"{"wordCount":1e999}"#), .malformed)
        XCTAssertEqual(error(#""nope""#), .malformed)
    }

    func testLoadKeepsTheFirstBucketForARepeatedDayAndRecordsIntoIt() async throws {
        let url = temporaryStatsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let today = SettingsInsights.dayKey(for: now, calendar: .current)
        var first = AggregateStats()
        first.attemptCount = 2
        var second = AggregateStats()
        second.attemptCount = 7
        let document = DiagnosticsDocument(dailyBuckets: [
            DailyStats(day: today, aggregate: first),
            DailyStats(day: today, aggregate: second)
        ])
        try JSONEncoder().encode(document).write(to: url)

        let store = DiagnosticsStore(fileURL: url)
        XCTAssertEqual(store.snapshot().dailyBuckets.map(\.aggregate.attemptCount), [2])

        _ = await store.record(trace: trace(), outcome: .eventsPosted, text: "hi", now: now).value
        XCTAssertEqual(store.snapshot().dailyBuckets.map(\.aggregate.attemptCount), [3])
        XCTAssertEqual(store.productivitySummary(now: now).todayDictations, 3)
        XCTAssertEqual(SettingsInsights.make(document: store.snapshot(), now: now).days.last?.dictations, 3)
    }

    func testDailyBucketsRollOverAndKeepTheNewestDays() async {
        let store = DiagnosticsStore(fileURL: temporaryStatsURL())
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var lastWrite: Task<Bool, Never>?
        for day in 0..<40 {
            lastWrite = store.record(
                trace: trace(withTimings: false),
                outcome: .noSpeech,
                now: start.addingTimeInterval(Double(day) * 86_400)
            )
        }
        _ = await lastWrite?.value

        let days = store.snapshot().dailyBuckets.map(\.day)
        XCTAssertEqual(days.count, DiagnosticsStore.maxDailyBuckets)
        XCTAssertEqual(Set(days).count, days.count)
        XCTAssertEqual(days.last, SettingsInsights.dayKey(for: start.addingTimeInterval(39 * 86_400), calendar: .current))
        XCTAssertEqual(store.snapshot().lifetime.attemptCount, 40)
        XCTAssertTrue(store.snapshot().latencySamples.isEmpty)
    }

    func testReloadTrimsOversizedDocumentsToTheStoreCaps() throws {
        let url = temporaryStatsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = DiagnosticsDocument(
            dailyBuckets: (0..<40).map { DailyStats(day: "day-\($0)", aggregate: AggregateStats()) },
            latencySamples: (0..<300).map {
                LatencySample(captureStartMs: Double($0), releaseToTextMs: nil, releaseToPasteMs: nil)
            }
        )
        try JSONEncoder().encode(document).write(to: url)

        let snapshot = DiagnosticsStore(fileURL: url).snapshot()

        XCTAssertEqual(snapshot.dailyBuckets.first?.day, "day-9")
        XCTAssertEqual(snapshot.dailyBuckets.count, DiagnosticsStore.maxDailyBuckets)
        XCTAssertEqual(snapshot.latencySamples.first?.captureStartMs, 44)
        XCTAssertEqual(snapshot.latencySamples.count, DiagnosticsStore.maxLatencySamples)
    }

    func testMissingCounterKeysDefaultToZero() throws {
        let counters = try JSONDecoder().decode(BackendCounters.self, from: Data("{}".utf8))
        XCTAssertEqual(counters, BackendCounters())
        let outcomes = try JSONDecoder().decode(OutcomeCounters.self, from: Data(#"{"noSpeech":3}"#.utf8))
        var expected = OutcomeCounters()
        expected.noSpeech = 3
        XCTAssertEqual(outcomes, expected)
    }

    func testBackendCountersOnlyCountCurrentNames() {
        var counters = BackendCounters()
        counters.increment("parakeet-tdt-ctc-110m")
        counters.increment("parakeet-unified-en")
        counters.increment("nemotron")
        XCTAssertEqual(counters.parakeet110M, 1)
        XCTAssertEqual(counters.parakeetUnified, 1)
        XCTAssertEqual(counters.unknown, 1)
    }

    func testFormatterComputesPercentilesOnlyFromBoundedNumericSamples() {
        var document = DiagnosticsDocument()
        document.lifetime.attemptCount = 2
        document.lifetime.deliveryCount = 1
        document.latencySamples = [
            LatencySample(
                captureStartMs: 1,
                releaseToTextMs: 10,
                releaseToPasteMs: 20
            ),
            LatencySample(
                captureStartMs: 2,
                releaseToTextMs: 20,
                releaseToPasteMs: 30
            ),
            LatencySample(
                captureStartMs: 3,
                releaseToTextMs: 30,
                releaseToPasteMs: 40
            )
        ]

        let report = DiagnosticsFormatter.report(document: document, today: "2026-08-06")

        XCTAssertTrue(report.contains("Lifetime: 2 attempts, 50% delivered"))
        XCTAssertTrue(report.contains("Release to text: p50 20.0 ms, p95 30.0 ms"))
    }

    func testProductivitySummaryComparesMeasuredSpeechWithSeventyWPMTyping() {
        var document = DiagnosticsDocument()
        document.lifetime.attemptCount = 10
        document.lifetime.deliveryCount = 9
        document.lifetime.wordCount = 140
        document.lifetime.measuredWordCount = 70
        document.lifetime.speakingDurationMs = 30_000

        var today = AggregateStats()
        today.attemptCount = 3
        today.wordCount = 42
        document.dailyBuckets = [DailyStats(day: "2026-08-07", aggregate: today)]
        document.latencySamples = [
            LatencySample(captureStartMs: nil, releaseToTextMs: 280, releaseToPasteMs: nil),
            LatencySample(captureStartMs: nil, releaseToTextMs: 440, releaseToPasteMs: nil)
        ]

        let summary = DiagnosticsFormatter.summary(document: document, today: "2026-08-07")

        XCTAssertEqual(summary.lifetimeWords, 140)
        XCTAssertEqual(summary.todayWords, 42)
        XCTAssertEqual(summary.deliveryRate, 0.9)
        XCTAssertEqual(summary.estimatedTypingDurationMs, 120_000, accuracy: 0.001)
        XCTAssertEqual(summary.speakingDurationMs, 58_000, accuracy: 0.001)
        XCTAssertEqual(summary.timeSavedMs, 62_000, accuracy: 0.001)
        XCTAssertTrue(summary.usesEstimatedSpeakingDuration)
        XCTAssertEqual(summary.releaseToTextP50Ms, 440)
        XCTAssertEqual(summary.releaseToTextP95Ms, 440)
    }

    func testRecordingDeliveredWordsAccumulatesMeasuredSpeakingDuration() async {
        let store = DiagnosticsStore(fileURL: temporaryStatsURL())

        _ = await store.record(
            trace: trace(),
            outcome: .eventsPosted,
            text: "one two three four five"
        ).value

        let aggregate = store.snapshot().lifetime
        XCTAssertEqual(aggregate.wordCount, 5)
        XCTAssertEqual(aggregate.measuredWordCount, 5)
        XCTAssertEqual(aggregate.speakingDurationMs, 2_000, accuracy: 0.001)
    }
}
