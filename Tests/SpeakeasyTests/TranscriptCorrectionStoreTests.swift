import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class TranscriptCorrectionStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-corrections-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("corrections.json")
    }

    func testReplacementPersistsVersionedCorrections() async throws {
        let url = temporaryURL()
        let store = TranscriptCorrectionStore(fileURL: url)
        let corrections = [TranscriptCorrection(heard: "my project", written: "Wisp")]

        let persisted = try await store.replace(corrections).value

        XCTAssertTrue(persisted)
        XCTAssertEqual(TranscriptCorrectionStore(fileURL: url).allCorrections(), corrections)
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(TranscriptCorrectionDocument.self, from: data)
        XCTAssertEqual(document.schemaVersion, TranscriptCorrectionDocument.currentSchemaVersion)
    }

    func testFailedPersistenceLeavesLastKnownGoodCorrectionsActive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-corrections-failure-\(UUID().uuidString)")
        let validURL = directory.appendingPathComponent("corrections.json")
        let store = TranscriptCorrectionStore(fileURL: validURL)
        let original = [TranscriptCorrection(heard: "alpha", written: "beta")]
        let didPersistOriginal = try await store.replace(original).value
        XCTAssertTrue(didPersistOriginal)

        try FileManager.default.removeItem(at: validURL)
        try FileManager.default.removeItem(at: directory)
        try Data("not-a-directory".utf8).write(to: directory)

        let didPersistReplacement = try await store.replace([
            TranscriptCorrection(heard: "alpha", written: "gamma")
        ]).value

        XCTAssertFalse(didPersistReplacement)
        XCTAssertEqual(store.allCorrections(), original)
    }

    func testInvalidReplacementDoesNotChangeInMemoryCorrections() async throws {
        let store = TranscriptCorrectionStore(fileURL: temporaryURL())
        let original = [TranscriptCorrection(heard: "alpha", written: "beta")]
        let didPersist = try await store.replace(original).value
        XCTAssertTrue(didPersist)

        XCTAssertThrowsError(try store.replace([
            TranscriptCorrection(heard: "alpha", written: "one"),
            TranscriptCorrection(heard: "ALPHA", written: "two")
        ]))
        XCTAssertEqual(store.allCorrections(), original)
    }
}
