import AppKit
import Carbon
import CoreGraphics
import Foundation
import os

protocol DictationKeyMonitoring: AnyObject {
    func setInvocationMode(_ mode: DictationInvocationMode) throws
    func updateShortcut(_ shortcut: DictationShortcut) throws
    func setSuspended(_ isSuspended: Bool)
}

enum KeyComboMonitorError: Error, Equatable {
    case eventHandlerRegistrationFailed(OSStatus)
    case shortcutRegistrationFailed(OSStatus)
    case keyboardMonitorUnavailable

    var userMessage: String {
        switch self {
        case .eventHandlerRegistrationFailed, .keyboardMonitorUnavailable:
            return "Keyboard monitoring is unavailable"
        case .shortcutRegistrationFailed:
            return "That shortcut is already in use"
        }
    }
}

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

struct FunctionKeyGestureState: Sendable {
    private(set) var isPressed = false
    private(set) var wasUsedAsModifier = false
    private(set) var didBeginPushToTalk = false
    private var generation: UInt64 = 0

    mutating func press(mode: DictationInvocationMode) -> UInt64? {
        guard !isPressed else { return nil }
        isPressed = true
        wasUsedAsModifier = false
        didBeginPushToTalk = false
        generation &+= 1
        return mode == .pushToTalk ? generation : nil
    }

    mutating func markUsedAsModifier() -> DictationIntent? {
        guard isPressed else { return nil }
        wasUsedAsModifier = true
        generation &+= 1
        guard didBeginPushToTalk else { return nil }
        didBeginPushToTalk = false
        return .cancel
    }

    mutating func beginPushToTalk(generation expectedGeneration: UInt64) -> Bool {
        guard isPressed,
              !wasUsedAsModifier,
              !didBeginPushToTalk,
              generation == expectedGeneration else {
            return false
        }
        didBeginPushToTalk = true
        return true
    }

    mutating func release(mode: DictationInvocationMode) -> DictationIntent? {
        guard isPressed else { return nil }
        defer { reset() }

        switch mode {
        case .toggle:
            return wasUsedAsModifier ? nil : .toggle
        case .pushToTalk:
            return didBeginPushToTalk ? .pushToTalkEnded : nil
        }
    }

    mutating func reset() {
        isPressed = false
        wasUsedAsModifier = false
        didBeginPushToTalk = false
        generation &+= 1
    }
}

final class KeyComboMonitor: DictationKeyMonitoring {
    private struct CarbonRegistration {
        let ref: EventHotKeyRef
        let id: EventHotKeyID
    }

    private static let signature: OSType = 0x53504B59
    private static let functionHoldDelay: TimeInterval = 0.18
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
    private let inputLock = UnfairLock()
    private var shortcut: DictationShortcut
    private var invocationMode: DictationInvocationMode
    private var isSuspended = false
    private var pushToTalkState = PushToTalkKeyState()
    private var functionKeyState = FunctionKeyGestureState()
    private var escapeIsPressed = false
    private var carbonRegistration: CarbonRegistration?
    private var eventHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init?(
        shortcut: DictationShortcut,
        invocationMode: DictationInvocationMode = .toggle,
        callback: @escaping (DictationIntent) -> Void
    ) {
        guard shortcut.isValid else { return nil }
        self.callback = callback
        self.shortcut = shortcut
        self.invocationMode = invocationMode

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
            return nil
        }

        if invocationMode == .toggle,
           case .keyCombination = shortcut {
            do {
                carbonRegistration = try registerCarbonHotKey(for: shortcut)
            } catch {
                if let eventHandlerRef {
                    RemoveEventHandler(eventHandlerRef)
                    self.eventHandlerRef = nil
                }
                logger.error("Failed to register initial shortcut: \(String(describing: error))")
                return nil
            }
        }

