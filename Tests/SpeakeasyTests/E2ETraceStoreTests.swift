import Foundation
import XCTest
@testable import Speakeasy

final class E2ETraceStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = testScratchDirectory
            .appendingPathComponent("speakeasy-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("dictation-e2e.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Record factory gating

    func testCompleteSuccessfulTraceProducesRecord() {
        let trace = completeTrace()
        let record = E2ETraceRecordFactory.record(
            from: trace,
            outcome: .eventsPosted,
            deliveredText: "hello world"
        )
        XCTAssertNotNil(record)
        XCTAssertTrue(record!.succeeded)
        XCTAssertEqual(record!.deliveredCharacterCount, 11)
        XCTAssertEqual(record!.outcome, "eventsPosted")
        XCTAssertEqual(record!.hotkeyReleaseToPasteRequestMs ?? -1, 160.0, accuracy: 0.001)
    }

    func testNativeIdleAndRewarmFieldsPersist() throws {
        var trace = completeTrace()
        trace.idleGapSinceLastNativeInferenceMs = 120_000
        trace.nativeTimings = NativeASRTimings(totalMs: 185, waitMs: 2, audioMs: 1_000)
        trace.rewarmStarted = true
        trace.rewarmInFlightAtFinalStart = true
        let record = try XCTUnwrap(E2ETraceRecordFactory.record(from: trace, outcome: .eventsPosted, deliveredText: "x"))
        let store = E2ETraceStore(fileURL: fileURL)
        store.append(record)
        waitUntilFileContains(count: 1)
        let decoded = try XCTUnwrap(E2ETraceStore(fileURL: fileURL).allRecords().first)
        XCTAssertEqual(decoded.idleGapSinceLastNativeInferenceMs, 120_000)
        XCTAssertEqual(decoded.nativeTotalMs, 185)
        XCTAssertEqual(decoded.nativeWaitMs, 2)
        XCTAssertEqual(decoded.rewarmStarted, true)
        XCTAssertEqual(decoded.rewarmInFlightAtFinalStart, true)
    }

    func testIncompleteSuccessfulTraceIsDropped() {
        var trace = completeTrace()
        trace.pasteRequestedAt = nil
        let record = E2ETraceRecordFactory.record(
            from: trace,
            outcome: .eventsPosted,
            deliveredText: "hello"
        )
        XCTAssertNil(record, "successful outcome without paste milestone must not record")
    }

    func testFailedOutcomeRecordsEvenWhenIncomplete() {
        let trace = TranscriptionTrace(backend: "test")
        let record = E2ETraceRecordFactory.record(from: trace, outcome: .noSpeech, deliveredText: nil)
        XCTAssertNotNil(record)
        XCTAssertFalse(record!.succeeded)
        XCTAssertNil(record!.deliveredCharacterCount)
    }

    func testFailureOutcomesAreNeverMarkedSuccessful() {
        for outcome in [TranscriptionTrace.Outcome.noSpeech, .transcriptionFailed, .timedOut] {
            let record = E2ETraceRecordFactory.record(
                from: completeTrace(),
                outcome: outcome,
                deliveredText: nil
            )
            XCTAssertEqual(record?.succeeded, false, "\(outcome) must not count as success")
        }
    }

    // MARK: - Persistence

    func testAppendPersistsJSONLAndSurvivesReload() {
        let store = E2ETraceStore(fileURL: fileURL)
        let record = E2ETraceRecordFactory.record(
            from: completeTrace(),
            outcome: .clipboardUpdated,
            deliveredText: "persisted"
        )!

        store.append(record)
        waitUntilFileContains(count: 1)

        let reloaded = E2ETraceStore(fileURL: fileURL)
        waitUntil { reloaded.allRecords().count == 1 }
        let decoded = reloaded.allRecords().first
        // JSONL stores wall time at second precision; compare the rest exactly.
        XCTAssertEqual(decoded?.id, record.id)
        XCTAssertEqual(decoded?.backend, record.backend)
        XCTAssertEqual(decoded?.outcome, record.outcome)
        XCTAssertEqual(decoded?.succeeded, record.succeeded)
        XCTAssertEqual(decoded?.deliveredCharacterCount, record.deliveredCharacterCount)
        XCTAssertEqual(decoded?.hotkeyReleaseToPasteRequestMs ?? -1,
                       record.hotkeyReleaseToPasteRequestMs ?? -2, accuracy: 0.001)

        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(raw.split(separator: "\n").count, 1, "one JSON object per line")
    }

    func testExistingJSONLWithoutNewFieldsStillLoads() throws {
        let record = try XCTUnwrap(E2ETraceRecordFactory.record(
            from: completeTrace(), outcome: .eventsPosted, deliveredText: "old"
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        for key in ["idle_gap_since_last_native_inference_ms", "native_total_ms", "native_wait_ms", "rewarm_started", "rewarm_in_flight_at_final_start"] {
            object.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: fileURL)
        XCTAssertEqual(E2ETraceStore(fileURL: fileURL).allRecords().first?.id, record.id)
    }

    func testCorruptLogLoadsWhatItCan() throws {
        let good = E2ETraceRecordFactory.record(from: completeTrace(), outcome: .eventsPosted, deliveredText: "x")!
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let line = String(data: try encoder.encode(good), encoding: .utf8)!
        try "\(line)\nnot json at all\n\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = E2ETraceStore(fileURL: fileURL)
        XCTAssertEqual(store.allRecords().count, 1, "corrupt lines skipped, valid kept")

        store.append(good)
        XCTAssertTrue(waitUntil { E2ETraceStore(fileURL: self.fileURL).allRecords().count == 2 })
    }

    func testTornFinalLineIsRepairedBeforeTheNextAppend() throws {
        let good = try XCTUnwrap(E2ETraceRecordFactory.record(from: completeTrace(), outcome: .eventsPosted, deliveredText: "x"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = try encoder.encode(good)
        data.append(0x0A)
        data.append(contentsOf: Data(#"{"id":"torn-by-a-cra"#.utf8))
        try data.write(to: fileURL)

        let store = E2ETraceStore(fileURL: fileURL)
        XCTAssertEqual(store.allRecords().count, 1)
        store.append(good)

        XCTAssertTrue(waitUntilFileContains(count: 2))
        XCTAssertTrue(E2ETraceStore.parse(try Data(contentsOf: fileURL)).isClean)
        XCTAssertEqual(E2ETraceStore(fileURL: fileURL).allRecords().count, 2)
    }

    func testOversizedLogIsTrimmedOnLoad() throws {
        let record = try XCTUnwrap(E2ETraceRecordFactory.record(from: completeTrace(), outcome: .noSpeech, deliveredText: nil))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let line = try encoder.encode(record) + Data([0x0A])
        try Data((0..<10).flatMap { _ in line }).write(to: fileURL)

        XCTAssertEqual(E2ETraceStore(fileURL: fileURL, maxRecords: 4).allRecords().count, 4)
        XCTAssertEqual(E2ETraceStore.parse(try Data(contentsOf: fileURL)).records.count, 4)
    }

    func testWrapAroundKeepsNewestHalfAndStaysBounded() {
        let store = E2ETraceStore(fileURL: fileURL, maxRecords: 4)

        // Distinct lengths turn character count into an index tag.
        func makeRecord(_ index: Int) -> E2ETraceRecord {
            E2ETraceRecordFactory.record(
                from: completeTrace(),
                outcome: .eventsPosted,
                deliveredText: String(repeating: "x", count: index)
            )!
        }
        for index in 0..<10 {
            store.append(makeRecord(index))
        }

        waitUntil(timeout: 2) { store.allRecords().count >= 2 }
        XCTAssertLessThanOrEqual(store.allRecords().count, 4, "retention stays bounded")
        // Serial appends fill to 4, wrap to 2 at the fifth, reach 4 again,
        // wrap at the eighth, and end at 4: only recent indices survive.
        let indices = Set(store.allRecords().compactMap(\.deliveredCharacterCount))
        XCTAssertTrue(indices.isSuperset(of: [8, 9]) && indices.isSubset(of: [6, 7, 8, 9]), "got \(indices)")
    }

    // MARK: - Summarizer

    func testSummaryUsesSuccessfulPassesOnly() {
        let success = makeRecord(outcome: .eventsPosted, succeeded: true, transcriptionMs: 100)
        let another = makeRecord(outcome: .clipboardUpdated, succeeded: true, transcriptionMs: 300)
        let failure = makeRecord(outcome: .timedOut, succeeded: false, transcriptionMs: 10_000)

        let summary = E2ESummarizer.summarize([success, another, failure])
        XCTAssertEqual(summary.totalPasses, 3)
        XCTAssertEqual(summary.successfulPasses, 2)
        let transcription = summary.segments.first { $0.name == "transcription" }
        XCTAssertEqual(transcription?.medianMs, 200, "median over successes only")
    }

    func testMedianInterpolatesEvenCounts() {
        XCTAssertEqual(E2ESummarizer.median([3, 1, 2]), 2)
        XCTAssertEqual(E2ESummarizer.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(E2ESummarizer.median([]))
    }

    func testSummaryOmitsSegmentsMissingFromAllSuccesses() {
        var record = makeRecord(outcome: .eventsPosted, succeeded: true, transcriptionMs: 5)
        record = E2ETraceRecord(
            id: record.id,
            recordedAt: record.recordedAt,
            backend: record.backend,
            outcome: record.outcome,
            succeeded: record.succeeded,
            deliveredCharacterCount: record.deliveredCharacterCount,
            utteranceMs: record.utteranceMs,
            hotkeyPressToCaptureStartMs: nil,
            hotkeyReleaseToStopReturnMs: nil,
            captureStopToTranscriptionStartMs: nil,
            transcriptionMs: record.transcriptionMs,
            transcriptionEndToPasteRequestMs: nil,
            hotkeyReleaseToPasteRequestMs: nil
        )
        let summary = E2ESummarizer.summarize([record])
        XCTAssertFalse(summary.segments.isEmpty)
        XCTAssertFalse(summary.segments.contains { $0.name == "press_to_capture_start" })
    }

    func testTraceHasStageCountsButNeverTranscriptText() throws {
        var trace = completeTrace()
        trace.stageChanges = [StageChange(stage: "exactCorrections", count: 1)]
        let record = try XCTUnwrap(E2ETraceRecordFactory.record(from: trace, outcome: .eventsPosted,
                                                                 deliveredText: "private spoken words"))
        XCTAssertEqual(record.stageChangeCounts, ["exactCorrections": 1])
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("private spoken words"))
    }

    // MARK: - Helpers

    private func completeTrace() -> TranscriptionTrace {
        completeTrace(id: UUID())
    }

    private func completeTrace(id: UUID) -> TranscriptionTrace {
        var trace = TranscriptionTrace(id: id, hotkeyPressedAt: 0, backend: "test")
        trace.markCaptureStarted(at: 10_000_000)
        trace.markHotkeyReleased(at: 20_000_000)
        trace.markStopReturned(sampleCount: 16_000, prependedSampleCount: 800, graceDurationMs: 12.5, at: 70_000_000)
        trace.markTranscriptionStarted(at: 80_000_000)
        trace.markTranscriptionEnded(at: 130_000_000)
        trace.markPasteRequested(at: 180_000_000)
        return trace
    }

    private func makeRecord(
        outcome: TranscriptionTrace.Outcome,
        succeeded: Bool,
        transcriptionMs: Double?
    ) -> E2ETraceRecord {
        E2ETraceRecord(
            id: UUID(),
            recordedAt: Date(),
            backend: "test",
            outcome: outcome.rawValue,
            succeeded: succeeded,
            deliveredCharacterCount: succeeded ? 5 : nil,
            utteranceMs: 1_000,
            hotkeyPressToCaptureStartMs: 1,
            hotkeyReleaseToStopReturnMs: 2,
            captureStopToTranscriptionStartMs: 3,
            transcriptionMs: transcriptionMs,
            transcriptionEndToPasteRequestMs: 4,
            hotkeyReleaseToPasteRequestMs: 10
        )
    }

    @discardableResult
    private func waitUntilFileContains(count expected: Int, timeout: TimeInterval = 2) -> Bool {
        waitUntil(timeout: timeout) {
            let data = try? Data(contentsOf: self.fileURL)
            return (data?.split(separator: 0x0A).count ?? -1) == expected
        }
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

// MARK: - Native timing surfacing (task: cross-reported FFI timings)

final class NativeASRTimingsTests: XCTestCase {
    func testFieldsRoundTrip() {
        let timings = NativeASRTimings(totalMs: 12.5, waitMs: 0.5, audioMs: 400)
        XCTAssertEqual(timings.totalMs, 12.5)
        XCTAssertEqual(timings.waitMs, 0.5)
        XCTAssertEqual(timings.audioMs, 400)
    }
    func testRealtimeFactorDividesTotalByAudio() {
        let timings = NativeASRTimings(totalMs: 250, waitMs: 10, audioMs: 1000)
        XCTAssertEqual(timings.realtimeFactor, 0.25, accuracy: 0.0001)
    }

    func testRealtimeFactorIsZeroWithoutAudio() {
        let timings = NativeASRTimings(totalMs: 5, waitMs: 0, audioMs: 0)
        XCTAssertEqual(timings.realtimeFactor, 0)
    }

    func testFastRealtimeStaysBelowOne() {
        let timings = NativeASRTimings(totalMs: 80, waitMs: 3, audioMs: 5_000)
        XCTAssertLessThan(timings.realtimeFactor, 1.0)
        XCTAssertEqual(timings.realtimeFactor, 80.0 / 5_000.0, accuracy: 0.0001)
    }
}
