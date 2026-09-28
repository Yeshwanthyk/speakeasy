import Foundation
import XCTest
@testable import Speakeasy

/// Generated-input invariants for the on-disk stores. See
/// `Support/PropertyTesting.swift` for seeds and iteration counts.
@MainActor
final class PersistencePropertyTests: XCTestCase {
    // MARK: - Generators

    private static let text = Gen.string(
        from: Array("abc XYZ 019\n\t\"\\/{}[],:") + ["é", "e\u{301}", "\u{0}", "\u{2028}", "👩\u{200D}💻", "🇺🇸"],
        length: 0...24
    )

    private static let outcome = Gen.element(of: TranscriptionTrace.Outcome.allCases)

    private static let milliseconds = Gen<Double?>.frequency([
        (1, .constant(nil)),
        (4, Gen.int(in: -1_000...600_000).map { Double($0) / 7 }),
    ])

    private static let record = genZip(genZip(text, text), genZip(outcome, milliseconds)).map { texts, rest in
        TranscriptRecord(
            createdAt: Date(timeIntervalSinceReferenceDate: rest.1 ?? 0),
            rawText: texts.0,
            finalText: texts.1,
            backend: texts.0.isEmpty ? "parakeet-unified-en" : texts.1,
            outcome: rest.0,
            timings: rest.1.map {
                TimingSnapshot(
                    captureStartMs: $0, releaseToStopMs: nil, transcriptionMs: $0 / 3,
                    releaseToTextMs: nil, releaseToPasteMs: $0 * 2, transcriptionEndToPasteMs: nil,
                    utteranceMs: 0
                )
            },
            stageChanges: texts.0.count.isMultiple(of: 2) ? nil : [StageChange(stage: texts.1, count: texts.0.count)]
        )
    }

    private static let count = Gen.frequency([
        (6, Gen.int(in: 0...1_000)),
        (1, .element(of: [0, DiagnosticsDocument.maxStoredCount])),
    ])

    private static let aggregate = Gen<[Int]>.array(of: count, count: 21...21).map { counts in
        var stats = AggregateStats()
        stats.attemptCount = counts[0]
        stats.deliveryCount = counts[1]
        stats.wordCount = counts[2]
        stats.characterCount = counts[3]
        stats.measuredWordCount = counts[4]
        stats.speakingDurationMs = Double(counts[5]) / 3
        stats.outcomes.eventsPosted = counts[6]
        stats.outcomes.noSpeech = counts[7]
        stats.outcomes.timedOut = counts[8]
        stats.outcomes.accessibilityDenied = counts[9]
        stats.outcomes.cancelled = counts[10]
        stats.outcomes.transcriptionFailed = counts[11]
        stats.outcomes.clipboardUpdated = counts[12]
        stats.outcomes.warmupBlocked = counts[13]
        stats.outcomes.emptyAudio = counts[14]
        stats.outcomes.captureInterrupted = counts[15]
        stats.outcomes.clipboardWriteFailed = counts[16]
        stats.outcomes.transcriptPersisted = counts[17]
        stats.backends.parakeet110M = counts[18]
        stats.backends.parakeetUnified = counts[19]
        stats.backends.unknown = counts[20]
        return stats
    }

    /// Valid stored documents: unique days within the caps.
    private static let diagnosticsDocument = genZip(
        genZip(aggregate, Gen<[Int]>.array(of: .int(in: 0...60), count: 0...40)),
        Gen<[Double?]>.array(of: milliseconds, count: 0...300)
    ).map { head, samples in
        let (lifetime, dayOffsets) = head
        var seen: Set<Int> = []
        let days = dayOffsets.filter { seen.insert($0).inserted }.suffix(DiagnosticsStore.maxDailyBuckets)
        return DiagnosticsDocument(
            lifetime: lifetime,
            dailyBuckets: days.map { DailyStats(day: String(format: "2026-08-%02d", $0), aggregate: lifetime) },
            latencySamples: samples.suffix(DiagnosticsStore.maxLatencySamples).map {
                LatencySample(captureStartMs: nil, releaseToTextMs: $0, releaseToPasteMs: $0.map { $0 + 1 })
            }
        )
    }

    // MARK: - Round trips

    func testHistoryDocumentsRoundTrip() throws {
        forAll(Gen<[TranscriptRecord]>.array(of: Self.record, count: 0...8)) { records in
            guard let data = try? JSONEncoder().encode(TranscriptHistoryDocument(records: records)) else {
                return false
            }
            return (try? TranscriptHistoryDocument.validatedRecords(from: data)) == records
        }
    }

    func testValidDiagnosticsDocumentsRoundTripUnchanged() {
        forAll(Self.diagnosticsDocument) { document in
            guard let data = try? JSONEncoder().encode(document) else { return false }
            return (try? DiagnosticsDocument.validated(from: data)) == document
        }
    }

