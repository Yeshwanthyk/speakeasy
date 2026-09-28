import Foundation
import XCTest
@testable import Speakeasy

/// Generated-input invariants for the text pipeline. See
/// `Support/PropertyTesting.swift` for seeds and iteration counts.
final class TextPipelinePropertyTests: XCTestCase {
    // MARK: - Generators

    /// Characters that stress tokenization and normalization.
    private static let trickyAlphabet: [Character] = Array("abcXYZ019 \n\t.,-_/'?!()") + [
        "é", "e\u{301}", "ß", "ﬁ", "™", "Ａ", "…", "\u{200B}", "\u{301}", "\r\n",
        "👩\u{200D}💻", "🇺🇸", "Ω", "١",
    ]

    /// Words that are neither spoken commands nor common English words.
    private static let safeWords = [
        "zorp", "quix", "blen", "frab", "glim", "tronk", "vesp", "wump", "kudo",
        "cuda", "llm", "vllm", "pytorch", "kubernetes", "grafana", "zed", "yak",
    ]

    private static let commandWords: Set<String> = [
        "new", "line", "paragraph", "question", "mark", "exclamation", "point", "dot",
        "left", "right", "parenthesis", "bracket", "brace", "backslash", "underscore",
        "slash", "comma", "colon", "semicolon", "plus", "minus", "equals", "percent",
        "ampersand", "asterisk", "at", "number", "hash", "dollar", "sign",
    ]

    private static let trickyText = Gen.string(from: trickyAlphabet, length: 0...40)

    private static let safeText = Gen.text(
        words: .element(of: safeWords),
        separators: [" ", "  ", ", ", ". ", "\n", "-"],
        count: 0...12
    )

    private static let safePhrase = Gen<[String]>.array(of: .element(of: safeWords), count: 1...3)
        .map { $0.joined(separator: " ") }

    /// Rule sets whose heard phrases are unique after normalization, so
    /// they always compile.
    private static let validCorrections = Gen<[TranscriptCorrection]>.array(
        of: genZip(genZip(safePhrase, safeText), .element(of: [true, true, false]))
            .map { TranscriptCorrection(heard: $0.0.0, written: String($0.0.1.prefix(64)), isEnabled: $0.1) },
        count: 0...10
    ).map { corrections in
        var seen: Set<String> = []
        return corrections.filter { seen.insert($0.heard).inserted }
    }

    // MARK: - Tokenizer and normalization

    func testTokensPartitionTextIntoNonWhitespaceRuns() {
        forAll(Self.trickyText) { text in
            var cursor = text.startIndex
            for token in TranscriptPostProcessor.tokens(in: text) {
                guard cursor <= token.range.lowerBound,
                      !token.range.isEmpty,
                      text[cursor..<token.range.lowerBound].allSatisfy(\.isWhitespace),
                      !text[token.range].contains(where: \.isWhitespace)
                else { return false }
                cursor = token.range.upperBound
            }
            return text[cursor...].allSatisfy(\.isWhitespace)
        }
    }

    // MARK: - Post-processor

    func testTextWithoutCommandsOrRulesIsUnchanged() throws {
        let processor = try TranscriptPostProcessor(corrections: [])
        forAll(Self.safeText) { text in
            processor.process(text) == ProcessedTranscript(rawText: text, finalText: text)
        }
    }

    func testEnabledRuleRewritesItsOwnHeardPhraseExactlyOnce() {
        forAll(Self.validCorrections) { corrections in
            guard let processor = try? TranscriptPostProcessor(corrections: corrections) else {
                return false
            }
            return corrections.filter(\.isEnabled).allSatisfy { correction in
                processor.process(correction.heard).finalText == correction.written
            }
        }
    }

    func testDisabledRulesHaveNoEffect() {
        let baseline = TranscriptPostProcessor()
        let input = genZip(Self.validCorrections, Self.trickyText)
        forAll(input) { corrections, text in
            let disabled = corrections.map {
                TranscriptCorrection(id: $0.id, heard: $0.heard, written: $0.written, isEnabled: false)
            }
            guard let processor = try? TranscriptPostProcessor(corrections: disabled) else { return false }
            return processor.process(text).finalText == baseline.process(text).finalText
        }
    }

    func testOutputIsBoundedAndUnchangedTextReportsNoStages() {
        let input = genZip(Self.validCorrections, Self.trickyText)
        forAll(input) { corrections, text in
            guard let processor = try? TranscriptPostProcessor(corrections: corrections) else { return false }
            let result = processor.process(text)
            let bounded = result.finalText.count
                <= text.count * TranscriptPostProcessor.maxCorrectionCharacters
            return bounded && (!result.stageChanges.isEmpty || result.finalText == text)
        }
    }

    func testCommandsNeverAddLettersOrDigits() {
        let processor = TranscriptPostProcessor()
        let words = Array(Self.commandWords) + Self.safeWords
        let text = Gen.text(words: .element(of: words), separators: [" ", ", ", "\n"], count: 0...16)
        forAll(text) { text in
            func alphanumericCount(_ value: String) -> Int {
                value.filter { $0.isLetter || $0.isNumber }.count
            }
            return alphanumericCount(processor.process(text).finalText) <= alphanumericCount(text)
        }
    }

