import AppKit
import Foundation

/// Owns the status-bar item and its menu. Rebuilds the menu lazily via
/// `NSMenuDelegate.menuNeedsUpdate`, so no work runs on the transcription path.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let titleMaxLength = 60

    private let store: TranscriptStore
    private let paster: Pasting
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(store: TranscriptStore, paster: Pasting) {
        self.store = store
        self.paster = paster
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wisp")
            image?.isTemplate = true
            button.image = image
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

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

    // MARK: - Helpers

    private static func displayTitle(for text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > titleMaxLength else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: titleMaxLength)
        return String(collapsed[..<idx]) + "…"
    }
}
