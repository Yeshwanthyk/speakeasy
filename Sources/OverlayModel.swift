import Foundation

/// Where the while-recording indicator sits. Raw values are the v1 keys so
/// stored choices keep decoding.
enum OverlayStyle: String, CaseIterable, Identifiable, Sendable {
    /// A compact capsule at the top center: it grows out of the notch, or
    /// sits inside the menu bar on a display without one.
    case top = "topIndicator"
    /// A small floating pill just above the Dock.
    case bottom = "bottomPill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top center"
        case .bottom: return "Bottom"
        }
    }

    var detail: String {
        switch self {
        case .top: return "Beside the notch or in the menu bar"
        case .bottom: return "A small pill above the Dock"
        }
    }
}

/// Recording-overlay preferences.
///
/// Schema 2 (this version) made the indicator minimal: the top capsule is the
/// default and the live transcript is off unless chosen. Migration from v1:
/// - v1 wrote `overlayLiveText` only when the toggle changed, and it
///   defaulted on, so a stored `true` means the person turned it off and back
///   on. Only that explicit opt-in survives; anything else reads as off.
/// - v1 wrote `overlayStyle` only when a tile was clicked, and the bottom pill
///   was preselected, so a stored bottom pill is weak evidence. It is kept
///   only together with an explicit live-text opt-in (the pill was where text
///   lived); otherwise it resets to the new default top capsule.
struct OverlayPreferences {
    static let styleKey = "overlayStyle"
    static let liveTextKey = "overlayLiveText"
    static let schemaKey = "overlayPreferencesSchema"
    static let currentSchema = 2
    static let defaultStyle: OverlayStyle = .top

    static func style(in defaults: UserDefaults = .standard) -> OverlayStyle {
        migrateIfNeeded(in: defaults)
        return OverlayStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? defaultStyle
    }

    static func setStyle(_ style: OverlayStyle, in defaults: UserDefaults = .standard) {
        migrateIfNeeded(in: defaults)
        defaults.set(style.rawValue, forKey: styleKey)
    }

    static func showsLiveText(in defaults: UserDefaults = .standard) -> Bool {
        migrateIfNeeded(in: defaults)
        return defaults.object(forKey: liveTextKey) as? Bool ?? false
    }

    static func setShowsLiveText(_ value: Bool, in defaults: UserDefaults = .standard) {
        migrateIfNeeded(in: defaults)
        defaults.set(value, forKey: liveTextKey)
    }

    static func migrateIfNeeded(in defaults: UserDefaults) {
        guard defaults.integer(forKey: schemaKey) < currentSchema else { return }
        let explicitLiveText = (defaults.object(forKey: liveTextKey) as? Bool) == true
        if !explicitLiveText {
            defaults.removeObject(forKey: liveTextKey)
            if defaults.string(forKey: styleKey) == OverlayStyle.bottom.rawValue {
                defaults.removeObject(forKey: styleKey)
            }
        }
        defaults.set(currentSchema, forKey: schemaKey)
    }
}

/// Pure state for the recording indicator. Every event returns the effect
/// the presenter must apply, so the transitions are testable without AppKit.
struct OverlayModel: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case hidden, recording, processing, error(String)
    }

    enum Effect: Equatable, Sendable {
        case noChange
        case present
        /// Present the error, then send `expireError(token:)` after `duration`.
        case presentError(token: UInt64, duration: TimeInterval)
        case dismiss
    }

    static let errorDisplayDuration: TimeInterval = 1.6
    static let liveTextLimit = 72
    static let fallbackErrorMessage = "Dictation failed"

    private(set) var phase: Phase = .hidden
    private(set) var preview = ""
    private(set) var revision = 0
    private(set) var errorToken: UInt64 = 0
    private(set) var showsLiveText = false

    var isVisible: Bool { phase != .hidden }

    /// The single line under or beside the indicator, or nil for the compact
    /// shape: an error message, or the live transcript tail when opted in.
    var displayedText: String? {
        switch phase {
        case .hidden:
            return nil
        case .error(let message):
            return message
        case .recording, .processing:
            guard showsLiveText, !preview.isEmpty else { return nil }
            return Self.tail(preview, limit: Self.liveTextLimit)
        }
    }

    var accessibilityLabel: String? {
        switch phase {
        case .hidden: return nil
        case .recording: return "Speakeasy is recording"
        case .processing: return "Speakeasy is processing dictation"
        case .error(let message): return "Speakeasy: \(message)"
        }
    }

    static func tail(_ text: String, limit: Int = 190) -> String {
        guard text.count > limit else { return text }
        let suffix = text.suffix(max(1, limit - 1))
        if let boundary = suffix.firstIndex(of: " "), boundary != suffix.startIndex {
            let words = suffix[suffix.index(after: boundary)...]
            if !words.isEmpty { return "…" + words }
        }
        return "…" + suffix
    }

    mutating func record(showsLiveText: Bool) -> Effect {
        self.showsLiveText = showsLiveText
        preview = ""
        revision = 0
        phase = .recording
        return .present
    }

    mutating func process() -> Effect {
        phase = .processing
        return .present
    }

    /// Hides recording or processing. An error stays up until it expires.
    mutating func hide() -> Effect {
        switch phase {
        case .hidden, .error:
            return .noChange
        case .recording, .processing:
            phase = .hidden
            return .dismiss
        }
    }

    mutating func fail(_ message: String) -> Effect {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        errorToken &+= 1
        phase = .error(trimmed.isEmpty ? Self.fallbackErrorMessage : trimmed)
        return .presentError(token: errorToken, duration: Self.errorDisplayDuration)
    }

    mutating func expireError(token: UInt64) -> Effect {
        guard case .error = phase, token == errorToken else { return .noChange }
        phase = .hidden
        return .dismiss
    }

    /// Adopts a live preview while recording. Returns whether the text changed.
    @discardableResult
    mutating func adopt(_ text: String) -> Bool {
        guard phase == .recording, showsLiveText else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != preview else { return false }
        preview = trimmed
        revision += 1
        return true
    }
}