    func testValidCorrectionsAlwaysCompileWithTheirFuzzyTerms() {
        let withDeletions = genZip(Self.validCorrections, .element(of: ["", " ", "\n", "x"]))
            .map { corrections, written in
                corrections.enumerated().map { index, correction in
                    index.isMultiple(of: 2)
                        ? correction
                        : TranscriptCorrection(heard: correction.heard, written: written)
                }
            }
        forAll(withDeletions) { corrections in
            guard (try? TranscriptPostProcessor(corrections: corrections)) != nil else { return true }
            return (try? TranscriptPostProcessor(
                corrections: corrections,
                phoneticTerms: TranscriptPostProcessor.phoneticTerms(for: corrections)
            )) != nil
        }
    }

    // MARK: - Phonetic corrector

    func testCommonSpeechIsNeverRewritten() throws {
        let common = Array(PhoneticCorrector.commonWords).sorted()
        let terms = Gen<[String]>.array(of: .element(of: Self.safeWords + common), count: 1...6)
        let text = Gen.text(words: .element(of: common), separators: [" ", ", ", ". "], count: 0...16)
        forAll(genZip(terms, text)) { spokenForms, text in
            var seen: Set<String> = []
            let phoneticTerms = spokenForms.filter { seen.insert($0).inserted }.map {
                PhoneticTerm(canonical: $0.uppercased() + "X", spokenForms: [$0])
            }
            guard let corrector = try? PhoneticCorrector(terms: phoneticTerms) else { return false }
            return corrector.correct(text) == text
        }
    }

    func testEmptyTermSetIsIdentity() throws {
        let corrector = try PhoneticCorrector(terms: [])
        forAll(Self.trickyText) { corrector.correct($0) == $0 }
    }

    func testPhoneticSkeletonIsVowelFreeAndCollapsed() {
        forAll(Self.trickyText) { word in
            let skeleton = PhoneticCorrector.phoneticSkeleton(word)
            let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
            return !skeleton.contains(where: vowels.contains)
                && zip(skeleton, skeleton.dropFirst()).allSatisfy { $0 != $1 }
        }
    }

    func testCappedLevenshteinAgreesWithExactDistance() {
        let word = Gen.string(from: Array("abcdk"), length: 0...9)
        let input = genZip(genZip(word, word), .int(in: 0...4))
        forAll(input) { pair, limit in
            let (left, right) = pair
            let exact = PhoneticCorrector.levenshtein(left, right, limit: 64)
            let capped = PhoneticCorrector.levenshtein(left, right, limit: limit)
            return exact == PhoneticCorrector.levenshtein(right, left, limit: 64)
                && (left != right || exact == 0)
                && exact <= max(left.count, right.count)
                && capped == (exact <= limit ? exact : limit + 1)
        }
    }

    // MARK: - Hallucination filter

    private static let duration = Gen<Double?>.frequency([
        (1, .constant(nil)),
        (6, Gen.int(in: 0...20_000).map { Double($0) / 1_000 }),
        (1, .element(of: [0, 1.5, 1e300, .greatestFiniteMagnitude, .infinity, .nan, -1])),
    ])

    private static let rms = Gen<Float?>.frequency([
        (1, .constant(nil)),
        (6, Gen.int(in: 0...100).map { Float($0) / 10_000 }),
        (1, .element(of: [0, .infinity, .nan, -1])),
    ])

    private static let filterText = Gen.frequency([
        (3, trickyText),
        (2, .text(
            words: .element(of: ["yeah", "one", "two", "three", "thanks", "for", "watching", "okay"]),
            separators: [" ", ". ", "! "],
            count: 0...40
        )),
    ])

    func testSurroundingWhitespaceNeverChangesTheVerdict() {
        let filter = HallucinationFilter()
        forAll(genZip(Self.filterText, genZip(Self.duration, Self.rms))) { text, audio in
            filter.verdict(for: text, activeDurationSeconds: audio.0, activeRMS: audio.1)
                == filter.verdict(for: "\n \(text) \t", activeDurationSeconds: audio.0, activeRMS: audio.1)
        }
    }

    func testMoreAudioNeverTurnsAnAcceptedTranscriptIntoARejection() {
        let filter = HallucinationFilter()
        let input = genZip(Self.filterText, genZip(Self.duration, Self.rms))
        forAll(input) { text, audio in
            let (duration, rms) = audio
            guard filter.verdict(for: text, activeDurationSeconds: duration, activeRMS: rms) == .accepted else {
                return true
            }
            let longer = duration.map { $0 * 2 + 1 }
            let louder = rms.map { $0 * 2 + 0.01 }
            return filter.verdict(for: text, activeDurationSeconds: longer, activeRMS: rms) == .accepted
                && filter.verdict(for: text, activeDurationSeconds: duration, activeRMS: louder) == .accepted
        }
    }

    func testDistinctWordsWithoutAudioEvidenceAreAccepted() {
        let filter = HallucinationFilter()
        let words = Gen<[Int]>.array(of: .int(in: 0...10_000), count: 0...60).map { numbers in
            var seen: Set<Int> = []
            return numbers.filter { seen.insert($0).inserted }.map { "w\($0)" }.joined(separator: " ")
        }
        forAll(words) { filter.verdict(for: $0) == .accepted }
    }
}
