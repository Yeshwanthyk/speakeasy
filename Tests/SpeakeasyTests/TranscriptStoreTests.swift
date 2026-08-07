import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-transcript-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func waitUntil(timeout: TimeInterval = 1.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func decodedHistory(at url: URL) -> [TranscriptRecord]? {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(TranscriptHistoryDocument.self, from: data)
        else {
            return nil
        }
        return decoded.records
    }

    func testAppendEvictsOldestEntriesPastCapacity() {
        let store = TranscriptStore(fileURL: temporaryHistoryURL())

        for index in 0..<55 {
            store.append("entry-\(index)")
        }

        let entries = store.allEntries()
        XCTAssertEqual(entries.count, TranscriptStore.capacity)
        XCTAssertEqual(entries.first, "entry-5")
        XCTAssertEqual(entries.last, "entry-54")
    }

    func testAppendPersistsAndReloadsHistory() {
        let url = temporaryHistoryURL()
        let store = TranscriptStore(fileURL: url)

        store.append("alpha")
        store.append("beta")

        XCTAssertTrue(waitUntil { decodedHistory(at: url)?.map(\.finalText) == ["alpha", "beta"] })
        XCTAssertEqual(TranscriptStore(fileURL: url).allEntries(), ["alpha", "beta"])
    }

    func testAppendResultCompletesAfterDiskWrite() async {
        let url = temporaryHistoryURL()
        let store = TranscriptStore(fileURL: url)

        let persisted = await store.append("durable").value

        XCTAssertTrue(persisted)
        XCTAssertEqual(decodedHistory(at: url)?.map(\.finalText), ["durable"])
    }

    func testAppendReportsDiskFailureButRetainsInMemoryEntry() async throws {
        let blockedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-transcript-store-blocker-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: blockedParent)
        let store = TranscriptStore(fileURL: blockedParent.appendingPathComponent("history.json"))

        let persisted = await store.append("recoverable").value

        XCTAssertFalse(persisted)
        XCTAssertEqual(store.allEntries(), ["recoverable"])
    }

    func testMalformedJSONLoadsAsEmptyHistory() throws {
        let url = temporaryHistoryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        let store = TranscriptStore(fileURL: url)

        XCTAssertTrue(store.allEntries().isEmpty)
    }

    func testMissingCanonicalHistoryLoadsAndMigratesLegacyHistory() throws {
        let currentURL = temporaryHistoryURL()
        let legacyURL = temporaryHistoryURL()
        let legacyEntries = ["one", "two"]
        let data = try JSONEncoder().encode(legacyEntries)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: legacyURL)

        let store = TranscriptStore(fileURL: currentURL, legacyFileURL: legacyURL)

        XCTAssertEqual(store.allEntries(), legacyEntries)
        XCTAssertTrue(waitUntil { decodedHistory(at: currentURL)?.map(\.finalText) == legacyEntries })
    }

    func testLoadedHistoryIsTruncatedToCapacity() throws {
        let url = temporaryHistoryURL()
        let entries = (0..<60).map { "entry-\($0)" }
        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let store = TranscriptStore(fileURL: url)

        XCTAssertEqual(store.allEntries().count, TranscriptStore.capacity)
        XCTAssertEqual(store.allEntries().first, "entry-10")
        XCTAssertEqual(store.allEntries().last, "entry-59")
    }

    func testClearRemovesEntriesAndPersistsEmptyHistory() {
        let url = temporaryHistoryURL()
        let store = TranscriptStore(fileURL: url)

        store.append("alpha")
        XCTAssertTrue(waitUntil { decodedHistory(at: url)?.map(\.finalText) == ["alpha"] })

        store.clear()

        XCTAssertTrue(store.allEntries().isEmpty)
        XCTAssertTrue(waitUntil { decodedHistory(at: url)?.isEmpty == true })
    }

    func testLegacyMigrationPreservesRecordFieldsAndWritesEnvelope() throws {
        let currentURL = temporaryHistoryURL()
        let legacyURL = temporaryHistoryURL()
        let legacyEntries = ["oldest", "newest"]
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(legacyEntries).write(to: legacyURL)

        let store = TranscriptStore(fileURL: currentURL, legacyFileURL: legacyURL)

        XCTAssertEqual(store.allRecords().map(\.finalText), legacyEntries)
        XCTAssertEqual(store.allRecords().map(\.rawText), legacyEntries)
        XCTAssertTrue(store.allRecords().allSatisfy { $0.backend == "unknown" })
        XCTAssertTrue(store.allRecords().allSatisfy { $0.outcome == .eventsPosted })
        XCTAssertTrue(waitUntil {
            guard let data = try? Data(contentsOf: currentURL),
                  let document = try? JSONDecoder().decode(TranscriptHistoryDocument.self, from: data)
            else { return false }
            return document.schemaVersion == 1 && document.records.count == 2
        })
    }

    func testMalformedCanonicalDoesNotResurrectLegacyFallback() throws {
        let currentURL = temporaryHistoryURL()
        let legacyURL = temporaryHistoryURL()
        try FileManager.default.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: currentURL)
        try JSONEncoder().encode(["legacy must stay unused"]).write(to: legacyURL)

        let store = TranscriptStore(fileURL: currentURL, legacyFileURL: legacyURL)

        XCTAssertTrue(store.allEntries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: currentURL), Data("not-json".utf8))
    }

    func testRecordOutcomeAndTimingsUpdateDurably() async {
        let url = temporaryHistoryURL()
        let store = TranscriptStore(fileURL: url)
        let timings = TimingSnapshot(
            captureStartMs: 1,
            releaseToStopMs: 2,
            transcriptionMs: 3,
            releaseToTextMs: 4,
            releaseToPasteMs: nil,
            transcriptionEndToPasteMs: nil,
            utteranceMs: 5
        )
        let record = TranscriptRecord(
            rawText: "raw",
            finalText: "final",
            backend: "parakeet-unified-en",
            outcome: .transcriptPersisted,
            timings: timings
        )

        let appendSucceeded = await store.append(record).value
        let updateSucceeded = await store.update(
            id: record.id,
            outcome: .eventsPosted,
            timings: timings
        ).value
        XCTAssertTrue(appendSucceeded)
        XCTAssertTrue(updateSucceeded)

        let reloaded = TranscriptStore(fileURL: url)
        XCTAssertEqual(reloaded.allRecords().first?.rawText, "raw")
        XCTAssertEqual(reloaded.allRecords().first?.finalText, "final")
        XCTAssertEqual(reloaded.allRecords().first?.backend, "parakeet-unified-en")
        XCTAssertEqual(reloaded.allRecords().first?.outcome, .eventsPosted)
        XCTAssertEqual(reloaded.allRecords().first?.timings, timings)
    }
}
