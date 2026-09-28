import XCTest
@testable import Speakeasy

@MainActor
final class OverlayModelTests: XCTestCase {
    func testTailKeepsRecentWordsAndBoundsLength() {
        let text = Array(repeating: "hello", count: 80).joined(separator: " ")
        let tail = OverlayModel.tail(text)
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("hello"))
        XCTAssertLessThanOrEqual(tail.count, 190)
        XCTAssertEqual(OverlayModel.tail("short"), "short")
    }

    func testTransitionsAndRevision() {
        let model = OverlayModel()
        model.start(mode: .pushToTalk)
        XCTAssertEqual(model.modeLabel, "Push to Talk")
        XCTAssertEqual(model.displayedText, "Listening…")
        model.adopt("First words")
        model.adopt("First words")
        XCTAssertEqual(model.revision, 1)
        model.transcribe()
        XCTAssertEqual(model.displayedText, "First words")
        model.adopt("ignored")
        XCTAssertEqual(model.revision, 1)
        model.finish()
        model.start(mode: .toggle)
        XCTAssertEqual(model.modeLabel, "Hands-Free")
        XCTAssertEqual(model.revision, 0)
        model.fail("Microphone unavailable")
        XCTAssertEqual(model.displayedText, "Microphone unavailable")
    }

    func testActionsUseFinalAndRawAndMarkUndoOnSuccessfulPaste() {
        let model = OverlayModel()
        let record = TranscriptRecord(rawText: "raw speech", finalText: "polished speech", backend: "test", outcome: .eventsPosted)
        var copied: [String] = []
        var pasted: [String] = []
        model.copyLast(record: record) { copied.append($0) }
        model.pasteLast(record: record) { pasted.append($0) }
        model.undoCorrections(record: record, copy: { copied.append($0) }, paste: {
            pasted.append($0)
            return true
        })
        XCTAssertEqual(copied, ["polished speech", "raw speech"])
        XCTAssertEqual(pasted, ["polished speech", "raw speech"])
        XCTAssertEqual(model.lastUndoRecordID, record.id)
    }

    func testUndoMarkerPersistsOnRecord() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranscriptStore(fileURL: url)
        let record = TranscriptRecord(rawText: "spoken", finalText: "corrected", backend: "test", outcome: .eventsPosted)
        let appended = await store.append(record).value
        let marked = await store.markCorrectionsUndone(id: record.id).value
        XCTAssertTrue(appended)
        XCTAssertTrue(marked)
        XCTAssertEqual(TranscriptStore(fileURL: url).allRecords().last?.correctionsUndone, true)
    }

    func testPreferencesPersistAndDefault() {
        let name = "overlay-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return XCTFail("defaults suite") }
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(OverlayPreferences.style(in: defaults), .bottomPill)
        XCTAssertTrue(OverlayPreferences.showsLiveText(in: defaults))
        OverlayPreferences.setStyle(.topIndicator, in: defaults)
        OverlayPreferences.setShowsLiveText(false, in: defaults)
        XCTAssertEqual(OverlayPreferences.style(in: defaults), .topIndicator)
        XCTAssertFalse(OverlayPreferences.showsLiveText(in: defaults))
    }
}
