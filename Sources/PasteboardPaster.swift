import AppKit
import Foundation
import os

struct PasteEvents {
    let post: () -> Void
}

final class PasteboardPaster: Pasting {
    /// Slow Electron and Chromium targets read the clipboard well after
    /// Command-V is posted; restoring sooner can paste the previous contents.
    static let defaultSettleDelay: TimeInterval = 0.5
    static let maximumSettleDelay: TimeInterval = 1.0
    /// A snapshot prepared at key-up is dropped after this long so a large
    /// clipboard image is not held in memory when no paste follows.
    static let preparedSnapshotLifetime: TimeInterval = 120

    private struct PreparedSnapshot {
        let changeCount: Int
        let snapshot: PasteboardSnapshot
        let generation: UInt64
    }

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "paste")
    private let pasteboard: PasteboardAccess
    private let targetProvider: DeliveryTargetProviding
    private let writeClipboard: ((String) -> Bool)?
    private let createPasteEvents: () -> PasteEvents?
    private let postPasteEvents: (() -> Bool)?
    private let refreshPasteKey: () -> Void
    private let settleQueue: DispatchQueue
    private let prepareQueue: DispatchQueue
    private let settleDelay: TimeInterval
    private let operationLock = NSLock()
    /// Guarded by `operationLock`.
    private var prepared: PreparedSnapshot?
    private var preparedGeneration: UInt64 = 0

    init(
        pasteboard: PasteboardAccess = SystemPasteboardAccess(),
        targetProvider: DeliveryTargetProviding = SystemDeliveryTargetProvider(),
        settleQueue: DispatchQueue = DispatchQueue(
            label: "com.speakeasy.app.pasteboard.settle",
            qos: .utility
        ),
        prepareQueue: DispatchQueue = DispatchQueue(
            label: "com.speakeasy.app.pasteboard.prepare",
            qos: .userInitiated
        ),
        settleDelay: TimeInterval = PasteboardPaster.defaultSettleDelay,
        pasteKeyCode: @escaping () -> CGKeyCode = { PasteKeyCodeCache.shared.current() },
        refreshPasteKey: @escaping () -> Void = { PasteKeyCodeCache.shared.scheduleRefresh() },
        createPasteEvents: (() -> PasteEvents?)? = nil,
        writeClipboard: ((String) -> Bool)? = nil,
        postPasteEvents: (() -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.targetProvider = targetProvider
        self.writeClipboard = writeClipboard
        self.settleQueue = settleQueue
        self.prepareQueue = prepareQueue
        self.settleDelay = min(max(0, settleDelay), Self.maximumSettleDelay)
        self.postPasteEvents = postPasteEvents
        self.refreshPasteKey = refreshPasteKey
        if let createPasteEvents {
            self.createPasteEvents = createPasteEvents
        } else {
            self.createPasteEvents = { [logger] in
                let events = Self.makePasteEvents(keyCode: pasteKeyCode())
                if events == nil {
                    logger.error("Could not create Command-V events")
                }
                return events
            }
        }
    }

    func copy(_ text: String) -> TranscriptDeliveryOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        let snapshot = pasteboard.snapshot()
        let changeCount = pasteboard.changeCount
        guard writeAndVerify(text, transient: false) else {
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

        let previousChangeCount = pasteboard.changeCount
        let snapshot = takeSnapshot(changeCount: previousChangeCount)
        // Clipboard managers skip the temporary write; any path that leaves
        // the transcript on the clipboard rewrites it as an ordinary copy.
        guard writeAndVerify(text, transient: true) else {
            restoreAfterFailedWrite(snapshot: snapshot, previousChangeCount: previousChangeCount)
            return .clipboardWriteFailed
        }
        let writeChangeCount = pasteboard.changeCount

        // Without a complete snapshot it is safer to leave the transcript on
        // the clipboard than to post a paste that cannot be restored safely.
        guard let snapshot else {
            logger.error("Could not snapshot the existing clipboard; leaving transcript available")
            keepOnClipboard(text, writeChangeCount: writeChangeCount)
            return .clipboardUpdated
        }

        guard targetCanReceivePaste(target) else {
            logger.info("No stable external paste target; leaving transcript on the clipboard")
            keepOnClipboard(text, writeChangeCount: writeChangeCount)
            return .clipboardUpdated
        }

        if let postPasteEvents {
            guard postPasteEvents() else {
                keepOnClipboard(text, writeChangeCount: writeChangeCount)
                return .clipboardUpdated
            }
            if writeClipboard == nil {
                scheduleRestore(snapshot: snapshot, changeCount: writeChangeCount)
            }
            return .eventsPosted
        }

        guard let events = createPasteEvents() else {
            logger.error("Could not create both paste events")
            keepOnClipboard(text, writeChangeCount: writeChangeCount)
            return .clipboardUpdated
        }

        // Both events are constructed before either event is posted.
        events.post()
        scheduleRestore(snapshot: snapshot, changeCount: writeChangeCount)
        return .eventsPosted
    }

    /// Snapshots the clipboard off the paste's critical path. Reading every
    /// representation can take long for images or app-promised data; the
    /// paste reuses this snapshot only if nothing changed the clipboard since.
    func preparePaste() {
        refreshPasteKey()
        prepareQueue.async { [weak self] in
            self?.capturePreparedSnapshot()
        }
    }

    private func capturePreparedSnapshot() {
        operationLock.lock()
        defer { operationLock.unlock() }

        let changeCount = pasteboard.changeCount
        if let prepared, prepared.changeCount == changeCount {
            return
        }
        prepared = nil
        guard let snapshot = pasteboard.snapshot(),
              pasteboard.changeCount == changeCount else {
            return
        }
        preparedGeneration &+= 1
        let generation = preparedGeneration
        prepared = PreparedSnapshot(changeCount: changeCount, snapshot: snapshot, generation: generation)
        prepareQueue.asyncAfter(deadline: .now() + Self.preparedSnapshotLifetime) { [weak self] in
            self?.expirePreparedSnapshot(generation: generation)
        }
    }

    private func expirePreparedSnapshot(generation: UInt64) {
        operationLock.lock()
        defer { operationLock.unlock() }
        if prepared?.generation == generation {
            prepared = nil
        }
    }

    /// Caller holds `operationLock`. A prepared snapshot is used at most once.
    private func takeSnapshot(changeCount: Int) -> PasteboardSnapshot? {
        defer { prepared = nil }
        if let prepared, prepared.changeCount == changeCount {
            return prepared.snapshot
        }
        return pasteboard.snapshot()
    }

    private func writeAndVerify(_ text: String, transient: Bool) -> Bool {
        if let writeClipboard {
            return writeClipboard(text)
        }

        guard pasteboard.write(string: text, transient: transient) else {
            return false
        }
        return pasteboard.string() == text
    }

    private func keepOnClipboard(_ text: String, writeChangeCount: Int) {
        guard writeClipboard == nil, pasteboard.changeCount == writeChangeCount else { return }
        if !pasteboard.write(string: text, transient: false) {
            logger.error("Could not rewrite the transcript as an ordinary clipboard item")
        }
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

    /// Command plus the given key, e.g. Command-Z for undo.
    static func makeShortcutEvents(keyCode: CGKeyCode) -> PasteEvents? {
        makePasteEvents(keyCode: keyCode)
    }

    /// Builds Command-V for the key that types "v" on the active layout.
    /// Both events are constructed before either can be posted.
    static func makePasteEvents(
        keyCode: CGKeyCode,
        makeEvent: (CGKeyCode, Bool) -> CGEvent? = { keyCode, keyDown in
            CGEvent(
                keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
                virtualKey: keyCode,
                keyDown: keyDown
            )
        }
    ) -> PasteEvents? {
        guard let keyDown = makeEvent(keyCode, true),
              let keyUp = makeEvent(keyCode, false) else {
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
