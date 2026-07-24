import Carbon
import CoreGraphics
import Foundation
import os

final class KeyComboMonitor {
    private static let signature: OSType = 0x53504B59

    // Protects `nextIdentifier`. Two concurrent `init`s would otherwise race
    // on `Self.nextIdentifier += 1`. In practice the app only ever creates
    // one monitor, but tests and defensive callers should not depend on that.
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
    private let callback: () -> Void
    private let hotKeyID: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(
        keyCode: CGKeyCode,
        requiredFlags: CGEventFlags,
        forbiddenFlags: CGEventFlags = [],
        callback: @escaping () -> Void
    ) {
        self.callback = callback

        hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.nextHotKeyIdentifier())

        if !forbiddenFlags.isEmpty {
            logger.info("Ignoring forbiddenFlags; Carbon hotkeys match only required modifiers")
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

        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(from: requiredFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            logger.error("Failed to register hotkey: \(registerStatus)")
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
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
            eventHotKeyID.id == hotKeyID.id
        else {
            return noErr
        }

        DispatchQueue.main.async { [callback] in
            callback()
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
