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
    static let undoFallbackKeyCode = UInt16(kVK_ANSI_Z)
    private static let keyCodes: Range<UInt16> = 0..<128

    static func keyCode(
        for character: Character,
        current: KeyboardLayoutTranslating?,
        asciiCapable: KeyboardLayoutTranslating?,
        fallback: UInt16 = fallbackKeyCode
    ) -> UInt16 {
        let target = String(character).lowercased()
        func find(_ layout: KeyboardLayoutTranslating?, command: Bool) -> UInt16? {
            guard let layout else { return nil }
            return keyCodes.first { layout.character(for: $0, command: command)?.lowercased() == target }
        }
        return find(current, command: true)
            ?? find(current, command: false)
            ?? find(asciiCapable, command: false)
            ?? fallback
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

/// Shortcut keys resolved from the active layout, off the paste hot path.
///
/// Text Input Sources must be read on the main thread, and a resolution costs
/// TIS round trips plus up to 256 `UCKeyTranslate` calls. The cache is
/// prewarmed at launch, refreshed when macOS reports an input-source change,
/// and refreshed again asynchronously at key-up while inference runs, so a
/// paste only reads a cached key. A miss resolves once on the main thread;
/// other threads fall back until a refresh has run.
final class PasteKeyCodeCache: @unchecked Sendable {
    typealias Resolver = (_ character: Character, _ fallback: CGKeyCode) -> CGKeyCode

    static let shared = PasteKeyCodeCache()

    /// Paste and undo; prewarmed so the first dictation never resolves.
    static let prewarmedKeys: [Character: CGKeyCode] = [
        "v": PasteKeyResolver.fallbackKeyCode,
        "z": PasteKeyResolver.undoFallbackKeyCode
    ]

    private let lock = UnfairLock()
    private let resolve: Resolver
    /// Guarded by `lock`.
    private var cached: [Character: CGKeyCode] = [:]
    /// Every character requested so far with its fallback. Guarded by `lock`.
    private var requested: [Character: CGKeyCode] = PasteKeyCodeCache.prewarmedKeys
    /// Main thread only.
    private var inputSourceObserver: InputSourceChangeObserver?

    init(resolve: @escaping Resolver = PasteKeyCodeCache.resolveFromActiveLayout) {
        self.resolve = resolve
    }

    func current() -> CGKeyCode {
        keyCode(for: "v", fallback: PasteKeyResolver.fallbackKeyCode)
    }

    func keyCode(for character: Character, fallback: CGKeyCode) -> CGKeyCode {
        if let cachedKey = lock.withLock({ cached[character] }) {
            return cachedKey
        }
        guard Thread.isMainThread else {
            lock.withLock { requested[character] = requested[character] ?? fallback }
            return fallback
        }
        let resolved = resolve(character, fallback)
        lock.withLock {
            cached[character] = resolved
            requested[character] = requested[character] ?? fallback
        }
        return resolved
    }

    /// Re-resolves every requested key. Main thread only.
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let keys = lock.withLock { requested }
        var resolved: [Character: CGKeyCode] = [:]
        for (character, fallback) in keys {
            resolved[character] = resolve(character, fallback)
        }
        lock.withLock { cached = resolved }
    }

    /// Refreshes on the main queue without blocking the caller.
    func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// Prewarms the cache and refreshes it on every input-source change.
    /// Idempotent. Main thread only.
    func startMonitoring(center: DistributedNotificationCenter = .default()) {
        dispatchPrecondition(condition: .onQueue(.main))
        refresh()
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = InputSourceChangeObserver(center: center) { [weak self] in
            self?.refresh()
        }
    }

    static func resolveFromActiveLayout(_ character: Character, fallback: CGKeyCode) -> CGKeyCode {
        PasteKeyResolver.keyCode(
            for: character,
            current: SystemKeyboardLayout.current(),
            asciiCapable: SystemKeyboardLayout.asciiCapable(),
            fallback: fallback
        )
    }
}

/// Observes the distributed Text Input Source notifications. Speakeasy is a
/// menu-bar app that is rarely active, and AppKit suspends distributed
/// delivery for inactive apps, so the observer asks for immediate delivery.
final class InputSourceChangeObserver: NSObject {
    static let notificationNames = [
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
    ]

    private let center: DistributedNotificationCenter
    private let onChange: () -> Void

    init(center: DistributedNotificationCenter, onChange: @escaping () -> Void) {
        self.center = center
        self.onChange = onChange
        super.init()
        for name in Self.notificationNames {
            center.addObserver(
                self,
                selector: #selector(inputSourceChanged(_:)),
                name: name,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    deinit {
        center.removeObserver(self)
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        if Thread.isMainThread {
            onChange()
        } else {
            DispatchQueue.main.async { [onChange] in onChange() }
        }
    }
}
