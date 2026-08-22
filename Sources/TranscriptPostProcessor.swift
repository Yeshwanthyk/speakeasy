import Foundation

struct TranscriptCorrection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var heard: String
    var written: String
    var isEnabled: Bool

    init(id: UUID = UUID(), heard: String, written: String, isEnabled: Bool = true) {
        self.id = id
        self.heard = heard
        self.written = written
        self.isEnabled = isEnabled
    }
}

enum TranscriptPostProcessorError: Error, Equatable {
    case tooManyCorrections(Int)
    case tooManyEnabledCorrections(Int)
    case heardIsEmpty(index: Int)
    case writtenIsTooLong(index: Int, count: Int)
    case heardIsTooLong(index: Int, count: Int)
    case duplicateHeard(index: Int, duplicateOf: Int)
}

struct ProcessedTranscript: Equatable, Sendable {
    let rawText: String
    let finalText: String
}

/// A bounded, immutable text cleanup pass for accepted ASR output.
///
/// Rules are compiled into token indexes at initialization. `process` only
/// tokenizes the input and walks those indexes; it does not construct regular
/// expressions, read settings, or recursively inspect replacement output.
struct TranscriptPostProcessor: Sendable {
    static let maxCorrections = 128
    static let maxEnabledCorrections = 128
    static let maxCorrectionCharacters = 128

    private let commandMatcher: CompiledMatcher
    private let correctionMatcher: CompiledMatcher
    /// Optional deterministic term rescue that runs before commands and
    /// exact corrections; nil keeps the pipeline byte-identical to before.
    private let phoneticCorrector: PhoneticCorrector?

    init() {
        self.commandMatcher = CompiledMatcher(rules: Self.commandRules)
        self.correctionMatcher = CompiledMatcher(rules: [])
        self.phoneticCorrector = nil
    }

    init(corrections: [TranscriptCorrection]) throws {
        try self.init(corrections: corrections, phoneticTerms: [])
    }

    init(corrections: [TranscriptCorrection], phoneticTerms: [PhoneticTerm]) throws {
        guard corrections.count <= Self.maxCorrections else {
            throw TranscriptPostProcessorError.tooManyCorrections(corrections.count)
        }

        let enabledCount = corrections.reduce(into: 0) { count, correction in
            if correction.isEnabled {
                count += 1
            }
        }
        guard enabledCount <= Self.maxEnabledCorrections else {
            throw TranscriptPostProcessorError.tooManyEnabledCorrections(enabledCount)
        }

        var seen: [String: Int] = [:]
        var rules: [CompiledRule] = []
        rules.reserveCapacity(enabledCount)

        for (index, correction) in corrections.enumerated() {
            let heardCount = correction.heard.count
            let writtenCount = correction.written.count
            guard heardCount > 0 else {
                throw TranscriptPostProcessorError.heardIsEmpty(index: index)
            }
            guard heardCount <= Self.maxCorrectionCharacters else {
                throw TranscriptPostProcessorError.heardIsTooLong(index: index, count: heardCount)
            }
            guard writtenCount <= Self.maxCorrectionCharacters else {
                throw TranscriptPostProcessorError.writtenIsTooLong(index: index, count: writtenCount)
            }

            let tokens = Self.tokens(in: correction.heard)
            guard !tokens.isEmpty else {
                throw TranscriptPostProcessorError.heardIsEmpty(index: index)
            }
            let key = Self.ruleKey(tokens)
            if let previousIndex = seen[key] {
                throw TranscriptPostProcessorError.duplicateHeard(
                    index: index,
                    duplicateOf: previousIndex
                )
            }
            seen[key] = index

            guard correction.isEnabled else { continue }
            rules.append(
                CompiledRule(
                    tokens: tokens.map(\.normalized),
                    replacement: correction.written,
                    style: nil,
                    order: index
                )
            )
        }

        self.commandMatcher = CompiledMatcher(rules: Self.commandRules)
        self.correctionMatcher = CompiledMatcher(rules: rules)
        self.phoneticCorrector = try PhoneticCorrector(terms: phoneticTerms)
    }

