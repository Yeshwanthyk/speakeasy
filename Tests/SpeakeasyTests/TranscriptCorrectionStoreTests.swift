import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class TranscriptCorrectionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = testScratchDirectory
            .appendingPathComponent("speakeasy-corrections-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("corrections.json")
    }

    private func writeFile(_ contents: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
    }

    func testMissingFileLoadsNoCorrections() {
        XCTAssertEqual(TranscriptCorrectionStore(fileURL: fileURL).allCorrections(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReplacementPersistsVersionedCorrections() async throws {
        let store = TranscriptCorrectionStore(fileURL: fileURL)
        let corrections = [TranscriptCorrection(heard: "my project", written: "Wisp")]

        let persisted = try await store.replace(corrections).value

        XCTAssertTrue(persisted)
        XCTAssertEqual(TranscriptCorrectionStore(fileURL: fileURL).allCorrections(), corrections)
        let document = try JSONDecoder().decode(TranscriptCorrectionDocument.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(document.schemaVersion, TranscriptCorrectionDocument.currentSchemaVersion)
    }

    func testSequentialReplacementsLeaveTheLastOnePersisted() async throws {
        let store = TranscriptCorrectionStore(fileURL: fileURL)
        let first = try store.replace([TranscriptCorrection(heard: "a", written: "1")])
        let last = [TranscriptCorrection(heard: "a", written: "2")]
        let second = try store.replace(last)

        let firstPersisted = await first.value
        let secondPersisted = await second.value

        XCTAssertTrue(firstPersisted)
        XCTAssertTrue(secondPersisted)
        XCTAssertEqual(store.allCorrections(), last)
        XCTAssertEqual(TranscriptCorrectionStore(fileURL: fileURL).allCorrections(), last)
    }

    func testFailedPersistenceLeavesLastKnownGoodCorrectionsActive() async throws {
        let store = TranscriptCorrectionStore(fileURL: fileURL)
        let original = [TranscriptCorrection(heard: "alpha", written: "beta")]
        let didPersistOriginal = try await store.replace(original).value
        XCTAssertTrue(didPersistOriginal)

        try FileManager.default.removeItem(at: directory)
        try Data("not-a-directory".utf8).write(to: directory)

        let didPersistReplacement = try await store.replace([
            TranscriptCorrection(heard: "alpha", written: "gamma")
        ]).value

        XCTAssertFalse(didPersistReplacement)
        XCTAssertEqual(store.allCorrections(), original)
    }

    func testInvalidReplacementDoesNotChangeInMemoryCorrections() async throws {
        let store = TranscriptCorrectionStore(fileURL: fileURL)
        let original = [TranscriptCorrection(heard: "alpha", written: "beta")]
        let didPersist = try await store.replace(original).value
        XCTAssertTrue(didPersist)

        XCTAssertThrowsError(try store.replace([
            TranscriptCorrection(heard: "alpha", written: "one"),
            TranscriptCorrection(heard: "ALPHA", written: "two")
        ]))
        XCTAssertEqual(store.allCorrections(), original)
    }

    func testInvalidFileIsSetAsideInsteadOfBeingOverwrittenLater() async throws {
        let invalid = #"{"schemaVersion":1,"corrections":[{"heard":"a"}]}"#
        try writeFile(invalid)

        let store = TranscriptCorrectionStore(fileURL: fileURL)

        XCTAssertEqual(store.allCorrections(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let setAside = PersistedDocumentFile.invalidFileURL(for: fileURL)
        XCTAssertEqual(try String(contentsOf: setAside, encoding: .utf8), invalid)

        let didPersist = try await store.replace([TranscriptCorrection(heard: "a", written: "b")]).value
        XCTAssertTrue(didPersist)
        XCTAssertEqual(try String(contentsOf: setAside, encoding: .utf8), invalid)
    }

    func testDocumentValidationReportsEachFailureKind() throws {
        func error(_ json: String) -> TranscriptCorrectionDocumentError? {
            do {
                _ = try TranscriptCorrectionDocument.validatedCorrections(from: Data(json.utf8))
                return nil
            } catch {
                return error as? TranscriptCorrectionDocumentError
            }
        }
        let id = UUID().uuidString

        XCTAssertEqual(error("[]"), .malformed)
        XCTAssertEqual(error(#"{"schemaVersion":2,"corrections":[]}"#), .unsupportedSchemaVersion(2))
        XCTAssertEqual(
            error(#"{"schemaVersion":1,"corrections":[{"id":"\#(id)","heard":" ","written":"x","isEnabled":true}]}"#),
            .invalidCorrections(.heardIsEmpty(index: 0))
        )
        XCTAssertEqual(
            try TranscriptCorrectionDocument.validatedCorrections(
                from: Data(#"{"schemaVersion":1,"corrections":[]}"#.utf8)
            ),
            []
        )
    }
}

