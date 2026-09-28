import AppKit
import Foundation

private enum MenuBarActivity {
    case ready
    case listening
    case transcribing

    var title: String {
        switch self {
        case .ready:
            return "Ready to dictate"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing locally"
        }
    }

    var color: NSColor {
        switch self {
        case .ready:
            return .systemGreen
        case .listening:
            return .systemRed
        case .transcribing:
            return .controlAccentColor
        }
    }
}

private final class MenuHeaderView: NSView {
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(activity: MenuBarActivity, shortcut: DictationShortcut) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 68))

        let iconBackground = NSView(frame: NSRect(x: 14, y: 14, width: 40, height: 40))
        iconBackground.wantsLayer = true
        iconBackground.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        iconBackground.layer?.cornerRadius = 10
        addSubview(iconBackground)

        let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speakeasy")
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyDown
        iconBackground.addSubview(icon)

        let title = NSTextField(labelWithString: "Speakeasy")
        title.frame = NSRect(x: 66, y: 36, width: 196, height: 20)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        addSubview(title)

        statusDot.frame = NSRect(x: 67, y: 20, width: 7, height: 7)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        addSubview(statusDot)

        statusLabel.frame = NSRect(x: 81, y: 14, width: 188, height: 19)
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        addSubview(statusLabel)

        let shortcutLabel = NSTextField(labelWithString: shortcut.displayName)
        shortcutLabel.frame = NSRect(x: 274, y: 24, width: 90, height: 20)
        shortcutLabel.alignment = .center
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.lineBreakMode = .byTruncatingMiddle
        shortcutLabel.wantsLayer = true
        shortcutLabel.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        shortcutLabel.layer?.cornerRadius = 6
        shortcutLabel.toolTip = "\(shortcut.accessibilityName) starts and stops dictation"
        addSubview(shortcutLabel)

        update(activity: activity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(activity: MenuBarActivity) {
        statusDot.layer?.backgroundColor = activity.color.cgColor
        statusLabel.stringValue = activity.title
        setAccessibilityLabel("Speakeasy, \(activity.title)")
    }
}

