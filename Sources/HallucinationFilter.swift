import Foundation

struct HallucinationFilter {
    static let defaultPatterns: Set<String> = [
        "yeah", "yeah.", "yes", "yes.", "okay", "okay.", "ok", "ok.",
        "uh-huh", "uh-huh.", "mhm", "mhm.", "hmm", "hmm.", "huh", "huh.",
        "oh", "oh.", "ah", "ah.", "uh", "uh.", "um", "um.",
        "bye", "bye.", "no", "no.", "so", "so.", "right", "right.",
    ]

    private let patterns: Set<String>

    init(patterns: Set<String> = Self.defaultPatterns) {
        self.patterns = patterns
    }

    func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return patterns.contains(normalized)
    }
}
