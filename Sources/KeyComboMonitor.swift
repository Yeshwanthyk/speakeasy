import CoreGraphics
import Foundation
import os

final class KeyComboMonitor {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "hotkey")
    private let keyCode: CGKeyCode
    private let requiredFlags: CGEventFlags
    private let forbiddenFlags: CGEventFlags
    private let callback: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        keyCode: CGKeyCode,
        requiredFlags: CGEventFlags,
        forbiddenFlags: CGEventFlags = [],
        callback: @escaping () -> Void
    ) {
        self.keyCode = keyCode
        self.requiredFlags = requiredFlags
        self.forbiddenFlags = forbiddenFlags
        self.callback = callback

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<KeyComboMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPointer
        )

        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                logger.debug("Key combo monitor active")
            } else {
                logger.error("Failed to create event tap run loop source")
            }
        } else {
            logger.error("Failed to create event tap; check Accessibility permissions")
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if !flags.contains(requiredFlags) || !flags.intersection(forbiddenFlags).isEmpty {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [callback] in
            callback()
        }
        return nil
    }
}
