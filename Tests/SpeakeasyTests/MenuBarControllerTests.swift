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
}
