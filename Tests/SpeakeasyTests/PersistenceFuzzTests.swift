import Foundation
import XCTest
@testable import Speakeasy

/// Fuzz targets for the files the app reads back from Application Support.
/// See `Support/Fuzzing.swift` for the harness and `Fuzz/Corpus/` for seeds.
final class PersistenceFuzzTests: XCTestCase {
    private static let jsonTokens = [
        "\"schemaVersion\":", "1", "2", "3", "4", "-1", "0", "1e999", "9223372036854775807",
        "-9223372036854775808", "0.5", "null", "true", "false", "[]", "{}", ",", "\"\"",
        "\\u0000", "\\ud800", "\"0F1D2C3B-4A59-6877-8695-A4B3C2D1E0F9\"",
    ]

    /// `history.json`: decoding never traps, and anything accepted
    /// re-encodes to an equal document.
    func testFuzzHistoryDocument() {
        fuzz("history-json", dictionary: Self.jsonTokens + [
            "\"records\":", "\"createdAt\":", "\"rawText\":", "\"finalText\":", "\"outcome\":",
            "\"eventsPosted\"", "\"timings\":", "\"stageChanges\":", "\"correctionsUndone\":",
        ]) { data in
            guard let records = try? TranscriptHistoryDocument.validatedRecords(from: data) else { return }
            let encoded = try JSONEncoder().encode(TranscriptHistoryDocument(records: records))
            let decoded = try TranscriptHistoryDocument.validatedRecords(from: encoded)
            try fuzzCheck(decoded == records, "history round-trip changed records")
        }
    }

    /// `stats.json`: anything accepted is in range, within the caps, has
    /// unique days, renders the Settings stats without trapping, and
    /// round-trips unchanged.
    func testFuzzDiagnosticsDocument() {
        fuzz("stats-json", dictionary: Self.jsonTokens + [
            "\"lifetime\":", "\"dailyBuckets\":", "\"latencySamples\":", "\"aggregate\":",
            "\"day\":", "\"2026-09-28\"", "\"attemptCount\":", "\"wordCount\":", "\"outcomes\":",
            "\"timedOut\":", "\"speakingDurationMs\":", "\"releaseToTextMs\":", "\"backends\":",
        ]) { data in
            guard let document = try? DiagnosticsDocument.validated(from: data) else { return }
            let aggregates = [document.lifetime] + document.dailyBuckets.map(\.aggregate)
            try fuzzCheck(aggregates.allSatisfy(\.isInStoredRange), "accepted out-of-range counters")
            try fuzzCheck(document.dailyBuckets.count <= DiagnosticsStore.maxDailyBuckets, "too many buckets")
            try fuzzCheck(document.latencySamples.count <= DiagnosticsStore.maxLatencySamples, "too many samples")
            try fuzzCheck(
                Set(document.dailyBuckets.map(\.day)).count == document.dailyBuckets.count,
                "repeated day survived load"
            )

            _ = SettingsInsights.make(document: document, now: Date(timeIntervalSince1970: 1_790_000_000))
            _ = DiagnosticsFormatter.report(document: document, today: "2026-09-28")

            let encoded = try JSONEncoder().encode(document)
            let decoded = try DiagnosticsDocument.validated(from: encoded)
            try fuzzCheck(decoded == document, "stats round-trip changed")
        }
    }

    /// `dictation-e2e.jsonl`: parsing never traps, and the surviving
    /// records re-serialize to a clean log that parses back identically.
    func testFuzzE2ETraceLog() {
        fuzz("e2e-jsonl", dictionary: Self.jsonTokens + [
            "\n", "\"id\":", "\"recorded_at\":", "\"succeeded\":", "\"utterance_ms\":",
            "\"stage_change_counts\":", "\"segment_count\":", "\"outcome\":", "\"backend\":",
        ]) { data in
            let parsed = E2ETraceStore.parse(data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            var rewritten = Data()
            for record in parsed.records {
                rewritten.append(try encoder.encode(record))
                rewritten.append(0x0A)
            }
            let reparsed = E2ETraceStore.parse(rewritten)
            try fuzzCheck(reparsed.isClean, "rewritten log is not clean")
            try fuzzCheck(reparsed.records == parsed.records, "rewritten log changed records")
            _ = E2ESummarizer.summarize(parsed.records)
        }
    }
}