    func process(_ rawText: String) -> ProcessedTranscript {
        // Phonetic rescue runs on the raw transcript so misheard domain
        // terms become canonical words before command and exact matching.
        let phoneticText = phoneticCorrector?.correct(rawText) ?? rawText
        let commandText = rewriteCommands(in: phoneticText)
        let finalText = correctionMatcher.rewrite(in: commandText)
        return ProcessedTranscript(rawText: rawText, finalText: finalText)
    }

    private func rewriteCommands(in text: String) -> String {
        let pieces = commandMatcher.rewritePieces(in: text)
        var output = ""
        var trimLeadingWhitespace = false

        for piece in pieces {
            switch piece {
            case .text(let value):
                if trimLeadingWhitespace {
                    output += String(value.drop(while: { $0.isWhitespace }))
                    trimLeadingWhitespace = false
                } else {
                    output += value
                }
            case .command(let rule):
                switch rule.style ?? .punctuation {
                case .lineBreak:
                    Self.removeTrailingWhitespace(from: &output)
                    output += rule.replacement
                    trimLeadingWhitespace = true
                case .openingBracket:
                    Self.removeTrailingInlineWhitespace(from: &output)
                    output += rule.replacement
                    trimLeadingWhitespace = true
                case .closingBracket, .punctuation, .glue:
                    Self.removeTrailingInlineWhitespace(from: &output)
                    output += rule.replacement
                    trimLeadingWhitespace = rule.style == .glue
                }
            }
        }

        return output
    }

    private static let commandRules: [CompiledRule] = [
        command("new paragraph", replacement: "\n\n", style: .lineBreak),
        command("new line", replacement: "\n", style: .lineBreak),
        command("question mark", replacement: "?", style: .punctuation),
        command("exclamation point", replacement: "!", style: .punctuation),
        command("dot dot dot", replacement: "…", style: .punctuation),
        command("left parenthesis", replacement: "(", style: .openingBracket),
        command("right parenthesis", replacement: ")", style: .closingBracket),
        command("left bracket", replacement: "[", style: .openingBracket),
        command("right bracket", replacement: "]", style: .closingBracket),
        command("left brace", replacement: "{", style: .openingBracket),
        command("right brace", replacement: "}", style: .closingBracket),
        command("backslash", replacement: "\\", style: .glue),
        command("underscore", replacement: "_", style: .glue),
        command("slash", replacement: "/", style: .glue),
        command("comma", replacement: ",", style: .punctuation),
        command("colon", replacement: ":", style: .punctuation),
        command("semicolon", replacement: ";", style: .punctuation),
        command("plus sign", replacement: "+", style: .punctuation),
        command("minus sign", replacement: "-", style: .punctuation),
        command("equals sign", replacement: "=", style: .punctuation),
        command("percent sign", replacement: "%", style: .punctuation),
        command("ampersand", replacement: "&", style: .punctuation),
        command("asterisk", replacement: "*", style: .punctuation),
        command("at sign", replacement: "@", style: .punctuation),
        command("number sign", replacement: "#", style: .punctuation),
        command("hash sign", replacement: "#", style: .punctuation),
        command("dollar sign", replacement: "$", style: .punctuation),
    ]

    private static func command(
        _ heard: String,
        replacement: String,
        style: CommandStyle
    ) -> CompiledRule {
        CompiledRule(
            tokens: tokens(in: heard).map(\.normalized),
            replacement: replacement,
            style: style,
            order: 0
        )
    }

    private static func ruleKey(_ tokens: [Token]) -> String {
        tokens.map(\.normalized).joined(separator: "\u{1F}")
    }

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var wordStart: String.Index?
        var index = text.startIndex

