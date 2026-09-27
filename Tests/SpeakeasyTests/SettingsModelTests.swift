import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class SettingsModelTests: XCTestCase {
    func testRefreshAndActionsUseInjectedSettingsCallbacks() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        store.append("Hello")
        var mode = DictationInvocationMode.toggle
        var shortcut = DictationShortcut.defaultShortcut
        var device = "built-in"
        var kind = ASRModelKind.parakeet110M
        var pasted: String?
        let model = SettingsModel(
            store: store,
            diagnosticsStore: nil,
            currentMode: { mode },
            setMode: { mode = $0 },
            currentShortcut: { shortcut },
            changeShortcut: { shortcut = .keyCombination(keyCode: 1, modifiers: [.control], keyLabel: "s") },
            resetShortcut: { shortcut = .defaultShortcut },
            shortcutEnabled: { true },
            availableDevices: { [MicrophoneDevice(uid: "built-in", name: "Built-in"), MicrophoneDevice(uid: "usb", name: "USB")] },
            selectedDevice: { device },
            selectDevice: { device = $0 },
            deviceEnabled: { true },
            currentModel: { kind },
            selectModel: { kind = $0 },
            openCorrections: {},
            pasteTranscript: { pasted = $0 }
        )

        XCTAssertEqual(model.records.map(\.finalText), ["Hello"])
        XCTAssertEqual(model.selectedDeviceUID, "built-in")
        model.chooseMode(.pushToTalk)
        model.chooseDevice("missing")
        XCTAssertEqual(device, "built-in")
        model.chooseDevice("usb")
        model.changeShortcutNow()
        XCTAssertNotEqual(model.shortcut, .defaultShortcut)
        model.resetShortcutNow()
        model.chooseModel(.parakeetUnified)
        model.pasteTranscript(model.records[0].finalText)

        XCTAssertEqual(model.mode, .pushToTalk)
        XCTAssertEqual(model.selectedDeviceUID, "usb")
        XCTAssertEqual(model.shortcut, .defaultShortcut)
        XCTAssertEqual(model.modelKind, .parakeetUnified)
        XCTAssertNil(model.requestedModel)
        XCTAssertEqual(pasted, "Hello")
    }

    func testDisabledActionsDoNotInvokeCallbacksAndModelRequestKeepsCurrentSelection() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        var changes = 0
        let model = SettingsModel(
            store: store,
            diagnosticsStore: nil,
            currentMode: { .toggle },
            setMode: { _ in },
            currentShortcut: { .defaultShortcut },
            changeShortcut: { changes += 1 },
            resetShortcut: { changes += 1 },
            shortcutEnabled: { false },
            availableDevices: { [MicrophoneDevice(uid: "usb", name: "USB")] },
            selectedDevice: { "usb" },
            selectDevice: { _ in changes += 1 },
            deviceEnabled: { false },
            currentModel: { .parakeet110M },
            selectModel: { _ in changes += 1 },
            openCorrections: {},
            pasteTranscript: { _ in }
        )
        model.changeShortcutNow()
        model.resetShortcutNow()
        model.chooseDevice("usb")
        XCTAssertEqual(changes, 0)
        model.chooseModel(.parakeetUnified)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.modelKind, .parakeet110M)
        XCTAssertEqual(model.requestedModel, .parakeetUnified)
    }

    func testClearHistoryRefreshesVisibleRecords() async {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        store.append("Hello")
        let model = SettingsModel(
            store: store,
            diagnosticsStore: nil,
            currentMode: { .toggle },
            setMode: { _ in },
            currentShortcut: { .defaultShortcut },
            changeShortcut: {},
            resetShortcut: {},
            shortcutEnabled: { true },
            availableDevices: { [] },
            selectedDevice: { nil },
            selectDevice: { _ in },
            deviceEnabled: { false },
            currentModel: { .parakeet110M },
            selectModel: { _ in },
            openCorrections: {},
            pasteTranscript: { _ in }
        )
        let cleared = await model.clearHistory()
        XCTAssertTrue(cleared)
        XCTAssertTrue(model.records.isEmpty)
    }
}
