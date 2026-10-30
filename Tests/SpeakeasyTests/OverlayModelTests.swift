import XCTest
@testable import Speakeasy

final class OverlayModelTests: XCTestCase {
    func testTailKeepsRecentWordsAndBoundsLength() {
        let text = Array(repeating: "hello", count: 80).joined(separator: " ")
        let tail = OverlayModel.tail(text)
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("hello"))
        XCTAssertLessThanOrEqual(tail.count, 190)
        XCTAssertEqual(OverlayModel.tail("short"), "short")
    }

    func testRecordingIsCompactAndIgnoresPreviewsWhenLiveTextIsOff() {
        var model = OverlayModel()
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.record(showsLiveText: false), .present)
        XCTAssertEqual(model.phase, .recording)
        XCTAssertFalse(model.adopt("hello there"))
        XCTAssertNil(model.displayedText)
        XCTAssertEqual(model.accessibilityLabel, "Speakeasy is recording")
    }

    func testLiveTextAdoptsDuringRecordingOnlyAndStaysThroughProcessing() {
        var model = OverlayModel()
        _ = model.record(showsLiveText: true)
        XCTAssertNil(model.displayedText, "No empty text row before words arrive")
        XCTAssertTrue(model.adopt(" First words "))
        XCTAssertFalse(model.adopt("First words"))
        XCTAssertEqual(model.revision, 1)
        XCTAssertEqual(model.displayedText, "First words")

        XCTAssertEqual(model.process(), .present)
        XCTAssertFalse(model.adopt("ignored"))
        XCTAssertEqual(model.displayedText, "First words")

        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        _ = model.record(showsLiveText: true)
        XCTAssertEqual(model.revision, 0)
        model.adopt(long)
        XCTAssertLessThanOrEqual(model.displayedText?.count ?? .max, OverlayModel.liveTextLimit)
    }

    func testHideDismissesOnceAndRecordingRestarts() {
        var model = OverlayModel()
        XCTAssertEqual(model.hide(), .noChange)
        _ = model.record(showsLiveText: false)
        _ = model.process()
        XCTAssertEqual(model.hide(), .dismiss)
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertEqual(model.hide(), .noChange)
        XCTAssertNil(model.displayedText)
    }

    func testErrorHoldsThroughHideThenExpiresWithItsOwnToken() {
        var model = OverlayModel()
        _ = model.record(showsLiveText: false)
        XCTAssertEqual(
            model.fail("Transcription failed"),
            .presentError(token: 1, duration: OverlayModel.errorDisplayDuration)
        )
        XCTAssertEqual(model.displayedText, "Transcription failed")
        XCTAssertEqual(model.hide(), .noChange, "A late hide must not cut the error short")
        XCTAssertEqual(model.expireError(token: 0), .noChange)
        XCTAssertEqual(model.expireError(token: 1), .dismiss)
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.expireError(token: 1), .noChange)
    }

    func testNewRecordingSupersedesPendingErrorExpiry() {
        var model = OverlayModel()
        _ = model.fail("Transcript could not be saved")
        _ = model.record(showsLiveText: false)
        XCTAssertEqual(model.expireError(token: model.errorToken), .noChange)
        XCTAssertEqual(model.phase, .recording)

        XCTAssertEqual(
            model.fail("  "),
            .presentError(token: 2, duration: OverlayModel.errorDisplayDuration)
        )
        XCTAssertEqual(model.phase, .error(OverlayModel.fallbackErrorMessage))
    }

    @MainActor
    func testUndoMarkerPersistsOnRecord() async {
        let url = testScratchDirectory.appendingPathComponent("overlay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranscriptStore(fileURL: url)
        let record = TranscriptRecord(rawText: "spoken", finalText: "corrected", backend: "test", outcome: .eventsPosted)
        let appended = await store.append(record).value
        let marked = await store.markCorrectionsUndone(id: record.id).value
        XCTAssertTrue(appended)
        XCTAssertTrue(marked)
        XCTAssertEqual(TranscriptStore(fileURL: url).allRecords().last?.correctionsUndone, true)
    }
}

final class OverlayPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = testDefaultsSuiteName("overlay-prefs")
        guard let defaults = UserDefaults(suiteName: name) else { return XCTFail("defaults suite") }
        defer { removeTestDefaults(name) }
        body(defaults)
    }

    func testFreshInstallDefaultsToTopCapsuleWithoutLiveText() {
        withDefaults { defaults in
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .top)
            XCTAssertFalse(OverlayPreferences.showsLiveText(in: defaults))
            XCTAssertEqual(defaults.integer(forKey: OverlayPreferences.schemaKey), OverlayPreferences.currentSchema)
        }
    }

    func testV1DefaultsAndStoredBottomPillMigrateToMinimal() {
        withDefaults { defaults in
            defaults.set("bottomPill", forKey: OverlayPreferences.styleKey)
            XCTAssertFalse(OverlayPreferences.showsLiveText(in: defaults))
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .top)
        }
        withDefaults { defaults in
            defaults.set("bottomPill", forKey: OverlayPreferences.styleKey)
            defaults.set(false, forKey: OverlayPreferences.liveTextKey)
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .top)
            XCTAssertFalse(OverlayPreferences.showsLiveText(in: defaults))
        }
    }

    func testV1ExplicitLiveTextOptInSurvivesWithItsStyle() {
        withDefaults { defaults in
            defaults.set("bottomPill", forKey: OverlayPreferences.styleKey)
            defaults.set(true, forKey: OverlayPreferences.liveTextKey)
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .bottom)
            XCTAssertTrue(OverlayPreferences.showsLiveText(in: defaults))
        }
        withDefaults { defaults in
            defaults.set("topIndicator", forKey: OverlayPreferences.styleKey)
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .top)
            XCTAssertFalse(OverlayPreferences.showsLiveText(in: defaults))
        }
    }

    func testChoicesAfterMigrationPersistAndAreNotMigratedAgain() {
        withDefaults { defaults in
            OverlayPreferences.setStyle(.bottom, in: defaults)
            OverlayPreferences.setShowsLiveText(false, in: defaults)
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .bottom)
            XCTAssertFalse(OverlayPreferences.showsLiveText(in: defaults))
            OverlayPreferences.setShowsLiveText(true, in: defaults)
            XCTAssertTrue(OverlayPreferences.showsLiveText(in: defaults))
            XCTAssertEqual(OverlayPreferences.style(in: defaults), .bottom)
        }
    }
}