        let eventMask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleKeyboardEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleKeyboardEvent(event)
            return event
        }

        guard globalMonitor != nil || localMonitor != nil else {
            if let carbonRegistration {
                UnregisterEventHotKey(carbonRegistration.ref)
                self.carbonRegistration = nil
            }
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            logger.error("Failed to install keyboard monitor")
            return nil
        }

        logger.debug("Key combo monitor active with \(shortcut.displayName, privacy: .public)")
    }

    deinit {
        if let carbonRegistration {
            UnregisterEventHotKey(carbonRegistration.ref)
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

    func setInvocationMode(_ mode: DictationInvocationMode) throws {
        let snapshot = inputLock.withLock { (shortcut, invocationMode) }
        guard snapshot.1 != mode else { return }

        let candidate: CarbonRegistration?
        if mode == .toggle, case .keyCombination = snapshot.0 {
            candidate = try registerCarbonHotKey(for: snapshot.0)
        } else {
            candidate = nil
        }

        let previous = inputLock.withLock { () -> CarbonRegistration? in
            let previous = carbonRegistration
            invocationMode = mode
            carbonRegistration = candidate
            pushToTalkState.reset()
            functionKeyState.reset()
            escapeIsPressed = false
            return previous
        }
        if let previous {
            UnregisterEventHotKey(previous.ref)
        }
    }

    func updateShortcut(_ shortcut: DictationShortcut) throws {
        guard shortcut.isValid else {
            throw KeyComboMonitorError.shortcutRegistrationFailed(OSStatus(paramErr))
        }

        let mode = inputLock.withLock { invocationMode }
        let candidate: CarbonRegistration?
        if mode == .toggle, case .keyCombination = shortcut {
            candidate = try registerCarbonHotKey(for: shortcut)
        } else {
            candidate = nil
        }

        let previous = inputLock.withLock { () -> CarbonRegistration? in
            let previous = carbonRegistration
            self.shortcut = shortcut
            carbonRegistration = candidate
            pushToTalkState.reset()
            functionKeyState.reset()
            escapeIsPressed = false
            return previous
        }
        if let previous {
            UnregisterEventHotKey(previous.ref)
        }
        logger.info("Updated dictation shortcut to \(shortcut.displayName, privacy: .public)")
    }

    func setSuspended(_ isSuspended: Bool) {
        inputLock.withLock {
            self.isSuspended = isSuspended
            pushToTalkState.reset()
            functionKeyState.reset()
            escapeIsPressed = false
        }
    }

    private func registerCarbonHotKey(for shortcut: DictationShortcut) throws -> CarbonRegistration {
        guard case .keyCombination(let keyCode, let modifiers, _) = shortcut else {
            throw KeyComboMonitorError.shortcutRegistrationFailed(OSStatus(paramErr))
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.nextHotKeyIdentifier())
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(from: modifiers.cgEventFlags),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            logger.error("Failed to register shortcut: \(status)")
            throw KeyComboMonitorError.shortcutRegistrationFailed(status)
        }
        return CarbonRegistration(ref: ref, id: id)
    }

    private func handleKeyboardEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            handleFlagsChanged(event)
            return
        }

        let sideEffect = inputLock.withLock { () -> DictationIntent? in
            guard !isSuspended else { return nil }

            if functionKeyState.isPressed, event.type == .keyDown {
                return functionKeyState.markUsedAsModifier()
            }

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

            guard case .keyCombination(let keyCode, let modifiers, _) = shortcut,
                  event.keyCode == keyCode,
                  invocationMode == .pushToTalk else {
                return nil
            }

            switch event.type {
            case .keyDown:
                let actualModifiers = ShortcutModifiers(eventFlags: event.modifierFlags)
                return pushToTalkState.keyDown(
                    isMatching: actualModifiers == modifiers,
                    isRepeat: event.isARepeat
                )
            case .keyUp:
                return pushToTalkState.keyUp()
            default:
                return nil
            }
        }

        if let sideEffect {
            emit(sideEffect)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let functionIsDown = event.cgEvent?.flags.contains(.maskSecondaryFn)
            ?? event.modifierFlags.contains(.function)
        var scheduledGeneration: UInt64?
        let intent = inputLock.withLock { () -> DictationIntent? in
            guard !isSuspended, shortcut == .functionKey else { return nil }

            if functionIsDown {
                if !ShortcutModifiers(eventFlags: event.modifierFlags).isEmpty {
                    return functionKeyState.markUsedAsModifier()
                }
                scheduledGeneration = functionKeyState.press(mode: invocationMode)
                return nil
            }
            return functionKeyState.release(mode: invocationMode)
        }

        if let scheduledGeneration {
            scheduleFunctionPushToTalk(generation: scheduledGeneration)
        }
        if let intent {
            emit(intent)
        }
    }

    private func scheduleFunctionPushToTalk(generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.functionHoldDelay) { [weak self] in
            guard let self else { return }
            let shouldBegin = self.inputLock.withLock {
                guard !self.isSuspended,
                      self.shortcut == .functionKey,
                      self.invocationMode == .pushToTalk else {
                    return false
                }
                return self.functionKeyState.beginPushToTalk(generation: generation)
            }
            if shouldBegin {
                self.emit(.pushToTalkBegan)
            }
        }
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

        let shouldEmit = inputLock.withLock {
            guard !isSuspended,
                  invocationMode == .toggle,
                  case .keyCombination = shortcut,
                  let activeID = carbonRegistration?.id else {
                return false
            }
            return eventHotKeyID.signature == activeID.signature
                && eventHotKeyID.id == activeID.id
        }
        if shouldEmit {
            emit(.toggle)
        }
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
