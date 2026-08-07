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

private final class MicrophoneLevelView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var level: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let label = NSTextField(labelWithString: "Live input level")
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

private enum MenuStatsFormatter {
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func duration(milliseconds: Double) -> String {
        let seconds = max(milliseconds, 0) / 1_000
        if seconds < 60 {
            return "\(Int(seconds.rounded())) sec"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(Int(minutes.rounded())) min"
        }
        return String(format: "%.1f hr", minutes / 60)
    }

    static func latency(milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds < 1_000 {
            return "\(Int(milliseconds.rounded())) ms"
        }
        return String(format: "%.1f sec", milliseconds / 1_000)
    }

    static func percentage(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }
}

private final class MenuSectionHeaderView: NSView {
    init(title: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 25))

        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 14, y: 3, width: width - 28, height: 17)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class ProductivityStatsView: NSView {
    init(summary: ProductivitySummary) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 238))

        addLabel(
            "Your dictation impact",
            frame: NSRect(x: 18, y: 207, width: 364, height: 19),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        addLabel(
            "Compared with typing at 70 words per minute",
            frame: NSRect(x: 18, y: 188, width: 364, height: 17),
            font: .systemFont(ofSize: 10.5, weight: .regular),
            color: .secondaryLabelColor
        )

        addLabel(
            MenuStatsFormatter.duration(milliseconds: summary.timeSavedMs),
            frame: NSRect(x: 18, y: 145, width: 165, height: 35),
            font: .monospacedDigitSystemFont(ofSize: 27, weight: .semibold),
            color: summary.timeSavedMs > 0 ? .controlAccentColor : .secondaryLabelColor
        )
        addLabel(
            "estimated time saved",
            frame: NSRect(x: 18, y: 126, width: 165, height: 17),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: .secondaryLabelColor
        )

        let verticalDivider = NSBox(frame: NSRect(x: 195, y: 122, width: 1, height: 58))
        verticalDivider.boxType = .separator
        addSubview(verticalDivider)

        addLabel(
            MenuStatsFormatter.count(summary.lifetimeWords),
            frame: NSRect(x: 216, y: 151, width: 166, height: 29),
            font: .monospacedDigitSystemFont(ofSize: 21, weight: .semibold),
            color: .labelColor
        )
        addLabel(
            "words dictated",
            frame: NSRect(x: 216, y: 132, width: 166, height: 17),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: .secondaryLabelColor
        )
        addLabel(
            "\(MenuStatsFormatter.count(summary.lifetimeDictations)) dictations  ·  \(MenuStatsFormatter.percentage(summary.deliveryRate)) delivered",
            frame: NSRect(x: 216, y: 113, width: 166, height: 17),
            font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            color: .tertiaryLabelColor
        )

        let horizontalDivider = NSBox(frame: NSRect(x: 18, y: 98, width: 364, height: 1))
        horizontalDivider.boxType = .separator
        addSubview(horizontalDivider)

        addLabel(
            "Today",
            frame: NSRect(x: 18, y: 71, width: 72, height: 17),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: .secondaryLabelColor
        )
        addLabel(
            "\(MenuStatsFormatter.count(summary.todayWords)) words from \(MenuStatsFormatter.count(summary.todayDictations)) dictations",
            frame: NSRect(x: 92, y: 71, width: 290, height: 17),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            color: .labelColor
        )

        addLabel(
            "Speed",
            frame: NSRect(x: 18, y: 49, width: 72, height: 17),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: .secondaryLabelColor
        )
        addLabel(
            "Text is typically ready in \(MenuStatsFormatter.latency(milliseconds: summary.releaseToTextP50Ms))",
            frame: NSRect(x: 92, y: 49, width: 290, height: 17),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            color: .labelColor
        )

        let note = summary.usesEstimatedSpeakingDuration
            ? "Based on 70 wpm typing. New dictations use your measured dictation time."
            : "Based on 70 wpm typing and your measured dictation time."
        addLabel(
            note,
            frame: NSRect(x: 18, y: 12, width: 364, height: 30),
            font: .systemFont(ofSize: 9.5, weight: .regular),
            color: .tertiaryLabelColor,
            maximumLines: 2
        )

        setAccessibilityLabel(
            "Dictation impact. \(MenuStatsFormatter.duration(milliseconds: summary.timeSavedMs)) estimated time saved. "
                + "\(summary.lifetimeWords) words dictated across \(summary.lifetimeDictations) dictations."
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func addLabel(
        _ text: String,
        frame: NSRect,
        font: NSFont,
        color: NSColor,
        maximumLines: Int = 1
    ) {
        let label = maximumLines == 1
            ? NSTextField(labelWithString: text)
            : NSTextField(wrappingLabelWithString: text)
        label.frame = frame
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = maximumLines
        label.lineBreakMode = maximumLines == 1 ? .byTruncatingTail : .byWordWrapping
        addSubview(label)
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
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var transientFeedback: UserFeedbackEvent?
    private var feedbackGeneration = 0
    private var levelTimer: Timer?
    private weak var levelItem: NSMenuItem?
    private var correctionEditorController: CorrectionEditorWindowController?

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
                title: "Dictate with \(currentDictationShortcut().displayName) — transcripts appear here",
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
        addShortcutControls(to: menu)
        addMicrophoneControls(to: menu)
        addModelControls(to: menu)
        addCorrectionControls(to: menu)
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

    private func addShortcutControls(to menu: NSMenu) {
        let shortcut = currentDictationShortcut()
        let shortcutItem = NSMenuItem(
            title: "Shortcut — \(shortcut.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        shortcutItem.image = Self.symbol("keyboard", accessibilityDescription: "Dictation shortcut")

        let shortcutMenu = NSMenu(title: "Dictation Shortcut")
        shortcutMenu.autoenablesItems = false

        let change = actionItem(
            title: "Change Shortcut…",
            action: #selector(changeShortcutAction),
            symbol: "keyboard.badge.ellipsis"
        )
        change.isEnabled = canChangeDictationShortcut()
        shortcutMenu.addItem(change)

        let reset = actionItem(
            title: "Reset to fn",
            action: #selector(resetShortcutAction),
            symbol: "arrow.counterclockwise"
        )
        reset.isEnabled = canChangeDictationShortcut() && shortcut != .defaultShortcut
        shortcutMenu.addItem(reset)

        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)
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

        if isRecording() {
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

    private func addCorrectionControls(to menu: NSMenu) {
        menu.addItem(
            actionItem(
                title: "Corrections…",
                action: #selector(showCorrections),
                symbol: "text.badge.checkmark"
            )
        )
    }

    private func addDiagnostics(to menu: NSMenu) {
        let summary = diagnosticsStore?.productivitySummary()
            ?? DiagnosticsFormatter.summary(document: DiagnosticsDocument(), today: "")
        let statsTitle = summary.lifetimeWords > 0
            ? "Stats — \(MenuStatsFormatter.duration(milliseconds: summary.timeSavedMs)) saved"
            : "Stats & Insights"
        let diagnosticsItem = NSMenuItem(title: statsTitle, action: nil, keyEquivalent: "")
        diagnosticsItem.image = Self.symbol("chart.bar.xaxis", accessibilityDescription: "Stats and insights")

        let diagnosticsMenu = NSMenu(title: "Stats & Insights")
        diagnosticsMenu.autoenablesItems = false
        let summaryItem = NSMenuItem(title: "Dictation impact", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        summaryItem.view = ProductivityStatsView(summary: summary)
        diagnosticsMenu.addItem(summaryItem)

        diagnosticsMenu.addItem(.separator())
        let technicalItem = NSMenuItem(title: "Technical Details", action: nil, keyEquivalent: "")
        technicalItem.image = Self.symbol("gauge", accessibilityDescription: "Technical details")
        let technicalMenu = NSMenu(title: "Technical Details")
        technicalMenu.autoenablesItems = false
        addTechnicalDetail(
            title: "Typical release to text",
            value: MenuStatsFormatter.latency(milliseconds: summary.releaseToTextP50Ms),
            to: technicalMenu
        )
        addTechnicalDetail(
            title: "95% release to text",
            value: MenuStatsFormatter.latency(milliseconds: summary.releaseToTextP95Ms),
            to: technicalMenu
        )
        addTechnicalDetail(
            title: "Estimated typing time",
            value: MenuStatsFormatter.duration(milliseconds: summary.estimatedTypingDurationMs),
            to: technicalMenu
        )
        addTechnicalDetail(
            title: "Measured dictation time",
            value: MenuStatsFormatter.duration(milliseconds: summary.speakingDurationMs),
            to: technicalMenu
        )
        if summary.usesEstimatedSpeakingDuration {
            addTechnicalDetail(
                title: "Older dictation pace estimate",
                value: "150 words/min",
                to: technicalMenu
            )
        }
        technicalItem.submenu = technicalMenu
        diagnosticsMenu.addItem(technicalItem)

        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
    }

    private func addTechnicalDetail(title: String, value: String, to menu: NSMenu) {
        let item = NSMenuItem(title: "\(title) — \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addSectionTitle(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = MenuSectionHeaderView(title: title, width: Self.menuWidth)
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
