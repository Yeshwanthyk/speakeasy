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

    private func decodedHistory(at url: URL) -> [String]? {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return decoded
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

        XCTAssertTrue(waitUntil { decodedHistory(at: url) == ["alpha", "beta"] })
        XCTAssertEqual(TranscriptStore(fileURL: url).allEntries(), ["alpha", "beta"])
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
        XCTAssertTrue(waitUntil { decodedHistory(at: currentURL) == legacyEntries })
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
        XCTAssertTrue(waitUntil { decodedHistory(at: url) == ["alpha"] })

        store.clear()

        XCTAssertTrue(store.allEntries().isEmpty)
        XCTAssertTrue(waitUntil { decodedHistory(at: url) == [] })
    }
}
