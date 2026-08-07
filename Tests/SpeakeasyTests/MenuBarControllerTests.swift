import AppKit
import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testMenuExposesLazyStatsAndDiagnosticsReport() {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-menu-history-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-menu-stats-\(UUID().uuidString)")
            .appendingPathComponent("stats.json")
        let history = TranscriptStore(fileURL: historyURL)
        let diagnostics = DiagnosticsStore(fileURL: statsURL)
        let controller = MenuBarController(
            store: history,
            diagnosticsStore: diagnostics
        )
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let item = menu.items.first(where: { $0.title == "Stats & Diagnostics" })
        XCTAssertNotNil(item?.submenu)
        XCTAssertEqual(item?.submenu?.items.count, 1)
        XCTAssertTrue(item?.submenu?.items.first?.title.contains("Today: 0 attempts") == true)
        XCTAssertFalse(item?.submenu?.items.first?.isEnabled ?? true)
    }

    func testMenuExposesInvocationModesAndCancelControl() {
        let store = TranscriptStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-menu-mode-\(UUID().uuidString)")
                .appendingPathComponent("history.json")
        )
        let controller = MenuBarController(
            store: store,
            currentInvocationMode: { .pushToTalk },
            canCancelDictation: { true }
        )
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let modeItem = menu.items.first(where: { $0.title == "Invocation Mode" })
        XCTAssertEqual(modeItem?.submenu?.items.count, DictationInvocationMode.allCases.count)
        XCTAssertEqual(
            modeItem?.submenu?.items.first(where: { $0.representedObject as? String == DictationInvocationMode.pushToTalk.rawValue })?.state,
            .on
        )

        let cancelItem = menu.items.first(where: { $0.title == "Cancel Dictation" })
        XCTAssertTrue(cancelItem?.isEnabled == true)
    }
}
