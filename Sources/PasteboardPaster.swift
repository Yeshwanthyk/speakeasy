import AppKit
import Carbon
import Foundation
import os

struct PasteEvents {
    let post: () -> Void
}

final class PasteboardPaster: Pasting {
    private static let maximumSettleDelay: TimeInterval = 0.25

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "paste")
    private let pasteboard: PasteboardAccess
    private let targetProvider: DeliveryTargetProviding
    private let writeClipboard: ((String) -> Bool)?
    private let createPasteEvents: () -> PasteEvents?
    private let postPasteEvents: (() -> Bool)?
    private let settleQueue: DispatchQueue
    private let settleDelay: TimeInterval
    private let operationLock = NSLock()

    init(
        pasteboard: PasteboardAccess = SystemPasteboardAccess(),
        targetProvider: DeliveryTargetProviding = SystemDeliveryTargetProvider(),
        settleQueue: DispatchQueue = DispatchQueue(
            label: "com.speakeasy.app.pasteboard.settle",
            qos: .utility
        ),
        settleDelay: TimeInterval = 0.1,
        createPasteEvents: (() -> PasteEvents?)? = nil,
        writeClipboard: ((String) -> Bool)? = nil,
        postPasteEvents: (() -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.targetProvider = targetProvider
        self.writeClipboard = writeClipboard
        self.settleQueue = settleQueue
        self.settleDelay = min(max(0, settleDelay), Self.maximumSettleDelay)
        self.postPasteEvents = postPasteEvents
        if let createPasteEvents {
            self.createPasteEvents = createPasteEvents
        } else {
            self.createPasteEvents = { [logger] in
                Self.makePasteEvents(logger: logger)
            }
        }
    }

    func copy(_ text: String) -> TranscriptDeliveryOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        let snapshot = pasteboard.snapshot()
        let changeCount = pasteboard.changeCount
        guard writeAndVerify(text) else {
            restoreAfterFailedWrite(snapshot: snapshot, previousChangeCount: changeCount)
            return .clipboardWriteFailed
        }
        return .clipboardUpdated
    }

    /// Compatibility entry point for callers that do not have a target
    /// identity. The coordinator always uses the target-aware overload.
    func paste(_ text: String) -> TranscriptDeliveryOutcome {
        paste(text, target: nil)
    }

    func paste(
        _ text: String,
        target: TranscriptDeliveryTarget?
    ) -> TranscriptDeliveryOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        let snapshot = pasteboard.snapshot()
        let previousChangeCount = pasteboard.changeCount
        guard writeAndVerify(text) else {
            restoreAfterFailedWrite(snapshot: snapshot, previousChangeCount: previousChangeCount)
            return .clipboardWriteFailed
        }
        let writeChangeCount = pasteboard.changeCount

        // Without a complete snapshot it is safer to leave the transcript on
        // the clipboard than to post a paste that cannot be restored safely.
        guard let snapshot else {
            logger.error("Could not snapshot the existing clipboard; leaving transcript available")
            return .clipboardUpdated
        }

        guard targetCanReceivePaste(target) else {
            logger.info("No stable external paste target; leaving transcript on the clipboard")
            return .clipboardUpdated
        }

        if let postPasteEvents {
            guard postPasteEvents() else {
                return .clipboardUpdated
            }
            if writeClipboard == nil {
                scheduleRestore(snapshot: snapshot, changeCount: writeChangeCount)
            }
            return .eventsPosted
        }

        guard let events = createPasteEvents() else {
            logger.error("Could not create both paste events")
            return .clipboardUpdated
        }

        // Both events are constructed before either event is posted.
        events.post()
        scheduleRestore(snapshot: snapshot, changeCount: writeChangeCount)
        return .eventsPosted
    }

    private func writeAndVerify(_ text: String) -> Bool {
        if let writeClipboard {
            return writeClipboard(text)
        }

        guard pasteboard.write(string: text) else {
            return false
        }
        return pasteboard.string() == text
    }

    private func restoreAfterFailedWrite(
        snapshot: PasteboardSnapshot?,
        previousChangeCount: Int
    ) {
        guard writeClipboard == nil,
              let snapshot,
              pasteboard.changeCount == previousChangeCount + 1 else {
            return
        }
        guard pasteboard.restore(snapshot) else {
            logger.error("Failed to restore clipboard after write verification failed")
            return
        }
        logger.debug("Restored clipboard after write verification failed")
    }

    private func targetCanReceivePaste(_ target: TranscriptDeliveryTarget?) -> Bool {
        guard let target else {
            return true
        }

        guard case .external(let application) = target else {
            return false
        }

        guard targetProvider.isRunning(application) else {
            logger.info("Paste target terminated before delivery")
            return false
        }

        guard targetProvider.currentTarget() == target else {
            logger.info("Paste target changed before delivery")
            return false
        }
        return true
    }

    private func scheduleRestore(snapshot: PasteboardSnapshot, changeCount: Int) {
        settleQueue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self else { return }

            self.operationLock.lock()
            defer { self.operationLock.unlock() }

            guard self.pasteboard.changeCount == changeCount else {
                self.logger.info("Skipping clipboard restore because a newer clipboard change exists")
                return
            }

            guard self.pasteboard.restore(snapshot) else {
                self.logger.error("Failed to restore the previous clipboard")
                return
            }
            self.logger.debug("Restored the previous clipboard")
        }
    }

    private static func makePasteEvents(logger: Logger) -> PasteEvents? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.error("Failed to create CGEventSource")
            return nil
        }

        // Construct both events before returning the pair. This prevents a
        // partially-created Command-V sequence from being posted.
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        ) else {
            logger.error("Failed to create keyDown event")
            return nil
        }

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        ) else {
            logger.error("Failed to create keyUp event")
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return PasteEvents {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
