import AppKit
import CoreGraphics
import Foundation

struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    static let supported: Self = [.control, .option, .shift, .command]

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: Self = []
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    var displaySymbols: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        return symbols
    }
}

enum DictationShortcut: Codable, Equatable, Sendable {
    case functionKey
    case keyCombination(keyCode: UInt16, modifiers: ShortcutModifiers, keyLabel: String)

    static let defaultShortcut = Self.functionKey

    var displayName: String {
        switch self {
        case .functionKey:
            return "fn"
        case .keyCombination(_, let modifiers, let keyLabel):
            return modifiers.displaySymbols + keyLabel.uppercased()
        }
    }

    var accessibilityName: String {
        switch self {
        case .functionKey:
            return "Function key"
        case .keyCombination:
            return displayName
        }
    }

    var isValid: Bool {
        switch self {
        case .functionKey:
            return true
        case .keyCombination(_, let modifiers, let keyLabel):
            let safeModifiers: ShortcutModifiers = [.control, .option, .command]
            return !modifiers.intersection(safeModifiers).isEmpty
                && !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum DictationShortcutStore {
    private static let key = "dictationShortcut"

    static func selected(defaults: UserDefaults = .standard) -> DictationShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(DictationShortcut.self, from: data),
              shortcut.isValid else {
            return .defaultShortcut
        }
        return shortcut
    }

    static func persist(_ shortcut: DictationShortcut, defaults: UserDefaults = .standard) {
        guard shortcut.isValid, let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

enum DictationShortcutUpdateResult: Equatable, Sendable {
    case success
    case failure(String)
}
