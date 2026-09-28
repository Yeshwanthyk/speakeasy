import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class DiagnosticsStoreTests: XCTestCase {
    private func temporaryStatsURL() -> URL {
        FileManager.default.temporaryDirectory
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

    func testMissingBackendKeysDefaultToZero() throws {
        let counters = try JSONDecoder().decode(BackendCounters.self, from: Data("{}".utf8))
        XCTAssertEqual(counters, BackendCounters())
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
