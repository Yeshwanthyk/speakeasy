import AppKit
import Carbon
import Foundation
import os

final class PasteboardPaster: Pasting {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "paste")
    private let feedback: UserFeedback

    init(feedback: UserFeedback) {
        self.feedback = feedback
    }

    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendCommandV()
    }

    private func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.error("Failed to create CGEventSource")
            feedback.error("Paste failed")
            return
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        ) else {
            logger.error("Failed to create keyDown event")
            feedback.error("Paste failed")
            return
        }

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        ) else {
            logger.error("Failed to create keyUp event")
            feedback.error("Paste failed")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
