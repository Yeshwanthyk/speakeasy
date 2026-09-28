import AppKit
import Foundation

enum OverlayStyle: String, CaseIterable {
    case bottomPill
    case topIndicator

    var title: String {
        switch self {
        case .bottomPill: return "Bottom pill (with live text)"
        case .topIndicator: return "Notch/top indicator (minimal)"
        }
    }
}

struct OverlayPreferences {
    private static let styleKey = "overlayStyle"
    private static let liveTextKey = "overlayLiveText"

    static func style(in defaults: UserDefaults = .standard) -> OverlayStyle {
        OverlayStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .bottomPill
    }

    static func setStyle(_ style: OverlayStyle, in defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: styleKey)
    }

    static func showsLiveText(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: liveTextKey) as? Bool ?? true
    }

    static func setShowsLiveText(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: liveTextKey)
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recording, transcribing, done, error(String)
    }

    @Published private(set) var phase: Phase = .recording
    @Published private(set) var preview = ""
    @Published private(set) var mode: DictationInvocationMode = .toggle
    private(set) var revision = 0
    private(set) var lastUndoRecordID: UUID?

    var modeLabel: String { mode == .pushToTalk ? "Push to Talk" : "Hands-Free" }
    var displayedText: String {
        if case .error(let message) = phase { return message }
        if preview.isEmpty { return phase == .transcribing ? "Transcribing…" : "Listening…" }
        return Self.tail(preview, limit: 140)
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

    func start(mode: DictationInvocationMode) {
        self.mode = mode
        preview = ""
        revision = 0
        phase = .recording
    }

    func adopt(_ text: String) {
        guard phase == .recording, text != preview else { return }
        preview = text
        revision += 1
    }

    func setMode(_ mode: DictationInvocationMode) { self.mode = mode }
    func transcribe() { phase = .transcribing }
    func finish() { phase = .done }
    func fail(_ message: String) { phase = .error(message) }

    func copyLast(record: TranscriptRecord?, copy: (String) -> Void) {
        guard let record else { return }
        copy(record.finalText)
    }

    func pasteLast(record: TranscriptRecord?, paste: (String) -> Void) {
        guard let record else { return }
        paste(record.finalText)
    }

    func undoCorrections(record: TranscriptRecord?, copy: (String) -> Void, paste: (String) -> Bool) {
        guard let record else { return }
        copy(record.rawText)
        if paste(record.rawText) { lastUndoRecordID = record.id }
    }
}