    func testE2ELogsRoundTripAndTruncationNeverInventsRecords() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let records = genZip(Gen<[Int]>.array(of: .int(in: 0...5_000), count: 0...12), .int(in: 0...10_000))
        forAll(records) { lengths, cut in
            let records = lengths.map { length in
                E2ETraceRecord(
                    id: UUID(), recordedAt: Date(timeIntervalSince1970: Double(length)), backend: "b",
                    outcome: "eventsPosted", succeeded: length.isMultiple(of: 2),
                    deliveredCharacterCount: length, utteranceMs: Double(length) / 3,
                    hotkeyPressToCaptureStartMs: nil, hotkeyReleaseToStopReturnMs: 1,
                    captureStopToTranscriptionStartMs: nil, transcriptionMs: 2,
                    transcriptionEndToPasteRequestMs: nil, hotkeyReleaseToPasteRequestMs: 3,
                    stageChangeCounts: length.isMultiple(of: 3) ? nil : ["commands": length]
                )
            }
            var data = Data()
            for record in records {
                guard let line = try? encoder.encode(record) else { return false }
                data.append(line)
                data.append(0x0A)
            }
            let full = E2ETraceStore.parse(data)
            let truncated = E2ETraceStore.parse(data.prefix(data.isEmpty ? 0 : cut % (data.count + 1)))
            return full.isClean
                && full.records == records
                && truncated.records == Array(records.prefix(truncated.records.count))
        }
    }

    // MARK: - Store state

    func testRecordingKeepsCountersConsistentAndBounded() async {
        let calls = Gen<[Int]>.array(of: .int(in: 0...10_000), count: 0...80)
        forAll(calls, iterations: max(PropertyTesting.iterations / 10, 10)) { seeds in
            let url = testScratchDirectory
                .appendingPathComponent("speakeasy-diagnostics-property/\(UUID().uuidString)/stats.json")
            let store = DiagnosticsStore(fileURL: url)
            let traceIDs = (0..<6).map { _ in UUID() }
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            var uniqueTraces: Set<UUID> = []
            var words = 0
            for seed in seeds {
                let id = traceIDs[seed % traceIDs.count] == traceIDs[0] ? UUID() : traceIDs[seed % traceIDs.count]
                let text = String(repeating: "w ", count: seed % 5)
                if uniqueTraces.insert(id).inserted {
                    words += seed % 5
                }
                var trace = TranscriptionTrace(id: id, hotkeyPressedAt: 0, backend: seed.isMultiple(of: 2) ? "x" : "parakeet-unified-en")
                if seed.isMultiple(of: 3) {
                    trace.markHotkeyReleased(at: 1_000_000)
                    trace.markPasteRequested(at: UInt64(seed) * 1_000_000 + 2_000_000)
                }
                store.record(
                    trace: trace,
                    outcome: TranscriptionTrace.Outcome.allCases[seed % TranscriptionTrace.Outcome.allCases.count],
                    text: text,
                    now: start.addingTimeInterval(Double(seed % 45) * 86_400)
                )
            }
            let document = store.snapshot()
            let days = document.dailyBuckets.map(\.day)
            return document.lifetime.attemptCount == uniqueTraces.count
                && document.lifetime.outcomes.total == uniqueTraces.count
                && document.lifetime.wordCount == words
                && document.lifetime.deliveryCount <= document.lifetime.attemptCount
                && Set(days).count == days.count
                && days.count <= DiagnosticsStore.maxDailyBuckets
                && document.latencySamples.count <= DiagnosticsStore.maxLatencySamples
                && document.dailyBuckets.reduce(0) { $0 + $1.aggregate.attemptCount } <= uniqueTraces.count
        }
    }

    func testHistoryStoreKeepsTheNewestRecordsWithinCapacity() async {
        let appends = Gen<[Int]>.array(of: .int(in: 0...3), count: 0...(TranscriptStore.capacity * 2))
        forAll(appends, iterations: max(PropertyTesting.iterations / 10, 10)) { operations in
            let url = testScratchDirectory
                .appendingPathComponent("speakeasy-history-property/\(UUID().uuidString)/history.json")
            let store = TranscriptStore(fileURL: url)
            var expected: [String] = []
            for (index, operation) in operations.enumerated() {
                if operation == 0, index.isMultiple(of: 7) {
                    store.clear()
                    expected.removeAll()
                } else {
                    store.append("entry \(index)")
                    expected.append("entry \(index)")
                }
            }
            return store.allEntries() == Array(expected.suffix(TranscriptStore.capacity))
        }
    }

    // MARK: - Settings stats

    func testInsightsAreWellFormedForAnyValidDocument() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)))
        forAll(Self.diagnosticsDocument) { document in
            let insights = SettingsInsights.make(document: document, now: now, calendar: calendar)
            let finiteLatencies = document.latencySamples.compactMap(\.releaseToTextMs).count
            let summary = DiagnosticsFormatter.summary(document: document, today: "2026-08-30")
            return insights.days.count == SettingsInsights.chartDayCount
                && insights.days.last?.isToday == true
                && zip(insights.days, insights.days.dropFirst()).allSatisfy { $0.date < $1.date }
                && (0...SettingsInsights.chartDayCount).contains(insights.streakDays)
                && insights.latencySampleCount == finiteLatencies
                && insights.outcomes.allSatisfy { $0.count > 0 }
                && summary.timeSavedMs >= 0
                && summary.deliveryRate.map { $0.isFinite } ?? true
        }
    }
}