        func flushWord(endingAt end: String.Index) {
            guard let wordStart else { return }
            let value = String(text[wordStart..<end])
            tokens.append(Token(
                normalized: normalize(value),
                range: wordStart..<end
            ))
        }

        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isWhitespace {
                flushWord(endingAt: index)
                wordStart = nil
            } else if character.isLetter || character.isNumber {
                if wordStart == nil {
                    wordStart = index
                }
            } else {
                flushWord(endingAt: index)
                wordStart = nil
                tokens.append(Token(
                    normalized: normalize(String(character)),
                    range: index..<next
                ))
            }
            index = next
        }
        flushWord(endingAt: text.endIndex)
        return tokens
    }

    static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCompatibilityMapping
    }

    private static func removeTrailingWhitespace(from value: inout String) {
        value = String(value.reversed().drop(while: { $0.isWhitespace }).reversed())
    }

    private static func removeTrailingInlineWhitespace(from value: inout String) {
        value = String(
            value.reversed()
                .drop(while: { $0.isWhitespace && $0 != "\n" && $0 != "\r" })
                .reversed()
        )
    }

    struct Token: Sendable {
        let normalized: String
        let range: Range<String.Index>

        var hasLetterOrNumber: Bool {
            !normalized.isEmpty && normalized.contains(where: { $0.isLetter || $0.isNumber })
        }
    }

    private enum CommandStyle: Sendable, Equatable {
        case lineBreak
        case openingBracket
        case closingBracket
        case punctuation
        case glue
    }

    private struct CompiledRule: Sendable {
        let tokens: [String]
        let replacement: String
        let style: CommandStyle?
        let order: Int
    }

    private enum Piece {
        case text(String)
        case command(CompiledRule)
    }

    private struct Match {
        let rule: CompiledRule
        let tokenCount: Int
        let range: Range<String.Index>
    }

    private struct CompiledMatcher: Sendable {
        private let rulesByFirstToken: [String: [CompiledRule]]

        init(rules: [CompiledRule]) {
            var indexed: [String: [CompiledRule]] = [:]
            for rule in rules where !rule.tokens.isEmpty {
                indexed[rule.tokens[0], default: []].append(rule)
            }
            self.rulesByFirstToken = indexed
        }

        func rewrite(in text: String) -> String {
            guard !rulesByFirstToken.isEmpty else { return text }
            return rewritePieces(in: text).reduce(into: "") { output, piece in
                if case .text(let value) = piece {
                    output += value
                } else if case .command(let rule) = piece {
                    output += rule.replacement
                }
            }
        }

        func rewritePieces(in text: String) -> [Piece] {
            guard !rulesByFirstToken.isEmpty else { return [.text(text)] }
            let inputTokens = TranscriptPostProcessor.tokens(in: text)
            guard !inputTokens.isEmpty else { return [.text(text)] }

            var pieces: [Piece] = []
            pieces.reserveCapacity(inputTokens.count + 1)
            var cursor = text.startIndex
            var tokenIndex = 0

            while tokenIndex < inputTokens.count {
                guard let match = longestMatch(in: text, tokens: inputTokens, at: tokenIndex) else {
                    tokenIndex += 1
                    continue
                }

                if cursor < match.range.lowerBound {
                    pieces.append(.text(String(text[cursor..<match.range.lowerBound])))
                }
                if match.rule.style == nil {
                    pieces.append(.text(match.rule.replacement))
                } else {
                    pieces.append(.command(match.rule))
                }
                cursor = match.range.upperBound
                tokenIndex += match.tokenCount
            }

            if cursor < text.endIndex {
                pieces.append(.text(String(text[cursor..<text.endIndex])))
            }
            return pieces
        }

        private func longestMatch(
            in text: String,
            tokens: [Token],
            at index: Int
        ) -> Match? {
            guard let candidates = rulesByFirstToken[tokens[index].normalized] else {
                return nil
            }

            var best: Match?
            for rule in candidates {
                let count = rule.tokens.count
                guard index + count <= tokens.count else { continue }
                var matches = true
                if count > 1 {
                    for offset in 1..<count {
                        guard
                            tokens[index + offset].normalized == rule.tokens[offset],
                            gapIsWhitespace(
                                in: text,
                                between: tokens[index + offset - 1].range.upperBound,
                                and: tokens[index + offset].range.lowerBound
                            )
                        else {
                            matches = false
                            break
                        }
                    }
                }
                guard matches else { continue }

                let match = Match(
                    rule: rule,
                    tokenCount: count,
                    range: tokens[index].range.lowerBound..<tokens[index + count - 1].range.upperBound
                )
                if let currentBest = best {
                    if match.tokenCount > currentBest.tokenCount
                        || (match.tokenCount == currentBest.tokenCount && match.rule.order < currentBest.rule.order) {
                        best = match
                    }
                } else {
                    best = match
                }
            }
            return best
        }

        private func gapIsWhitespace(
            in text: String,
            between start: String.Index,
            and end: String.Index
        ) -> Bool {
            text[start..<end].allSatisfy(\.isWhitespace)
        }
    }
}
