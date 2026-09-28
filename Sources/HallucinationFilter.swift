import Foundation

enum HallucinationFilterReason: Equatable, Sendable {
    case exactPattern
    case nearSilenceInvention
    case excessiveTokenDensity(wordCount: Int, maximum: Int)
    case excessiveCharacterDensity(characterCount: Int, maximum: Int)
    case repeatedNGram(tokenCount: Int, repetitions: Int)
    case repeatedSentence(tokenCount: Int)
}

enum HallucinationFilterVerdict: Equatable, Sendable {
    case accepted
    case rejected(HallucinationFilterReason)

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    var rejectionReason: HallucinationFilterReason? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}

struct HallucinationFilter {
    static let defaultPatterns: Set<String> = [
        "yeah", "yeah.", "yes", "yes.", "okay", "okay.", "ok", "ok.",
        "uh-huh", "uh-huh.", "mhm", "mhm.", "hmm", "hmm.", "huh", "huh.",
        "oh", "oh.", "ah", "ah.", "uh", "uh.", "um", "um.",
        "bye", "bye.", "no", "no.", "so", "so.", "right", "right.",
    ]

    /// Decoder boilerplate that is especially likely when the input is silent.
    /// Keep this list conservative: ordinary quiet speech must still pass.
    static let defaultKnownInventionPatterns: Set<String> = [
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "the end",
    ]

    static let silenceRMSThreshold: Float = 0.002
    static let maximumTokensPerSecond = 5.0
    static let maximumCharactersPerSecond = 30.0
    static let minimumTokenBudget = 12
    static let minimumCharacterBudget = 64

    private static let minimumRepeatedNGramLength = 3
    private static let maximumRepeatedNGramLength = 12
    private static let minimumRepeatedNGramRepetitions = 4
    private static let minimumRepeatedSentenceLength = 8

    private let patterns: Set<String>
    private let knownInventionPatterns: Set<String>

    init(
        patterns: Set<String> = Self.defaultPatterns,
        knownInventionPatterns: Set<String> = Self.defaultKnownInventionPatterns
    ) {
        self.patterns = Set(patterns.map(Self.normalize))
        self.knownInventionPatterns = Set(knownInventionPatterns.map(Self.normalize))
    }

    func verdict(
        for text: String,
        activeDurationSeconds: TimeInterval? = nil,
        activeRMS: Float? = nil
    ) -> HallucinationFilterVerdict {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return .accepted }

        // Brief acknowledgements are legitimate dictation unless the audio
        // itself is nearly silent. Never reject them on text alone.
        if patterns.contains(normalized),
           let activeDurationSeconds, activeDurationSeconds < 1.5,
           let activeRMS, activeRMS.isFinite, activeRMS <= Self.silenceRMSThreshold {
            return .rejected(.exactPattern)
        }

        if let activeRMS,
           activeRMS.isFinite,
           activeRMS <= Self.silenceRMSThreshold,
           knownInventionPatterns.contains(normalized) {
            return .rejected(.nearSilenceInvention)
        }

        let tokens = Self.tokens(in: normalized)
        if let activeDurationSeconds,
           activeDurationSeconds.isFinite,
           activeDurationSeconds >= 0
        {
            let maximumWordCount = Self.maximumCount(
                minimum: Self.minimumTokenBudget,
                perSecond: Self.maximumTokensPerSecond,
                duration: activeDurationSeconds
            )
            if tokens.count > maximumWordCount {
                return .rejected(
                    .excessiveTokenDensity(wordCount: tokens.count, maximum: maximumWordCount)
                )
            }

            let characterCount = normalized.reduce(into: 0) { count, character in
                if !character.isWhitespace { count += 1 }
            }
            let maximumCharacterCount = Self.maximumCount(
                minimum: Self.minimumCharacterBudget,
                perSecond: Self.maximumCharactersPerSecond,
                duration: activeDurationSeconds
            )
            if characterCount > maximumCharacterCount {
                return .rejected(
                    .excessiveCharacterDensity(
                        characterCount: characterCount,
                        maximum: maximumCharacterCount
                    )
                )
            }
        }

