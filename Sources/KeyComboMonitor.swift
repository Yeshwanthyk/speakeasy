import AppKit
import Carbon
import CoreGraphics
import Foundation
import os

struct PushToTalkKeyState: Sendable {
    private(set) var isPressed = false

    mutating func keyDown(isMatching: Bool, isRepeat: Bool) -> DictationIntent? {
        guard isMatching, !isRepeat, !isPressed else { return nil }
        isPressed = true
        return .pushToTalkBegan
    }

    mutating func keyUp() -> DictationIntent? {
        guard isPressed else { return nil }
        isPressed = false
        return .pushToTalkEnded
    }

    mutating func reset() {
        isPressed = false
    }
}

final class KeyComboMonitor {
    private static let signature: OSType = 0x53504B59

    // Protects `nextIdentifier`. Two concurrent `init`s would otherwise race
    // on `Self.nextIdentifier += 1`.
    private static let identifierLock = UnfairLock()
    private static var nextIdentifier: UInt32 = 1

    private static func nextHotKeyIdentifier() -> UInt32 {
        identifierLock.withLock {
            let id = nextIdentifier
            nextIdentifier &+= 1
            return id
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else {
            return noErr
        }

        let monitor = Unmanaged<KeyComboMonitor>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return monitor.handle(event: event)
    }

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "hotkey")
    private let callback: (DictationIntent) -> Void
    private let keyCode: CGKeyCode
    private let requiredFlags: CGEventFlags
    private let forbiddenFlags: CGEventFlags
    private let hotKeyID: EventHotKeyID
    private let inputLock = UnfairLock()
    private var invocationMode: DictationInvocationMode = .toggle
    private var pushToTalkState = PushToTalkKeyState()
    private var escapeIsPressed = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        keyCode: CGKeyCode,
        requiredFlags: CGEventFlags,
        forbiddenFlags: CGEventFlags = [],
        callback: @escaping (DictationIntent) -> Void
    ) {
        self.callback = callback
        self.keyCode = keyCode
        self.requiredFlags = requiredFlags
        self.forbiddenFlags = forbiddenFlags
        hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.nextHotKeyIdentifier())

        if !forbiddenFlags.isEmpty {
            logger.info("Ignoring forbiddenFlags for Carbon hotkeys; key events still enforce them")
        }

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            logger.error("Failed to install hotkey handler: \(installStatus)")
            return
        }

        registerCarbonHotKey()

        let eventMask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleKeyboardEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleKeyboardEvent(event)
            return event
        }

        guard globalMonitor != nil || localMonitor != nil else {
            logger.error("Failed to install release-capable keyboard monitor")
            return
        }

        logger.debug("Key combo monitor active")
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func setInvocationMode(_ mode: DictationInvocationMode) {
        let shouldRegister = inputLock.withLock { () -> Bool in
            invocationMode = mode
            pushToTalkState.reset()
            escapeIsPressed = false
            return mode == .toggle
        }

        if shouldRegister {
            registerCarbonHotKey()
        } else {
            unregisterCarbonHotKey()
        }
    }

    private func registerCarbonHotKey() {
        guard hotKeyRef == nil else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(from: requiredFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            logger.error("Failed to register hotkey: \(status)")
            return
        }
        hotKeyRef = ref
    }

    private func unregisterCarbonHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func handleKeyboardEvent(_ event: NSEvent) {
        let intent = inputLock.withLock { () -> DictationIntent? in
            if event.keyCode == UInt16(kVK_Escape) {
                switch event.type {
                case .keyDown where !event.isARepeat && !escapeIsPressed:
                    escapeIsPressed = true
                    return .cancel
                case .keyUp:
                    escapeIsPressed = false
                    return nil
                default:
                    return nil
                }
            }

            guard event.keyCode == UInt16(keyCode), invocationMode == .pushToTalk else {
                return nil
            }

            switch event.type {
            case .keyDown:
                return pushToTalkState.keyDown(
                    isMatching: flagsMatch(event),
                    isRepeat: event.isARepeat
                )
            case .keyUp:
                // Once the matching key went down, release modifiers may have
                // changed. The pressed-state gate makes this release valid,
                // while duplicate and stale key-ups remain no-ops.
                return pushToTalkState.keyUp()
            default:
                return nil
            }
        }

        guard let intent else { return }
        emit(intent)
    }

    private func flagsMatch(_ event: NSEvent) -> Bool {
        guard let flags = event.cgEvent?.flags else { return false }
        guard flags.contains(requiredFlags) else { return false }
        return flags.intersection(forbiddenFlags).isEmpty
    }

    private func emit(_ intent: DictationIntent) {
        DispatchQueue.main.async { [callback] in
            callback(intent)
        }
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard let event else {
            return noErr
        }

        var eventHotKeyID = EventHotKeyID()
        let status = withUnsafeMutablePointer(to: &eventHotKeyID) { pointer in
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                pointer
            )
        }

        guard status == noErr else {
            logger.error("Failed to inspect hotkey event: \(status)")
            return status
        }

        guard
            eventHotKeyID.signature == hotKeyID.signature,
            eventHotKeyID.id == hotKeyID.id,
            inputLock.withLock({ invocationMode == .toggle })
        else {
            return noErr
        }

        emit(.toggle)
        return noErr
    }

    static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0

        if flags.contains(.maskCommand) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.maskControl) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.maskAlternate) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.maskShift) {
            modifiers |= UInt32(shiftKey)
        }

        return modifiers
    }
}
