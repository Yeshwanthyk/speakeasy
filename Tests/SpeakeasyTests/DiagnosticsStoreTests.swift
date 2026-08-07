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
}