        if let reason = Self.repeatedNGramReason(in: tokens) {
            return .rejected(reason)
        }

        if let reason = Self.repeatedSentenceReason(in: normalized) {
            return .rejected(reason)
        }

        return .accepted
    }

    func rejectionReason(
        for text: String,
        activeDurationSeconds: TimeInterval? = nil,
        activeRMS: Float? = nil
    ) -> HallucinationFilterReason? {
        verdict(
            for: text,
            activeDurationSeconds: activeDurationSeconds,
            activeRMS: activeRMS
        ).rejectionReason
    }

    func isLikelyHallucination(_ text: String) -> Bool {
        verdict(for: text).isRejected
    }

    private static func maximumCount(
        minimum: Int,
        perSecond: Double,
        duration: TimeInterval
    ) -> Int {
        // Int(_:) traps above Int.max; a huge duration means no density cap.
        let scaled = (duration * perSecond).rounded(.up)
        guard scaled < Double(Int.max) else { return Int.max }
        return max(minimum, Int(scaled))
    }

    private static func normalize(_ text: String) -> String {
        text
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in normalizedText: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func finishCurrent() {
            guard !current.isEmpty else { return }
            tokens.append(String(current))
            current.removeAll()
        }

        for scalar in normalizedText.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                finishCurrent()
            }
        }
        finishCurrent()
        return tokens
    }

    private static func repeatedNGramReason(
        in tokens: [String]
    ) -> HallucinationFilterReason? {
        guard tokens.count >= minimumRepeatedNGramLength * minimumRepeatedNGramRepetitions else {
            return nil
        }

        for length in stride(
            from: maximumRepeatedNGramLength,
            through: minimumRepeatedNGramLength,
            by: -1
        ) {
            guard tokens.count >= length * minimumRepeatedNGramRepetitions else { continue }
            for start in 0...(tokens.count - length * minimumRepeatedNGramRepetitions) {
                var repetitions = 1
                while start + (repetitions + 1) * length <= tokens.count,
                      sameTokens(
                          tokens,
                          firstStart: start,
                          secondStart: start + repetitions * length,
                          length: length
                      ) {
                    repetitions += 1
                }

                if repetitions >= minimumRepeatedNGramRepetitions {
                    return .repeatedNGram(tokenCount: length, repetitions: repetitions)
                }
            }
        }
        return nil
    }

    private static func sameTokens(
        _ tokens: [String],
        firstStart: Int,
        secondStart: Int,
        length: Int
    ) -> Bool {
        for offset in 0..<length where tokens[firstStart + offset] != tokens[secondStart + offset] {
            return false
        }
        return true
    }

    private static func repeatedSentenceReason(
        in normalizedText: String
    ) -> HallucinationFilterReason? {
        let sentences = sentenceTokens(in: normalizedText)
        guard sentences.count >= 2 else { return nil }

        for index in 1..<sentences.count {
            let previous = sentences[index - 1]
            let current = sentences[index]
            guard previous.count >= minimumRepeatedSentenceLength,
                  previous == current
            else { continue }
            return .repeatedSentence(tokenCount: previous.count)
        }
        return nil
    }

    private static func sentenceTokens(in normalizedText: String) -> [[String]] {
        var sentences: [[String]] = []
        var currentSentence: [String] = []
        var currentToken = String.UnicodeScalarView()

        func finishToken() {
            guard !currentToken.isEmpty else { return }
            currentSentence.append(String(currentToken))
            currentToken.removeAll()
        }

        func finishSentence() {
            finishToken()
            guard !currentSentence.isEmpty else { return }
            sentences.append(currentSentence)
            currentSentence.removeAll(keepingCapacity: true)
        }

        for scalar in normalizedText.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                currentToken.append(scalar)
            } else if ".!?".unicodeScalars.contains(scalar) {
                finishSentence()
            } else {
                finishToken()
            }
        }
        finishSentence()
        return sentences
    }
}
