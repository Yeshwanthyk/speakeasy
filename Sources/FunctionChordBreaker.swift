import CoreGraphics
import Foundation
import os

/// Tools such as Raycast and Karabiner fire their own action on a bare fn
/// tap. A push-to-talk hold looks like a long tap to them, so once a hold
/// begins dictation Speakeasy posts one press of a key that has no function
/// while fn is down; they then read the hold as a chord. The press is posted
/// at the HID tap so HID taps, session taps, and global monitors observe it,
/// and an annotated-session tap drops it before the focused app, which would
/// otherwise beep at an unhandled key. Without that tap nothing is posted.
final class FunctionChordBreaker {
    /// Unassigned on Apple keyboards; types nothing and triggers nothing.
    static let keyCode: CGKeyCode = 0x44
    /// Marks Speakeasy's own events in `eventSourceUserData`.
    static let marker: Int64 = 0x5350_4B59_4342

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "hotkey")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didAttemptInstall = false

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// The press and release posted for one hold, under the held flags.
    static func eventSpecs(flags: CGEventFlags) -> [(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags)] {
        [(keyCode, true, flags), (keyCode, false, flags)]
    }

    static func isOwnEvent(userData: Int64, keyCode eventKeyCode: Int64) -> Bool {
        userData == marker && eventKeyCode == Int64(keyCode)
    }

    /// Call on the main thread while fn is held.
    func post(flags: CGEventFlags = .maskSecondaryFn) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard installTapIfNeeded() else { return }
        let source = CGEventSource(stateID: .privateState)
        let events = Self.eventSpecs(flags: flags).compactMap { spec -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: spec.keyCode, keyDown: spec.keyDown) else {
                return nil
            }
            event.flags = spec.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            return event
        }
        guard events.count == 2 else { return }
        events.forEach { $0.post(tap: .cghidEventTap) }
    }

    private func installTapIfNeeded() -> Bool {
        if tap != nil { return true }
        guard !didAttemptInstall else { return false }
        didAttemptInstall = true

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let userInfo {
                    let breaker = Unmanaged<FunctionChordBreaker>.fromOpaque(userInfo).takeUnretainedValue()
                    if let tap = breaker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            let isOwn = FunctionChordBreaker.isOwnEvent(
                userData: event.getIntegerValueField(.eventSourceUserData),
                keyCode: event.getIntegerValueField(.keyboardEventKeycode)
            )
            return isOwn ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.info("Chord breaker unavailable: could not create the event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }
}
