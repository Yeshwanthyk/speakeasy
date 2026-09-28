import AppKit
import Combine
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
        model.becameVisible()
        model.updateDevices(model.deviceEnumerator())
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

    func testDisabledActionsAndRejectedModelRequestClearsPendingState() {
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
        model.becameVisible()
        model.handleFeedback(.modelSwitchFailed("Model warming up, please wait"))
        XCTAssertNil(model.requestedModel)
        XCTAssertEqual(model.modelError, "Model warming up, please wait")
        model.becameHidden()
        XCTAssertFalse(model.isVisible)
    }

    func testSystemDefaultAndHiddenRefresh() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        var selected: String?
        var enumerations = 0
        let model = SettingsModel(
            store: store, diagnosticsStore: nil,
            currentMode: { .toggle }, setMode: { _ in },
            currentShortcut: { .defaultShortcut }, changeShortcut: {}, resetShortcut: {},
            shortcutEnabled: { true },
            availableDevices: { enumerations += 1; return [MicrophoneDevice(uid: "usb", name: "USB")] },
            selectedDevice: { selected }, selectDevice: { selected = $0.isEmpty ? nil : $0 },
            deviceEnabled: { true }, currentModel: { .parakeet110M }, selectModel: { _ in },
            openCorrections: {}, pasteTranscript: { _ in }
        )
        XCTAssertNil(model.selectedDeviceUID)
        model.becameVisible()
        model.updateDevices(model.deviceEnumerator())
        model.chooseDevice("usb")
        XCTAssertEqual(model.selectedDeviceUID, "usb")
        model.chooseDevice("")
        XCTAssertNil(model.selectedDeviceUID)
        let count = enumerations
        model.becameHidden()
        model.handleFeedback(.status("Unrelated"))
        XCTAssertEqual(enumerations, count)
    }

    func testHistoryPasteWithoutPreviousAppCopiesWithFeedback() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        let model = SettingsModel(
            store: store, diagnosticsStore: nil,
            currentMode: { .toggle }, setMode: { _ in },
            currentShortcut: { .defaultShortcut }, changeShortcut: {}, resetShortcut: {},
            shortcutEnabled: { true }, availableDevices: { [] }, selectedDevice: { nil },
            selectDevice: { _ in }, deviceEnabled: { false }, currentModel: { .parakeet110M },
            selectModel: { _ in }, openCorrections: {}, pasteTranscript: { _ in XCTFail("No paste target") },
            frontmostApp: { nil }
        )
        model.rememberPasteTarget()
        XCTAssertFalse(model.hasPasteTarget)
        model.pasteHistory("Hello")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Hello")
        XCTAssertNotNil(model.historyFeedback)
    }

    func testHistoryPasteRestoresPreviousAppBeforeDelivery() throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }) else { throw XCTSkip("No other running application") }
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        var activated = false
        var pasted = false
        let model = SettingsModel(
            store: store, diagnosticsStore: nil,
            currentMode: { .toggle }, setMode: { _ in },
            currentShortcut: { .defaultShortcut }, changeShortcut: {}, resetShortcut: {},
            shortcutEnabled: { true }, availableDevices: { [] }, selectedDevice: { nil },
            selectDevice: { _ in }, deviceEnabled: { false }, currentModel: { .parakeet110M },
            selectModel: { _ in }, openCorrections: {},
            pasteTranscript: { _ in pasted = activated }, frontmostApp: { app },
            activateTarget: { _ in activated = true; return true }
        )
        model.rememberPasteTarget()
        XCTAssertTrue(model.hasPasteTarget)
        model.pasteHistory("Hello")
        let expectation = expectation(description: "Delivery follows activation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(pasted)
    }

    func testWindowControllerReusesWindowAndStopsUpdatesOnClose() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json"))
        let model = SettingsModel(
            store: store, diagnosticsStore: nil,
            currentMode: { .toggle }, setMode: { _ in },
            currentShortcut: { .defaultShortcut }, changeShortcut: {}, resetShortcut: {},
            shortcutEnabled: { true }, availableDevices: { [] }, selectedDevice: { nil },
            selectDevice: { _ in }, deviceEnabled: { false }, currentModel: { .parakeet110M },
            selectModel: { _ in }, openCorrections: {}, pasteTranscript: { _ in },
            frontmostApp: { nil }
        )
        let controller = SettingsWindowController(model: model)
        let window = controller.window
        controller.present()
        XCTAssertTrue(model.isVisible)
        controller.window?.close()
        XCTAssertFalse(model.isVisible)
        controller.present()
        XCTAssertTrue(controller.window === window)
        controller.window?.close()
    }

    func testMeterPublishesWithoutPublishingSettingsAndStopsWhenPaneHidden() {
        let model = makeIsolatedModel(level: { MicrophoneLevelSnapshot(normalizedLevel: 0.5, sequence: 1) })
        var modelUpdates = 0
        var meterUpdates = 0
        let modelToken = model.objectWillChange.sink { _ in modelUpdates += 1 }
        let meterToken = model.microphoneMeter.objectWillChange.sink { _ in meterUpdates += 1 }
        model.becameVisible()
        model.setMicrophonePaneVisible(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertGreaterThan(meterUpdates, 0)
        XCTAssertEqual(modelUpdates, 0)
        model.setMicrophonePaneVisible(false)
        let stoppedAt = meterUpdates
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(meterUpdates, stoppedAt)
        model.becameHidden()
        withExtendedLifetime((modelToken, meterToken)) {}
    }

    func testActivationUpdatesPasteTargetAndCloseClearsIt() throws {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
        guard apps.count >= 2 else { throw XCTSkip("Need two running applications") }
        var activatedPID: pid_t?
        let model = SettingsModel(store: TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json")), diagnosticsStore: nil,
            currentMode: { .toggle }, setMode: { _ in }, currentShortcut: { .defaultShortcut },
            changeShortcut: {}, resetShortcut: {}, shortcutEnabled: { true }, availableDevices: { [] },
            selectedDevice: { nil }, selectDevice: { _ in }, deviceEnabled: { true },
            currentModel: { .parakeet110M }, selectModel: { _ in }, openCorrections: {},
            pasteTranscript: { _ in }, frontmostApp: { apps[0] },
            activateTarget: { app in activatedPID = app.processIdentifier; return true })
        model.rememberPasteTarget()
        model.becameVisible()
        XCTAssertTrue(model.hasPasteTarget)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: apps[1]])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        model.pasteHistory("Hello")
        XCTAssertEqual(activatedPID, apps[1].processIdentifier)
        model.becameHidden()
        XCTAssertFalse(model.hasPasteTarget)
    }

    func testTypedModelFailureClearsPendingRequest() {
        let model = makeIsolatedModel(level: { MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0) })
        model.chooseModel(.parakeetUnified)
        model.handleFeedback(.error("Unrelated error"))
        XCTAssertEqual(model.requestedModel, .parakeetUnified)
        model.handleFeedback(.modelSwitchFailed("Stop recording before switching models"))
        XCTAssertNil(model.requestedModel)
        XCTAssertEqual(model.modelError, "Stop recording before switching models")
    }

    private func makeIsolatedModel(level: @escaping () -> MicrophoneLevelSnapshot) -> SettingsModel {
        SettingsModel(store: TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-settings-\(UUID().uuidString)/history.json")), diagnosticsStore: nil,
            currentMode: { .toggle }, setMode: { _ in }, currentShortcut: { .defaultShortcut },
            changeShortcut: {}, resetShortcut: {}, shortcutEnabled: { true }, availableDevices: { [] },
            selectedDevice: { nil }, selectDevice: { _ in }, deviceEnabled: { true },
            currentModel: { .parakeet110M }, selectModel: { _ in }, openCorrections: {},
            pasteTranscript: { _ in }, levelSnapshot: level)
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
