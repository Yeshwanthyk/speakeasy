import AppKit
import Foundation

/// Owns the status-bar item and its menu. Rebuilds the menu lazily via
/// `NSMenuDelegate.menuNeedsUpdate`, so no work runs on the transcription path.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let titleMaxLength = 60

    private let store: TranscriptStore
    private let paster: Pasting
    private let currentASRModelKind: () -> ASRModelKind
    private let selectASRModel: (ASRModelKind) -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var transientFeedback: UserFeedbackEvent?
    private var feedbackGeneration = 0

    init(
        store: TranscriptStore,
        paster: Pasting,
        currentASRModelKind: @escaping () -> ASRModelKind = { .parakeetUnified },
        selectASRModel: @escaping (ASRModelKind) -> Void = { _ in }
    ) {
        self.store = store
        self.paster = paster
        self.currentASRModelKind = currentASRModelKind
        self.selectASRModel = selectASRModel
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
        paster.paste(text)
    }

    @objc private func clearHistory() {
        store.clear()
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
}
