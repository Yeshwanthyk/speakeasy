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

    func testMenuExposesOnlyDefaultAndFallbackModels() {
        let store = TranscriptStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-menu-models-\(UUID().uuidString)")
                .appendingPathComponent("history.json")
        )
        let controller = MenuBarController(store: store)
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let modelItems = menu.items.first(where: { $0.title.hasPrefix("Speech Model —") })?.submenu?.items
        XCTAssertEqual(
            modelItems?.map(\.title),
            ["Parakeet TDT+CTC 110M Q8_0", "Parakeet Unified EN 0.6B Q8_0"]
        )
        XCTAssertEqual(modelItems?.first?.state, .on)
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

        let modeItem = menu.items.first(where: { $0.title.hasPrefix("Dictation Mode —") })
        XCTAssertEqual(modeItem?.title, "Dictation Mode — Push to Talk")
        XCTAssertEqual(modeItem?.submenu?.items.count, DictationInvocationMode.allCases.count)
        XCTAssertEqual(
            modeItem?.submenu?.items.first(where: { $0.representedObject as? String == DictationInvocationMode.pushToTalk.rawValue })?.state,
            .on
        )

        let cancelItem = menu.items.first(where: { $0.title == "Cancel Transcription" })
        XCTAssertTrue(cancelItem?.isEnabled == true)
    }

    func testMenuExposesFailedCaptureActionsWithTruthfulEnabledState() {
        let store = TranscriptStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-menu-replay-\(UUID().uuidString)")
                .appendingPathComponent("history.json")
        )
        let controller = MenuBarController(
            store: store,
            canRetryFailedCapture: { true },
            canDiscardFailedCapture: { false }
        )
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        XCTAssertTrue(menu.items.first(where: { $0.title == "Retry Failed Capture" })?.isEnabled == true)
        XCTAssertNil(menu.items.first(where: { $0.title == "Discard Failed Capture" }))
    }

    func testMenuBuildsLazyMicrophoneControlsAndLevelPreview() {
        let store = TranscriptStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-menu-microphone-\(UUID().uuidString)")
                .appendingPathComponent("history.json")
        )
        let controller = MenuBarController(
            store: store,
            availableInputDevices: {
                [
                    MicrophoneDevice(uid: "built-in", name: "Built-in"),
                    MicrophoneDevice(uid: "usb", name: "USB")
                ]
            },
            selectedInputDeviceUID: { "usb" },
            microphoneLevelSnapshot: {
                MicrophoneLevelSnapshot(normalizedLevel: 0.42, sequence: 1)
            }
        )
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let microphone = menu.items.first(where: { $0.title.hasPrefix("Microphone —") })
        XCTAssertEqual(microphone?.title, "Microphone — USB")
        XCTAssertEqual(microphone?.submenu?.items.count, 2)
        XCTAssertEqual(
            microphone?.submenu?.items.first(where: { $0.representedObject as? String == "usb" })?.state,
            .on
        )
        XCTAssertTrue(menu.items.contains(where: { $0.title == "Microphone Level: 42%" }))
        XCTAssertNotNil(menu.items.first(where: { $0.title == "Microphone Level: 42%" })?.view)
    }

    func testMenuCapsVisibleRecentsAndMovesFullHistoryIntoSubmenu() {
        let store = TranscriptStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-menu-history-layout-\(UUID().uuidString)")
                .appendingPathComponent("history.json")
        )
        for index in 1...8 {
            store.append("Transcript \(index)")
        }
        let controller = MenuBarController(store: store)
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let visibleTranscripts = menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(visibleTranscripts.map(\.title), [
            "Transcript 8", "Transcript 7", "Transcript 6",
            "Transcript 5", "Transcript 4", "Transcript 3"
        ])

        let allHistory = menu.items.first(where: { $0.title == "All Transcripts (8)" })?.submenu
        XCTAssertEqual(allHistory?.items.filter { $0.representedObject is String }.count, 8)
        XCTAssertEqual(allHistory?.items.first?.title, "Clear Transcript History…")
    }

    func testMenuUsesBrandedHeaderAndConciseEmptyState() {
        let store = TranscriptStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-menu-empty-\(UUID().uuidString)")
                .appendingPathComponent("history.json")
        )
        let controller = MenuBarController(store: store)
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.first?.title, "Speakeasy")
        XCTAssertNotNil(menu.items.first?.view)
        XCTAssertNotNil(menu.items.first(where: {
            $0.title == "Dictate with Hyper+S — transcripts appear here"
        }))
    }
}
