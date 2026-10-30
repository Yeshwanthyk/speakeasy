import AppKit
import Carbon
import Foundation

/// Reads the character a key types on one keyboard layout.
protocol KeyboardLayoutTranslating {
    /// The character `keyCode` types, with Command held when `command` is true.
    func character(for keyCode: UInt16, command: Bool) -> String?
}

/// Finds the physical key that types a shortcut letter, the way AppKit
/// resolves key equivalents: the Command layer of the active layout first
/// (so "Dvorak - QWERTY ⌘" pastes with QWERTY V), then its plain layer, then
/// the ASCII-capable layout for non-Latin layouts, then ANSI V.
enum PasteKeyResolver {
    static let fallbackKeyCode = UInt16(kVK_ANSI_V)
    private static let keyCodes: Range<UInt16> = 0..<128

    static func keyCode(
        for character: Character,
        current: KeyboardLayoutTranslating?,
        asciiCapable: KeyboardLayoutTranslating?
    ) -> UInt16 {
        let target = String(character).lowercased()
        func find(_ layout: KeyboardLayoutTranslating?, command: Bool) -> UInt16? {
            guard let layout else { return nil }
            return keyCodes.first { layout.character(for: $0, command: command)?.lowercased() == target }
        }
        return find(current, command: true)
            ?? find(current, command: false)
            ?? find(asciiCapable, command: false)
            ?? fallbackKeyCode
    }
}

/// A Text Input Source's Unicode key layout, translated with UCKeyTranslate.
struct SystemKeyboardLayout: KeyboardLayoutTranslating {
    private static let commandModifierState = UInt32((cmdKey >> 8) & 0xFF)
    private let layoutData: Data

    init?(source: TISInputSource?) {
        guard let source,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    static func current() -> SystemKeyboardLayout? {
        SystemKeyboardLayout(source: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    static func asciiCapable() -> SystemKeyboardLayout? {
        SystemKeyboardLayout(source: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    func character(for keyCode: UInt16, command: Bool) -> String? {
        layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                command ? Self.commandModifierState : 0,
                UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// Text Input Sources must be read on the main thread. Paste requests on the
/// main thread refresh the cached key; other threads reuse the last value.
final class PasteKeyCodeCache: @unchecked Sendable {
    static let shared = PasteKeyCodeCache()

    private let lock = UnfairLock()
    private var cached = PasteKeyResolver.fallbackKeyCode

    func current() -> CGKeyCode {
        if Thread.isMainThread {
            let resolved = PasteKeyResolver.keyCode(
                for: "v",
                current: SystemKeyboardLayout.current(),
                asciiCapable: SystemKeyboardLayout.asciiCapable()
            )
            lock.withLock { cached = resolved }
            return resolved
        }
        return lock.withLock { cached }
    }
}
