import AppKit
import Carbon
import Foundation

@MainActor
final class ShortcutCaptureView: NSView {
    var onShortcutChanged: ((DictationShortcut) -> Void)?

    private let valueLabel = NSTextField(labelWithString: "Press a shortcut")
    private let guidanceLabel = NSTextField(wrappingLabelWithString: "Tap fn by itself, or press a key with Command, Control, or Option.")
    private var functionKeyIsPressed = false
    private var functionKeyWasCombined = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let field = NSView(frame: NSRect(x: 0, y: 38, width: frameRect.width, height: 38))
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        field.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        field.layer?.borderWidth = 2
        field.layer?.cornerRadius = 8
        addSubview(field)

        valueLabel.frame = NSRect(x: 12, y: 9, width: frameRect.width - 24, height: 20)
        valueLabel.alignment = .center
        valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .labelColor
        field.addSubview(valueLabel)

        guidanceLabel.frame = NSRect(x: 2, y: 0, width: frameRect.width - 4, height: 30)
        guidanceLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        guidanceLabel.textColor = .secondaryLabelColor
        guidanceLabel.alignment = .center
        guidanceLabel.maximumNumberOfLines = 2
        addSubview(guidanceLabel)

        setAccessibilityLabel("Shortcut recorder. Press the Function key, or a key with Command, Control, or Option.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            super.keyDown(with: event)
            return
        }
        captureKeyDown(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode != UInt16(kVK_Escape) else {
            return false
        }
        captureKeyDown(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let functionIsDown = event.cgEvent?.flags.contains(.maskSecondaryFn)
            ?? event.modifierFlags.contains(.function)

        if functionIsDown {
            if !functionKeyIsPressed {
                functionKeyIsPressed = true
                functionKeyWasCombined = false
                valueLabel.stringValue = "fn"
                guidanceLabel.stringValue = "Release fn to use it as the shortcut."
            }
            if !ShortcutModifiers(eventFlags: event.modifierFlags).isEmpty {
                functionKeyWasCombined = true
                showValidation("Use fn by itself, not as part of a combination.")
            }
            return
        }

        guard functionKeyIsPressed else { return }
        functionKeyIsPressed = false
        if functionKeyWasCombined {
            functionKeyWasCombined = false
            return
        }
        publish(.functionKey)
    }

    private func captureKeyDown(_ event: NSEvent) {
        if functionKeyIsPressed {
            functionKeyWasCombined = true
            showValidation("Use fn by itself, not as part of a combination.")
            return
        }

        let modifiers = ShortcutModifiers(eventFlags: event.modifierFlags)
        let safeModifiers: ShortcutModifiers = [.command, .control, .option]
        guard !modifiers.intersection(safeModifiers).isEmpty else {
            showValidation("Add Command, Control, or Option to avoid triggering while typing.")
            return
        }
        guard let keyLabel = Self.keyLabel(for: event) else {
            showValidation("Choose a letter, number, punctuation key, or Space.")
            return
        }

        publish(
            .keyCombination(
                keyCode: event.keyCode,
                modifiers: modifiers,
                keyLabel: keyLabel
            )
        )
    }

    private func publish(_ shortcut: DictationShortcut) {
        valueLabel.stringValue = shortcut.displayName
        guidanceLabel.stringValue = "Ready to save"
        onShortcutChanged?(shortcut)
    }

    private func showValidation(_ message: String) {
        valueLabel.stringValue = "Try another shortcut"
        guidanceLabel.stringValue = message
        NSSound.beep()
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Tab:
            return "Tab"
        case kVK_Return:
            return "Return"
        case kVK_Delete:
            return "Delete"
        case kVK_ForwardDelete:
            return "Forward Delete"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return characters.uppercased()
    }
}

enum ShortcutRecorder {
    @MainActor
    static func record(currentShortcut: DictationShortcut) -> DictationShortcut? {
        let alert = NSAlert()
        alert.messageText = "Set Dictation Shortcut"
        alert.informativeText = "Current shortcut: \(currentShortcut.displayName)"
        alert.alertStyle = .informational

        let captureView = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 320, height: 76))
        alert.accessoryView = captureView
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.isEnabled = false

        var capturedShortcut: DictationShortcut?
        captureView.onShortcutChanged = { [weak alert] shortcut in
            capturedShortcut = shortcut
            alert?.buttons.first?.isEnabled = true
        }

        let window = alert.window
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(
            options: [.activateAllWindows, .activateIgnoringOtherApps]
        )
        NSApplication.shared.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak window, weak captureView] in
            guard let window, let captureView else { return }
            window.makeFirstResponder(captureView)
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return capturedShortcut
    }
}
