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

    init(activity: MenuBarActivity) {
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

        let shortcut = NSTextField(labelWithString: "⌃⌥⇧⌘ S")
        shortcut.frame = NSRect(x: 286, y: 24, width: 78, height: 20)
        shortcut.alignment = .center
        shortcut.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcut.textColor = .secondaryLabelColor
        shortcut.wantsLayer = true
        shortcut.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        shortcut.layer?.cornerRadius = 6
        shortcut.toolTip = "Hyper+S starts and stops dictation"
        addSubview(shortcut)

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

private final class MicrophoneLevelView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var level: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let label = NSTextField(labelWithString: "Input level")
        label.frame = NSRect(x: 14, y: 22, width: 220, height: 17)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        valueLabel.frame = NSRect(x: frameRect.width - 56, y: 22, width: 42, height: 17)
        valueLabel.autoresizingMask = [.minXMargin]
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valueLabel.textColor = .tertiaryLabelColor
        addSubview(valueLabel)

        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.28).cgColor
        track.layer?.cornerRadius = 2.5
        addSubview(track)

        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = 2.5
        track.addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        track.frame = NSRect(x: 14, y: 10, width: bounds.width - 28, height: 5)
        fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * level, height: track.bounds.height)
    }

    func update(snapshot: MicrophoneLevelSnapshot) {
        let bounded = min(max(CGFloat(snapshot.normalizedLevel), 0), 1)
        level = bounded
        valueLabel.stringValue = "\(Int((bounded * 100).rounded()))%"
        fill.layer?.backgroundColor = level > 0.82
            ? NSColor.systemOrange.cgColor
            : NSColor.controlAccentColor.cgColor
        setAccessibilityLabel("Microphone input level \(valueLabel.stringValue)")
        needsLayout = true
    }
}

