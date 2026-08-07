import AppKit
import Foundation

/// Owns the status-bar item and its menu. Rebuilds the menu lazily via
/// `NSMenuDelegate.menuNeedsUpdate`, so no work runs on the transcription path.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let titleMaxLength = 60

    private let store: TranscriptStore
    private let diagnosticsStore: DiagnosticsStore?
    private let pasteTranscript: (String) -> Void
    private let copyLastTranscript: () -> Void
    private let pasteLastTranscript: () -> Void
    private let currentASRModelKind: () -> ASRModelKind
    private let selectASRModel: (ASRModelKind) -> Void
    private let currentInvocationMode: () -> DictationInvocationMode
    private let selectInvocationMode: (DictationInvocationMode) -> Void
    private let cancelDictation: () -> Void
    private let canCancelDictation: () -> Bool
    private let retryLastFailedCapture: () -> Void
    private let discardFailedCapture: () -> Void
    private let canRetryFailedCapture: () -> Bool
    private let canDiscardFailedCapture: () -> Bool
    private let availableInputDevices: () -> [MicrophoneDevice]
    private let selectedInputDeviceUID: () -> String?
    private let selectInputDevice: (String) -> Void
    private let canSelectInputDevice: () -> Bool
    private let microphoneLevelSnapshot: () -> MicrophoneLevelSnapshot
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var transientFeedback: UserFeedbackEvent?
    private var feedbackGeneration = 0
    private var levelTimer: Timer?
    private weak var levelItem: NSMenuItem?

    init(
        store: TranscriptStore,
        diagnosticsStore: DiagnosticsStore? = nil,
        paster: Pasting? = nil,
        pasteTranscript: ((String) -> Void)? = nil,
        currentASRModelKind: @escaping () -> ASRModelKind = { .parakeet110M },
        selectASRModel: @escaping (ASRModelKind) -> Void = { _ in },
        copyLastTranscript: @escaping () -> Void = {},
        pasteLastTranscript: @escaping () -> Void = {},
        currentInvocationMode: @escaping () -> DictationInvocationMode = { .toggle },
        selectInvocationMode: @escaping (DictationInvocationMode) -> Void = { _ in },
        cancelDictation: @escaping () -> Void = {},
        canCancelDictation: @escaping () -> Bool = { false },
        retryLastFailedCapture: @escaping () -> Void = {},
        discardFailedCapture: @escaping () -> Void = {},
        canRetryFailedCapture: @escaping () -> Bool = { false },
        canDiscardFailedCapture: @escaping () -> Bool = { false },
        availableInputDevices: @escaping () -> [MicrophoneDevice] = { [] },
        selectedInputDeviceUID: @escaping () -> String? = { nil },
        selectInputDevice: @escaping (String) -> Void = { _ in },
        canSelectInputDevice: @escaping () -> Bool = { true },
        microphoneLevelSnapshot: @escaping () -> MicrophoneLevelSnapshot = {
            MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0)
        }
    ) {
        self.store = store
        self.diagnosticsStore = diagnosticsStore
        self.pasteTranscript = pasteTranscript ?? { text in
            _ = paster?.paste(text)
        }
        self.copyLastTranscript = copyLastTranscript
        self.pasteLastTranscript = pasteLastTranscript
        self.currentASRModelKind = currentASRModelKind
        self.selectASRModel = selectASRModel
        self.currentInvocationMode = currentInvocationMode
        self.selectInvocationMode = selectInvocationMode
        self.cancelDictation = cancelDictation
        self.canCancelDictation = canCancelDictation
        self.retryLastFailedCapture = retryLastFailedCapture
        self.discardFailedCapture = discardFailedCapture
        self.canRetryFailedCapture = canRetryFailedCapture
        self.canDiscardFailedCapture = canDiscardFailedCapture
        self.availableInputDevices = availableInputDevices
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.selectInputDevice = selectInputDevice
        self.canSelectInputDevice = canSelectInputDevice
        self.microphoneLevelSnapshot = microphoneLevelSnapshot
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speakeasy")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Speakeasy"
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func showFeedback(_ event: UserFeedbackEvent) {
        transientFeedback = event
        feedbackGeneration &+= 1
        let generation = feedbackGeneration

        if let button = statusItem.button {
            button.title = " \(event.message)"
            button.toolTip = event.message
        }

        let duration: TimeInterval
        switch event {
        case .status:
            duration = 3
        case .error:
            duration = 6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.feedbackGeneration == generation else {
                return
            }
            self.transientFeedback = nil
            if let button = self.statusItem.button {
                button.title = ""
                button.toolTip = "Speakeasy"
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLevelItem()
            }
        }
        updateLevelItem()
    }

    func menuDidClose(_ menu: NSMenu) {
        levelTimer?.invalidate()
        levelTimer = nil
        levelItem = nil
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let transientFeedback {
            let feedbackItem = NSMenuItem(
                title: transientFeedback.message,
                action: nil,
                keyEquivalent: ""
            )
            feedbackItem.isEnabled = false
            menu.addItem(feedbackItem)
            menu.addItem(.separator())
        }

        let history = store.allEntries()
        if history.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // Newest first.
            for text in history.reversed() {
                let item = NSMenuItem(
                    title: Self.displayTitle(for: text),
                    action: #selector(pasteHistoryItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = text
                item.toolTip = text
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "Invocation Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "Invocation Mode")
        let selectedMode = currentInvocationMode()
        for mode in DictationInvocationMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectInvocationModeItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == selectedMode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let cancel = NSMenuItem(
            title: "Cancel Dictation",
            action: #selector(cancelDictationAction),
            keyEquivalent: ""
        )
        cancel.target = self
        cancel.isEnabled = canCancelDictation()
        menu.addItem(cancel)

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu(title: "Microphone")
        let selectedUID = selectedInputDeviceUID()
        let devices = availableInputDevices()
        let selectionEnabled = canSelectInputDevice()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            microphoneMenu.addItem(empty)
        } else {
            for device in devices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(selectInputDeviceItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.uid
                item.state = device.uid == selectedUID ? .on : .off
                item.isEnabled = selectionEnabled && device.uid != selectedUID
                microphoneMenu.addItem(item)
            }
        }
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)

        let currentLevel = NSMenuItem(title: Self.levelTitle(for: microphoneLevelSnapshot()), action: nil, keyEquivalent: "")
        currentLevel.isEnabled = false
        levelItem = currentLevel
        menu.addItem(currentLevel)

        let retry = NSMenuItem(
            title: "Retry Last Failed Capture",
            action: #selector(retryLastFailedCaptureAction),
            keyEquivalent: ""
        )
        retry.target = self
        retry.isEnabled = canRetryFailedCapture()
        menu.addItem(retry)

        let discardFailed = NSMenuItem(
            title: "Discard Failed Capture",
            action: #selector(discardFailedCaptureAction),
            keyEquivalent: ""
        )
        discardFailed.target = self
        discardFailed.isEnabled = canDiscardFailedCapture()
        menu.addItem(discardFailed)

        menu.addItem(.separator())

        let copyLast = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscriptAction),
            keyEquivalent: ""
        )
        copyLast.target = self
        copyLast.isEnabled = !history.isEmpty
        menu.addItem(copyLast)

        let pasteLast = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscriptAction),
            keyEquivalent: ""
        )
        pasteLast.target = self
        pasteLast.isEnabled = !history.isEmpty
        menu.addItem(pasteLast)

        let clear = NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !history.isEmpty
        menu.addItem(clear)

        let modelItem = NSMenuItem(title: "Audio Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu(title: "Audio Model")
        let selectedKind = currentASRModelKind()

        for kind in ASRModelKind.allCases {
            let item = NSMenuItem(
                title: kind.displayName,
                action: #selector(selectModelItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = kind.preferenceValue
            item.state = kind == selectedKind ? .on : .off
            modelMenu.addItem(item)
        }

        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let diagnosticsItem = NSMenuItem(title: "Stats & Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu(title: "Stats & Diagnostics")
        let report = diagnosticsStore?.report() ?? "Diagnostics unavailable"
        let reportItem = NSMenuItem(title: report, action: nil, keyEquivalent: "")
        reportItem.isEnabled = false
        diagnosticsMenu.addItem(reportItem)
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func pasteHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        pasteTranscript(text)
    }

    @objc private func copyLastTranscriptAction() {
        copyLastTranscript()
    }

    @objc private func pasteLastTranscriptAction() {
        pasteLastTranscript()
    }

    @objc private func clearHistory() {
        store.clear()
    }

    @objc private func cancelDictationAction() {
        cancelDictation()
    }

    @objc private func retryLastFailedCaptureAction() {
        retryLastFailedCapture()
    }

    @objc private func discardFailedCaptureAction() {
        discardFailedCapture()
    }

    @objc private func selectInputDeviceItem(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        selectInputDevice(uid)
    }

    @objc private func selectInvocationModeItem(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let mode = DictationInvocationMode(rawValue: value) else {
            return
        }

        selectInvocationMode(mode)
    }

    @objc private func selectModelItem(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let kind = ASRModelKind(preferenceValue: value) else {
            return
        }

        selectASRModel(kind)
    }

    // MARK: - Helpers

    private static func displayTitle(for text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > titleMaxLength else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: titleMaxLength)
        return String(collapsed[..<idx]) + "…"
    }

    private static func levelTitle(for snapshot: MicrophoneLevelSnapshot) -> String {
        "Microphone Level: \(Int((snapshot.normalizedLevel * 100).rounded()))%"
    }

    private func updateLevelItem() {
        guard let levelItem else { return }
        levelItem.title = Self.levelTitle(for: microphoneLevelSnapshot())
    }
}
