import AppKit
import CoreGraphics
import Foundation
import os

final class RightCommandMonitor {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "hotkey")
    private let callback: () -> Void
    private let stateLock = UnfairLock()
    private var isPressed = false

    private var flagsMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let rightCommandKeyCode: UInt16 = 54

    init(callback: @escaping () -> Void) {
        self.callback = callback

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .flagsChanged {
                    let monitor = Unmanaged<RightCommandMonitor>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                    monitor.handle(event: event)
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        )

        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                logger.debug("Right Command event tap active")
            } else {
                logger.error("Failed to create event tap run loop source")
            }
        } else {
            logger.error("Failed to create event tap; check Accessibility permissions")
        }

        logger.debug("Right Command monitor active")
    }

    deinit {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    private func handle(event: NSEvent) {
        guard event.type == .flagsChanged, event.keyCode == rightCommandKeyCode else {
            return
        }

        handleRightCommand(isDown: event.modifierFlags.contains(.command))
    }

    private func handle(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(rightCommandKeyCode) else {
            return
        }

        handleRightCommand(isDown: event.flags.contains(.maskCommand))
    }

    private func handleRightCommand(isDown: Bool) {
        let shouldTrigger = stateLock.withLock { () -> Bool in
            if isDown {
                if isPressed {
                    return false
                }
                isPressed = true
                return true
            }

            isPressed = false
            return false
        }

        if shouldTrigger {
            DispatchQueue.main.async { [callback] in
                callback()
            }
        }
    }
}
