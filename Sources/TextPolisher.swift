import Foundation

/// A post-correction refinement stage applied to accepted transcript text
/// before persistence and delivery.
///
/// The seam exists so a local model-based polish stage can be added later
/// without touching the dictation flow: implementations receive already
/// corrected text and return replacement text. Implementations must be safe
/// to call from any isolation domain and should enforce their own latency
/// budgets.
protocol TextPolishing: Sendable {
    func polish(_ input: String) async -> String
}

/// Pass-through polisher used as the pipeline default; behaviorally
/// identical to having no polisher installed.
struct IdentityPolisher: TextPolishing {
    func polish(_ input: String) async -> String {
        input
    }
}

/// Output-budget arithmetic shared by current and future polish stages.
///
/// The adaptive ceiling scales with utterance length so short requests stay
/// snappy while long ones cannot run away: `max(48, min(256, ceil(spoken
/// tokens x 1.8) + 24))`.
enum PolishBudget {
    /// Default generation ceiling in tokens.
    static let minimumOutputTokens = 48
    static let maximumOutputTokens = 256
    /// Headroom added over the estimated spoken length.
    static let headroomMultiplier = 1.8
    static let headroomConstant = 24

    /// Estimates spoken-token count from text. Dictation audio transcribes
    /// roughly one token per whitespace-delimited word; a real tokenizer can
    /// replace this without changing callers.
    static func estimateSpokenTokens(in text: String) -> Int {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(words, 1)
    }

    /// Maximum output tokens allowed for the given spoken-token estimate.
    static func maxOutputTokens(spokenTokenEstimate: Int) -> Int {
        let scaled = (Double(max(spokenTokenEstimate, 0)) * headroomMultiplier).rounded(.up)
        let withHeadroom = Int(scaled) + headroomConstant
        return min(max(withHeadroom, minimumOutputTokens), maximumOutputTokens)
    }

    /// Convenience overload estimating tokens from raw text.
    static func maxOutputTokens(forText text: String) -> Int {
        maxOutputTokens(spokenTokenEstimate: estimateSpokenTokens(in: text))
    }
}

/// Verdict returned by `PolishGuard` when output is rejected; `source`
/// carries the original text so callers always fall back to something sane.
enum PolishGuardVerdict: Equatable, Sendable {
    case accepted(String)
    case rejected(reason: PolishRejectionReason, source: String)
}

enum PolishRejectionReason: Equatable, Sendable {
    /// Polish produced empty or single-word output for multi-word speech.
    case collapse
    /// Polish removed one or two meaningful words.
    case meaningLoss
    /// Polish grew the text far beyond anything dictation produces.
    case expansion
}

/// Structural validation of polish output against its spoken source.
///
/// A formatter may remove fillers, fix punctuation, or deduplicate stuttered
/// words; it may not silently drop meaning, collapse the utterance, or run
/// away. Every rejection returns the untouched source text so the dictation
/// result degrades to pre-polish quality instead of vanishing.
enum PolishGuard {
    static let fillerWords: Set<String> = ["um", "uh", "er", "ah", "hmm", "mmm"]
    /// Expansion limits: more than double-plus-eight words, or four times
    /// plus sixty-four characters, is implausible formatting growth.
    static let expansionWordFactor = 2.0
    static let expansionWordConstant = 8
    static let expansionCharacterFactor = 4.0
    static let expansionCharacterConstant = 64

    static func validate(source: String, output: String) -> PolishGuardVerdict {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return source.split(whereSeparator: \.isWhitespace).count > 1
                ? .rejected(reason: .collapse, source: source)
                : .accepted(trimmedOutput)
        }

        let sourceWords = significantWords(in: source)
        let outputWords = significantWords(in: trimmedOutput)

        if Double(outputWords.count) > Double(sourceWords.count) * expansionWordFactor
            + Double(expansionWordConstant)
            || trimmedOutput.count > source.count * Int(expansionCharacterFactor)
            + expansionCharacterConstant {
            return .rejected(reason: .expansion, source: source)
        }

        if outputWords.count < sourceWords.count {
            let lost = missingWords(from: sourceWords, to: outputWords)
            // Removing only fillers or repeated stutter words is legitimate;
            // losing real content is not.
            let contentLoss = lost.filter { !isFillerOrDuplicated($0, source: sourceWords, output: outputWords) }
            switch contentLoss.count {
            case 0:
                break
            case 1, 2:
                return .rejected(reason: .meaningLoss, source: source)
            default:
                return .rejected(reason: .collapse, source: source)
            }
        }

        return .accepted(trimmedOutput)
    }

    /// Validates and falls back in one step, returning the text to deliver.
    static func sanitized(
        source: String,
        output: String,
        onRejection: (PolishRejectionReason) -> Void = { _ in }
    ) -> String {
        switch validate(source: source, output: output) {
        case .accepted(let text):
            return text
        case .rejected(let reason, let source):
            onRejection(reason)
            return source
        }
    }

    // MARK: - Internals

    private static func significantWords(in text: String) -> [String] {
        TranscriptPostProcessor.tokens(in: text)
            .filter(\.hasLetterOrNumber)
            .map(\.normalized)
    }

    private static func isFillerOrDuplicated(
        _ word: String,
        source: [String],
        output: [String]
    ) -> Bool {
        if fillerWords.contains(word) { return true }
        // A word counted as lost because the polish deduplicated a stutter
        // ("the the") loses exactly one copy while the other remains.
        let sourceCount = source.filter { $0 == word }.count
        let outputCount = output.filter { $0 == word }.count
        return outputCount >= sourceCount - 1 && sourceCount >= 2
    }

    private static func missingWords(from source: [String], to output: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for word in output { counts[word, default: 0] += 1 }
        var lost: [String] = []
        for word in source {
            if let available = counts[word], available > 0 {
                counts[word] = available - 1
            } else {
                lost.append(word)
            }
        }
        return lost
    }
}