/// Owns the status-bar item and its menu. Rebuilds the menu lazily via
/// `NSMenuDelegate.menuNeedsUpdate`, so no work runs on the transcription path.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let titleMaxLength = 54
    private static let recentTranscriptLimit = 5
    private static let menuWidth: CGFloat = 380

    private let store: TranscriptStore
    private let diagnosticsStore: DiagnosticsStore?
    private let pasteTranscript: (String) -> Void
    private let copyLastTranscript: () -> Void
    private let pasteLastTranscript: () -> Void
    private let loadCorrections: CorrectionEditorModel.Loader
    private let saveCorrections: CorrectionEditorModel.Saver
    private let currentASRModelKind: () -> ASRModelKind
    private let selectASRModel: (ASRModelKind) -> Void
    private let currentInvocationMode: () -> DictationInvocationMode
    private let selectInvocationMode: (DictationInvocationMode) -> Void
    private let currentDictationShortcut: () -> DictationShortcut
    private let setDictationShortcut: (DictationShortcut) -> DictationShortcutUpdateResult
    private let setShortcutCaptureActive: (Bool) -> Void
    private let canChangeDictationShortcut: () -> Bool
    private let cancelDictation: () -> Void
    private let canCancelDictation: () -> Bool
    private let isRecording: () -> Bool
    private let retryLastFailedCapture: () -> Void
    private let discardFailedCapture: () -> Void
    private let canRetryFailedCapture: () -> Bool
    private let canDiscardFailedCapture: () -> Bool
    private let availableInputDevices: () -> [MicrophoneDevice]
    private let selectedInputDeviceUID: () -> String?
    private let selectInputDevice: (String) -> Void
    private let canSelectInputDevice: () -> Bool
    private let microphoneLevelSnapshot: () -> MicrophoneLevelSnapshot
    private var levelTimer: Timer?
    private weak var levelItem: NSMenuItem?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var transientFeedback: UserFeedbackEvent?
    private var feedbackGeneration = 0
    private var correctionEditorController: CorrectionEditorWindowController?
    private var settingsController: SettingsWindowController?

    init(
        store: TranscriptStore,
        diagnosticsStore: DiagnosticsStore? = nil,
        paster: Pasting? = nil,
        pasteTranscript: ((String) -> Void)? = nil,
        currentASRModelKind: @escaping () -> ASRModelKind = { .parakeet110M },
        selectASRModel: @escaping (ASRModelKind) -> Void = { _ in },
        copyLastTranscript: @escaping () -> Void = {},
        pasteLastTranscript: @escaping () -> Void = {},
        loadCorrections: @escaping CorrectionEditorModel.Loader = { [] },
        saveCorrections: @escaping CorrectionEditorModel.Saver = { _ in false },
        currentInvocationMode: @escaping () -> DictationInvocationMode = { .toggle },
        selectInvocationMode: @escaping (DictationInvocationMode) -> Void = { _ in },
        currentDictationShortcut: @escaping () -> DictationShortcut = { .defaultShortcut },
        setDictationShortcut: @escaping (DictationShortcut) -> DictationShortcutUpdateResult = { _ in .success },
        setShortcutCaptureActive: @escaping (Bool) -> Void = { _ in },
        canChangeDictationShortcut: @escaping () -> Bool = { true },
        cancelDictation: @escaping () -> Void = {},
        canCancelDictation: @escaping () -> Bool = { false },
        isRecording: @escaping () -> Bool = { false },
        retryLastFailedCapture: @escaping () -> Void = {},
        discardFailedCapture: @escaping () -> Void = {},
        canRetryFailedCapture: @escaping () -> Bool = { false },
        canDiscardFailedCapture: @escaping () -> Bool = { false },
        availableInputDevices: @escaping () -> [MicrophoneDevice] = { [] },
        selectedInputDeviceUID: @escaping () -> String? = { nil },
        selectInputDevice: @escaping (String) -> Void = { _ in },
        canSelectInputDevice: @escaping () -> Bool = { true },
        microphoneLevelSnapshot: @escaping () -> MicrophoneLevelSnapshot = { MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0) }
    ) {
        self.store = store
        self.diagnosticsStore = diagnosticsStore
        self.pasteTranscript = pasteTranscript ?? { text in
            _ = paster?.paste(text)
        }
        self.copyLastTranscript = copyLastTranscript
        self.pasteLastTranscript = pasteLastTranscript
        self.loadCorrections = loadCorrections
        self.saveCorrections = saveCorrections
        self.currentASRModelKind = currentASRModelKind
        self.selectASRModel = selectASRModel
        self.currentInvocationMode = currentInvocationMode
        self.selectInvocationMode = selectInvocationMode
        self.currentDictationShortcut = currentDictationShortcut
        self.setDictationShortcut = setDictationShortcut
        self.setShortcutCaptureActive = setShortcutCaptureActive
        self.canChangeDictationShortcut = canChangeDictationShortcut
        self.cancelDictation = cancelDictation
        self.canCancelDictation = canCancelDictation
        self.isRecording = isRecording
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
            let image = Self.symbol("waveform", accessibilityDescription: "Speakeasy")
            button.image = image
            button.toolTip = statusToolTip
        }

        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
        statusItem.menu = menu
    }

    func showFeedback(_ event: UserFeedbackEvent) {
        settingsController?.handleFeedback(event)
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
                button.toolTip = self.statusToolTip
            }
        }
    }


    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.minimumWidth = Self.menuWidth

        addHeader(to: menu)
        let level = NSMenuItem(title: "Live input level", action: nil, keyEquivalent: "")
        let meter = NSProgressIndicator(frame: NSRect(x: 130, y: 8, width: 235, height: 12))
        meter.minValue = 0
        meter.maxValue = 1
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 30))
        let label = NSTextField(labelWithString: "Live input level")
        label.frame = NSRect(x: 14, y: 7, width: 110, height: 18)
        label.font = .systemFont(ofSize: 11)
        container.addSubview(label)
        container.addSubview(meter)
        level.view = container
        levelItem = level
        menu.addItem(level)

        if let transientFeedback {
            menu.addItem(.separator())
            let feedbackItem = NSMenuItem(
                title: transientFeedback.message,
                action: nil,
                keyEquivalent: ""
            )
            feedbackItem.image = Self.symbol(
                transientFeedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                accessibilityDescription: transientFeedback.message
            )
            feedbackItem.isEnabled = false
            menu.addItem(feedbackItem)
        }

        menu.addItem(.separator())

        let records = store.allRecords().reversed()
        addSectionTitle("Recent Transcripts", to: menu)
        addRecentTranscripts(Array(records.prefix(Self.recentTranscriptLimit)), to: menu)

        if records.isEmpty {
            let empty = NSMenuItem(
                title: "Dictate with \(currentDictationShortcut().displayName) — transcripts appear here",
                action: nil,
                keyEquivalent: ""
            )
            empty.image = Self.symbol("text.bubble", accessibilityDescription: "No transcripts yet")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            addHistoryActions(to: menu)
        }

        let cancelAvailable = canCancelDictation()
        let retryAvailable = canRetryFailedCapture()
        let discardAvailable = canDiscardFailedCapture()
        if cancelAvailable || retryAvailable || discardAvailable {
            menu.addItem(.separator())
            addSectionTitle("Current Session", to: menu)

            if cancelAvailable {
                let cancel = actionItem(
                    title: isRecording() ? "Cancel Recording" : "Cancel Transcription",
                    action: #selector(cancelDictationAction),
                    symbol: "xmark.circle"
                )
                cancel.keyEquivalent = "\u{1b}"
                cancel.keyEquivalentModifierMask = []
                menu.addItem(cancel)
            }

            if retryAvailable {
                menu.addItem(
                    actionItem(
                        title: "Retry Failed Capture",
                        action: #selector(retryLastFailedCaptureAction),
                        symbol: "arrow.clockwise.circle"
                    )
                )
            }

            if discardAvailable {
                menu.addItem(
                    actionItem(
                        title: "Discard Failed Capture",
                        action: #selector(discardFailedCaptureAction),
                        symbol: "trash"
                    )
                )
            }
        }

        menu.addItem(.separator())
        let settings = actionItem(title: "Settings…", action: #selector(showSettings), symbol: "gearshape")
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        let quit = NSMenuItem(
            title: "Quit Speakeasy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = Self.symbol("xmark.square", accessibilityDescription: "Quit Speakeasy")
        menu.addItem(quit)
    }

    // MARK: - Menu construction

    private func addHeader(to menu: NSMenu) {
        let item = NSMenuItem(title: "Speakeasy", action: nil, keyEquivalent: "")
        item.view = MenuHeaderView(
            activity: currentActivity(),
            shortcut: currentDictationShortcut()
        )
        menu.addItem(item)
    }

    private func addRecentTranscripts(_ records: [TranscriptRecord], to menu: NSMenu) {
        for (index, record) in records.enumerated() {
            let item = NSMenuItem(
                title: Self.displayTitle(for: record.finalText),
                action: #selector(pasteHistoryItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = record.finalText
            item.toolTip = "Paste transcript\n\n\(record.finalText)"
            item.image = Self.symbol(
                index == 0 ? "text.quote" : "clock",
                accessibilityDescription: "Paste transcript"
            )
            menu.addItem(item)
        }
    }

    private func addHistoryActions(to menu: NSMenu) {
        let pasteLast = actionItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscriptAction),
            symbol: "text.insert"
        )
        pasteLast.keyEquivalent = "v"
        pasteLast.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pasteLast)

        let copyLast = actionItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscriptAction),
            symbol: "doc.on.doc"
        )
        copyLast.keyEquivalent = "c"
        copyLast.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copyLast)

    }

    private func addSectionTitle(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func actionItem(title: String, action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = Self.symbol(symbol, accessibilityDescription: title)
        return item
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

    @objc private func cancelDictationAction() {
        cancelDictation()
    }

    @objc private func retryLastFailedCaptureAction() {
        retryLastFailedCapture()
    }

    @objc private func discardFailedCaptureAction() {
        discardFailedCapture()
    }

    @objc private func changeShortcutAction() {
        guard canChangeDictationShortcut() else { return }

        setShortcutCaptureActive(true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.presentShortcutRecorder()
            }
        }
    }

    @objc private func resetShortcutAction() {
        guard canChangeDictationShortcut() else { return }
        applyShortcut(.defaultShortcut)
    }

    @objc private func showSettings() {
        if settingsController == nil {
            let model = SettingsModel(
                store: store,
                diagnosticsStore: diagnosticsStore,
                currentMode: currentInvocationMode,
                setMode: selectInvocationMode,
                currentShortcut: currentDictationShortcut,
                changeShortcut: { [weak self] in self?.changeShortcutAction() },
                resetShortcut: { [weak self] in self?.resetShortcutAction() },
                shortcutEnabled: canChangeDictationShortcut,
                availableDevices: availableInputDevices,
                selectedDevice: selectedInputDeviceUID,
                selectDevice: selectInputDevice,
                deviceEnabled: canSelectInputDevice,
                currentModel: currentASRModelKind,
                selectModel: selectASRModel,
                openCorrections: { [weak self] in self?.showCorrections() },
                pasteTranscript: pasteTranscript,
                levelSnapshot: microphoneLevelSnapshot
            )
            settingsController = SettingsWindowController(model: model)
        }
        settingsController?.present()
    }

    @objc private func showCorrections() {
        if correctionEditorController == nil {
            correctionEditorController = CorrectionEditorWindowController(
                loadCorrections: loadCorrections,
                saveCorrections: saveCorrections
            )
        }
        correctionEditorController?.present()
    }

    // MARK: - Helpers

    private var statusToolTip: String {
        "Speakeasy — press \(currentDictationShortcut().accessibilityName) to dictate"
    }

    private func presentShortcutRecorder() {
        defer { setShortcutCaptureActive(false) }

        guard let shortcut = ShortcutRecorder.record(
            currentShortcut: currentDictationShortcut()
        ) else {
            return
        }
        applyShortcut(shortcut)
    }

    private func applyShortcut(_ shortcut: DictationShortcut) {
        switch setDictationShortcut(shortcut) {
        case .success:
            statusItem.button?.toolTip = statusToolTip
        case .failure(let message):
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn’t Change Shortcut"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let meter = self.levelItem?.view?.subviews.last as? NSProgressIndicator else { return }
                meter.doubleValue = Double(self.microphoneLevelSnapshot().normalizedLevel)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        levelTimer?.invalidate()
        levelTimer = nil
        levelItem = nil
    }


    private func currentActivity() -> MenuBarActivity {
        if isRecording() {
            return .listening
        }
        if canCancelDictation() {
            return .transcribing
        }
        return .ready
    }

    private static func displayTitle(for text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > titleMaxLength else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: titleMaxLength)
        return String(collapsed[..<idx]) + "…"
    }

    private static func symbol(_ name: String, accessibilityDescription: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
    }

}

private extension UserFeedbackEvent {
    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}
