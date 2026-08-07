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

    func testInvalidReplacementDoesNotChangeInMemoryCorrections() throws {
        let store = TranscriptCorrectionStore(fileURL: temporaryURL())
        let original = [TranscriptCorrection(heard: "alpha", written: "beta")]
        _ = try store.replace(original)

        XCTAssertThrowsError(try store.replace([
            TranscriptCorrection(heard: "alpha", written: "one"),
            TranscriptCorrection(heard: "ALPHA", written: "two")
        ]))
        XCTAssertEqual(store.allCorrections(), original)
    }
}
