import Foundation
import XCTest
@testable import Speakeasy

/// Fuzz targets for the text pipeline. See `Support/Fuzzing.swift` for the
/// harness and `Fuzz/Corpus/` for the seed inputs.
final class TextPipelineFuzzTests: XCTestCase {
    /// Untrusted `corrections.json` bytes: decoding never traps, and anything
    /// it accepts compiles (with and without fuzzy terms) and round-trips.
    func testFuzzCorrectionsDocument() {
        fuzz("corrections-json", dictionary: [
            "\"schemaVersion\":", "\"corrections\":", "\"heard\":", "\"written\":",
            "\"isEnabled\":", "\"id\":", "\"0F1D2C3B-4A59-6877-8695-A4B3C2D1E0F9\"",
            "true", "false", "null", "1", "2", "-1", "1e999", "[]", "{}", ",",
            "\\u0000", "\\ud800", "\\n", "\"\"",
        ]) { data in
            let corrections: [TranscriptCorrection]
            do {
                corrections = try TranscriptCorrectionDocument.validatedCorrections(from: data)
            } catch is TranscriptCorrectionDocumentError {
                return
            }

            let processor = try TranscriptPostProcessor(
                corrections: corrections,
                phoneticTerms: TranscriptPostProcessor.phoneticTerms(for: corrections)
            )
            for correction in corrections.prefix(8) {
                _ = processor.process(correction.heard)
            }

            let encoded = try JSONEncoder().encode(TranscriptCorrectionDocument(corrections: corrections))
            let decoded = try TranscriptCorrectionDocument.validatedCorrections(from: encoded)
            try fuzzCheck(decoded == corrections, "round-trip changed corrections")
        }
    }

    /// Rules plus a transcript (see `PostProcessorFuzzInput`): compiling and
    /// processing never trap, and the output obeys the pipeline's bounds.
    func testFuzzPostProcessor() {
        fuzz("post-processor", dictionary: [
            "\n---\n", "=>", "\n~", "\n!", " new line ", " new paragraph ", " comma ",
            " question mark ", " left parenthesis ", " right brace ", " underscore ",
            " slash ", "e\u{301}", "\u{301}", "ß", "ﬁ", "™", "Ａ", "…", "\u{200B}",
            "👩\u{200D}💻", "🇺🇸", "\r\n", "\t", "kudo", "v llm", "kubernetes",
        ]) { data in
            let input = PostProcessorFuzzInput(data)
            try checkTokenInvariants(input.transcript)

            if let phonetic = try? PhoneticCorrector(terms: input.phoneticTerms) {
                _ = phonetic.correct(input.transcript)
            }

            guard let processor = try? TranscriptPostProcessor(
                corrections: input.corrections,
                phoneticTerms: input.phoneticTerms
            ) else { return }
            let result = processor.process(input.transcript)
            try fuzzCheck(result.rawText == input.transcript, "rawText changed")
            if result.stageChanges.isEmpty {
                try fuzzCheck(result.finalText == input.transcript, "text changed without a stage change")
            }
            let limit = TranscriptPostProcessor.maxCorrectionCharacters
            let bound = input.transcript.count * (input.phoneticTerms.isEmpty ? limit : limit * limit)
            try fuzzCheck(result.finalText.count <= bound, "output exceeded \(bound) characters")

            // Valid exact corrections always compile with their fuzzy terms.
            if (try? TranscriptPostProcessor(corrections: input.corrections)) != nil {
                do {
                    _ = try TranscriptPostProcessor(
                        corrections: input.corrections,
                        phoneticTerms: TranscriptPostProcessor.phoneticTerms(for: input.corrections)
                    )
                } catch {
                    throw FuzzFailure("derived phonetic terms rejected: \(error)")
                }
            }
        }
    }

    /// `duration rms` header line plus transcript text: verdicts never trap
    /// and ignore surrounding whitespace.
    func testFuzzHallucinationFilter() {
        fuzz("hallucination-filter", dictionary: [
            "\n", " ", "nan", "inf", "-inf", "1e308", "1e-300", "-0", "0.002", "1.5", "-",
            "thanks for watching", "yeah.", "one two three ", ". ", "!", "?",
        ]) { data in
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let header = lines.first.map { $0.split(separator: " ") } ?? []
            let duration = header.first.flatMap { TimeInterval(String($0)) }
            let rms = header.dropFirst().first.flatMap { Float(String($0)) }
            let transcript = lines.count > 1 ? String(lines[1]) : ""

            let filter = HallucinationFilter()
            let verdict = filter.verdict(for: transcript, activeDurationSeconds: duration, activeRMS: rms)
            let padded = filter.verdict(
                for: " \n\(transcript)\t ",
                activeDurationSeconds: duration,
                activeRMS: rms
            )
            try fuzzCheck(verdict == padded, "surrounding whitespace changed the verdict")
        }
    }

    private func checkTokenInvariants(_ text: String) throws {
        var previousUpper = text.startIndex
        for token in TranscriptPostProcessor.tokens(in: text) {
            try fuzzCheck(previousUpper <= token.range.lowerBound, "tokens overlap or go backwards")
            try fuzzCheck(token.range.lowerBound < token.range.upperBound, "empty token range")
            try fuzzCheck(
                text[previousUpper..<token.range.lowerBound].allSatisfy(\.isWhitespace),
                "non-whitespace text between tokens"
            )
            try fuzzCheck(!text[token.range].contains(where: \.isWhitespace), "token contains whitespace")
            previousUpper = token.range.upperBound
        }
        try fuzzCheck(text[previousUpper...].allSatisfy(\.isWhitespace), "non-whitespace text after tokens")
    }
}

/// Human-readable fuzz input for the post-processor:
///
///     heard=>written        exact correction (prefix `!` to disable)
///     ~spoken=>Canonical    phonetic term
///     ---
///     transcript text…
///
/// Without a `---` line, the whole input is the transcript.
struct PostProcessorFuzzInput {
    var corrections: [TranscriptCorrection] = []
    var phoneticTerms: [PhoneticTerm] = []
    var transcript: String

    init(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard let separator = text.range(of: "\n---\n") else {
            transcript = text
            return
        }
        transcript = String(text[separator.upperBound...])
        for line in text[..<separator.lowerBound].split(separator: "\n") {
            guard let arrow = line.range(of: "=>") else { continue }
            var heard = line[..<arrow.lowerBound]
            let written = String(line[arrow.upperBound...])
            if heard.hasPrefix("~") {
                heard.removeFirst()
                phoneticTerms.append(PhoneticTerm(canonical: written, spokenForms: [String(heard)]))
            } else if heard.hasPrefix("!") {
                heard.removeFirst()
                corrections.append(TranscriptCorrection(heard: String(heard), written: written, isEnabled: false))
            } else {
                corrections.append(TranscriptCorrection(heard: String(heard), written: written))
            }
        }
    }
}