private final class DiagnosticsReportView: NSView {
    init(report: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 104))

        let title = NSTextField(labelWithString: "Private, on-device activity")
        title.frame = NSRect(x: 14, y: 78, width: 352, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: report)
        detail.frame = NSRect(x: 14, y: 12, width: 352, height: 60)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        addSubview(detail)

        setAccessibilityLabel("Private, on-device activity. \(report)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Owns the status-bar item and its menu. Rebuilds the menu lazily via
/// `NSMenuDelegate.menuNeedsUpdate`, so no work runs on the transcription path.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let titleMaxLength = 54
    private static let recentTranscriptLimit = 6
    private static let menuWidth: CGFloat = 380

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
        isRecording: @escaping () -> Bool = { false },
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
            button.toolTip = "Speakeasy — Hyper+S to dictate"
        }

        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
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
                button.toolTip = "Speakeasy — Hyper+S to dictate"
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
        menu.minimumWidth = Self.menuWidth

        addHeader(to: menu)

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
                title: "Dictate with Hyper+S — transcripts appear here",
                action: nil,
                keyEquivalent: ""
            )
            empty.image = Self.symbol("text.bubble", accessibilityDescription: "No transcripts yet")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            addHistoryActions(records: Array(records), to: menu)
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
        addSectionTitle("Dictation Settings", to: menu)
        addInvocationMode(to: menu)
        addMicrophoneControls(to: menu)
        addModelControls(to: menu)
        addDiagnostics(to: menu)

        menu.addItem(.separator())
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
        item.view = MenuHeaderView(activity: currentActivity())
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

    private func addHistoryActions(records: [TranscriptRecord], to menu: NSMenu) {
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

        let historyItem = NSMenuItem(
            title: "All Transcripts (\(records.count))",
            action: nil,
            keyEquivalent: ""
        )
        historyItem.image = Self.symbol("clock.arrow.circlepath", accessibilityDescription: "All transcripts")

        let historyMenu = NSMenu(title: "All Transcripts")
        historyMenu.autoenablesItems = false

        let clear = actionItem(
            title: "Clear Transcript History…",
            action: #selector(confirmClearHistory),
            symbol: "trash"
        )
        historyMenu.addItem(clear)
        historyMenu.addItem(.separator())

        for record in records {
            let item = NSMenuItem(
                title: Self.displayTitle(for: record.finalText),
                action: #selector(pasteHistoryItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = record.finalText
            item.toolTip = record.finalText
            historyMenu.addItem(item)
        }

        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
    }

    private func addInvocationMode(to menu: NSMenu) {
        let selectedMode = currentInvocationMode()
        let modeItem = NSMenuItem(
            title: "Dictation Mode — \(Self.shortName(for: selectedMode))",
            action: nil,
            keyEquivalent: ""
        )
        modeItem.image = Self.symbol("hand.tap", accessibilityDescription: "Dictation mode")

        let modeMenu = NSMenu(title: "Dictation Mode")
        modeMenu.autoenablesItems = false
        for mode in DictationInvocationMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectInvocationModeItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == selectedMode ? .on : .off
            item.isEnabled = mode != selectedMode
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
    }

    private func addMicrophoneControls(to menu: NSMenu) {
        let devices = availableInputDevices()
        let selectedUID = selectedInputDeviceUID()
        let selectedName = devices.first(where: { $0.uid == selectedUID })?.name ?? "System Default"
        let microphoneItem = NSMenuItem(
            title: "Microphone — \(Self.displayTitle(for: selectedName))",
            action: nil,
            keyEquivalent: ""
        )
        microphoneItem.image = Self.symbol("mic", accessibilityDescription: "Microphone")

        let microphoneMenu = NSMenu(title: "Microphone")
        microphoneMenu.autoenablesItems = false
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

        let snapshot = microphoneLevelSnapshot()
        let level = NSMenuItem(title: Self.levelTitle(for: snapshot), action: nil, keyEquivalent: "")
        let levelView = MicrophoneLevelView(
            frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: 44)
        )
        levelView.update(snapshot: snapshot)
        level.view = levelView
        levelItem = level
        menu.addItem(level)
    }

    private func addModelControls(to menu: NSMenu) {
        let selectedKind = currentASRModelKind()
        let modelItem = NSMenuItem(
            title: "Speech Model — \(Self.shortName(for: selectedKind))",
            action: nil,
            keyEquivalent: ""
        )
        modelItem.image = Self.symbol("waveform.badge.mic", accessibilityDescription: "Speech model")

        let modelMenu = NSMenu(title: "Speech Model")
        modelMenu.autoenablesItems = false
        for kind in ASRModelKind.allCases {
            let item = NSMenuItem(
                title: kind.displayName,
                action: #selector(selectModelItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = kind.preferenceValue
            item.state = kind == selectedKind ? .on : .off
            item.isEnabled = kind != selectedKind
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
    }

    private func addDiagnostics(to menu: NSMenu) {
        let diagnosticsItem = NSMenuItem(title: "Stats & Diagnostics", action: nil, keyEquivalent: "")
        diagnosticsItem.image = Self.symbol("chart.bar.xaxis", accessibilityDescription: "Stats and diagnostics")

        let diagnosticsMenu = NSMenu(title: "Stats & Diagnostics")
        diagnosticsMenu.autoenablesItems = false
        let report = diagnosticsStore?.report() ?? "Diagnostics unavailable"
        let reportItem = NSMenuItem(title: report, action: nil, keyEquivalent: "")
        reportItem.isEnabled = false
        reportItem.view = DiagnosticsReportView(report: report)
        diagnosticsMenu.addItem(reportItem)
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
    }

    private func addSectionTitle(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
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

    @objc private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear transcript history?"
        alert.informativeText = "This permanently removes all saved transcripts from this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

    private static func shortName(for mode: DictationInvocationMode) -> String {
        switch mode {
        case .toggle:
            return "Hands-Free"
        case .pushToTalk:
            return "Push to Talk"
        }
    }

    private static func shortName(for kind: ASRModelKind) -> String {
        switch kind {
        case .parakeet110M:
            return "Parakeet 110M"
        case .parakeetUnified:
            return "Parakeet Unified"
        }
    }

    private static func levelTitle(for snapshot: MicrophoneLevelSnapshot) -> String {
        "Microphone Level: \(Int((snapshot.normalizedLevel * 100).rounded()))%"
    }

    private static func symbol(_ name: String, accessibilityDescription: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
    }

    private func updateLevelItem() {
        guard let levelItem else { return }
        let snapshot = microphoneLevelSnapshot()
        levelItem.title = Self.levelTitle(for: snapshot)
        (levelItem.view as? MicrophoneLevelView)?.update(snapshot: snapshot)
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
