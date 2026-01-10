import Carbon
import Foundation
import os

enum HotKeyError: Error {
    case registerFailed(OSStatus)
    case handlerInstallFailed(OSStatus)
}

final class HotKeyManager {
    private let logger = Logger(subsystem: "com.wisp.app", category: "hotkey")
    private let hotKeyID: EventHotKeyID
    private let callback: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: EventHandlerUPP

    init(keyCode: UInt32, modifiers: UInt32, handler callback: @escaping () -> Void) throws {
        self.callback = callback
        self.hotKeyID = EventHotKeyID(signature: OSType(0x48535930), id: 1)

        handler = { _, event, userData in
            guard let event, let userData else {
                return noErr
            }

            var incomingID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &incomingID
            )

            if status != noErr {
                return noErr
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            if incomingID.id == manager.hotKeyID.id && incomingID.signature == manager.hotKeyID.signature {
                manager.callback()
            }

            return noErr
        }

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventSpec,
            userData,
            &handlerRef
        )

        if handlerStatus != noErr {
            throw HotKeyError.handlerInstallFailed(handlerStatus)
        }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            throw HotKeyError.registerFailed(registerStatus)
        }

        logger.debug("Hotkey registered")
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
