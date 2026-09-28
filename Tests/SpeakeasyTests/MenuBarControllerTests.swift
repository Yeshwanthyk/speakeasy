import AppKit
import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class MenuBarControllerTests: XCTestCase {
    private func makeStore() -> TranscriptStore {
        TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-menu-\(UUID().uuidString)/history.json"))
    }

    func testMenuIsCompactAndOpensSettings() {
        let controller = MenuBarController(store: makeStore())
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.first?.title, "Speakeasy")
        XCTAssertNotNil(menu.items.first?.view)
        XCTAssertTrue(menu.items.contains { $0.title == "Dictate with fn — transcripts appear here" })
        let settings = menu.items.first { $0.title == "Settings…" }
        XCTAssertEqual(settings?.keyEquivalent, ",")
        XCTAssertEqual(settings?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(menu.items.last?.title, "Quit Speakeasy")
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })
    }

    func testMenuCapsRecentsAndPreservesHistoryActions() {
        let store = makeStore()
        for index in 1...8 { store.append("Transcript \(index)") }
        let controller = MenuBarController(store: store)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.compactMap { $0.representedObject as? String }, [
            "Transcript 8", "Transcript 7", "Transcript 6", "Transcript 5", "Transcript 4"
        ])
        XCTAssertTrue(menu.items.contains { $0.title == "Copy Last Transcript" })
        XCTAssertTrue(menu.items.contains { $0.title == "Paste Last Transcript" })
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("All Transcripts") })
    }

    func testSessionActionsRemainConditional() {
        let controller = MenuBarController(
            store: makeStore(),
            canCancelDictation: { true },
            canRetryFailedCapture: { true },
            canDiscardFailedCapture: { false }
        )
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "Cancel Transcription" })
        XCTAssertTrue(menu.items.contains { $0.title == "Retry Failed Capture" })
        XCTAssertFalse(menu.items.contains { $0.title == "Discard Failed Capture" })
    }

    func testMenuDoesNotLoadSettingsOrCorrections() {
        var count = 0
        let controller = MenuBarController(store: makeStore(), loadCorrections: {
            count += 1
            return []
        })
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(count, 0)
        XCTAssertFalse(menu.items.contains { $0.title == "Corrections…" })
    }
}
