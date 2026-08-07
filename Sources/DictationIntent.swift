import Foundation

enum DictationIntent: Equatable, Sendable {
    case toggle
    case pushToTalkBegan
    case pushToTalkEnded
    case cancel
}

enum DictationInvocationMode: String, CaseIterable, Codable, Sendable {
    case toggle
    case pushToTalk

    /// The existing press-once/press-again behavior is also the hands-free mode.
    static let handsFree = Self.toggle

    var displayName: String {
        switch self {
        case .toggle:
            return "Toggle (Hands-Free)"
        case .pushToTalk:
            return "Push to Talk"
        }
    }
}
