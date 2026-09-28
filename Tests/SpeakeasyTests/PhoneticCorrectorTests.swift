import Foundation
import XCTest
@testable import Speakeasy

final class PhoneticCorrectorTests: XCTestCase {
    private func corrector(
        _ pairs: (canonical: String, forms: [String])...
    ) throws -> PhoneticCorrector {
        try PhoneticCorrector(
            terms: pairs.map { PhoneticTerm(canonical: $0.canonical, spokenForms: $0.forms) }
        )
    }

    // MARK: - Multi-word skeleton matching

    func testMultiWordSkeletonRewritesSpokenWindow() throws {
        let corrector = try corrector(("vLLM", ["v llm"]))
        XCTAssertEqual(corrector.correct("we deployed v llm today"), "we deployed vLLM today")
    }

    func testSkeletonMatchIgnoresVowelsAndCCollapse() throws {
        let corrector = try corrector(("CUDA", ["kudo"]))
        XCTAssertEqual(corrector.correct("the kudo kernel"), "the CUDA kernel")
        XCTAssertEqual(corrector.correct("the coda kernel"), "the CUDA kernel")
    }

    func testPunctuationAndSpacingAroundMatchArePreserved() throws {
        let corrector = try corrector(("cuDNN", ["koo dnn"]))
        XCTAssertEqual(corrector.correct("use koo dnn, then stop"), "use cuDNN, then stop")
        XCTAssertEqual(corrector.correct("(koo dnn)"), "(cuDNN)")
    }

    // MARK: - Single-word tiers

    func testEditDistanceRescuesNearMissOnLongWord() throws {
        let corrector = try corrector(("Kubernetes", ["kubernetes"]))
        XCTAssertEqual(corrector.correct("deploy to kuberntees now"), "deploy to Kubernetes now")
    }

    func testEditDistanceRequiresSameFirstLetter() throws {
        let corrector = try corrector(("Kubernetes", ["kubernetes"]))
        XCTAssertEqual(corrector.correct("deploy to tubernetes now"), "deploy to tubernetes now")
    }

    func testEditDistanceSkipsShortWords() throws {
        // Four characters: below the five-character edit-distance floor, so
        // "coda" only matches through the skeleton tier.
        let corrector = try corrector(("CUDA", ["cuda"]))
        XCTAssertEqual(corrector.correct("play the coda"), "play the CUDA")
    }

    // MARK: - Negative guards

    func testAmbiguousSkeletonDropsBothTerms() throws {
        // "kudo" and "kado" share skeleton "kd"; neither may win.
        let corrector = try corrector(("CUDA", ["kudo"]), ("RADOS", ["kado"]))
        XCTAssertEqual(corrector.correct("the kudo kernel"), "the kudo kernel")
        XCTAssertEqual(corrector.correct("the kado cluster"), "the kado cluster")
    }

    func testOverlappingMatchesResolveLeftmostLongestFirst() throws {
        let corrector = try corrector(("vLLM", ["v llm"]), ("LLM", ["llm"]))
        XCTAssertEqual(corrector.correct("run v llm please"), "run vLLM please")
    }

    func testUnrelatedTextIsUntouched() throws {
        let corrector = try corrector(("CUDA", ["kudo"]), ("vLLM", ["v llm"]))
        let text = "the quick brown fox jumped over the lazy dog"
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testAlreadyCanonicalTextIsNotTouchedByEditDistanceTier() throws {
        // "CUDA" normalizes to "cuda"; exact equality is not a candidate,
        // and no taught form is within edit-distance of it.
        let corrector = try corrector(("CUDA", ["kuda"]))
        XCTAssertEqual(corrector.correct("ship CUDA fast"), "ship CUDA fast")
    }

    func testCaseOfSurroundingTextIsPreserved() throws {
        let corrector = try corrector(("PyTorch", ["pie torch"]))
        XCTAssertEqual(corrector.correct("PIE TORCH rocks"), "PyTorch rocks")
    }

    func testCommonNearMissesAndShortWordsAreNeverSubstituted() throws {
        let corrector = try corrector(("CUDA", ["coda"]), ("Kubernetes", ["kubernets"]))
        XCTAssertEqual(corrector.correct("I could code today and come home"), "I could code today and come home")
        XCTAssertEqual(corrector.correct("the sun is hot"), "the sun is hot")
        XCTAssertEqual(corrector.correct("coda cubernets"), "CUDA cubernets")
        XCTAssertEqual(corrector.correct("CODA, coda!"), "CUDA, CUDA!")
    }

    func testEmptyTermsReturnTextUnchanged() {
        let corrector = try! PhoneticCorrector(terms: [])
        let text = "nothing to do here"
        XCTAssertEqual(corrector.correct(text), text)
    }

    // MARK: - Validation errors

    func testTooManyTermsThrows() {
        let terms = (0..<PhoneticCorrector.maxTerms + 1).map { index in
            PhoneticTerm(canonical: "Term\(index)", spokenForms: ["term \(index)"])
        }
        XCTAssertThrowsError(
            try PhoneticCorrector(terms: terms),
            "expected tooManyTerms"
        ) { error in
            XCTAssertEqual(
                error as? PhoneticCorrectorError,
                .tooManyTerms(PhoneticCorrector.maxTerms + 1)
            )
        }
    }

    func testEmptyCanonicalThrows() {
        XCTAssertThrowsError(
            try PhoneticCorrector(terms: [PhoneticTerm(canonical: "  ", spokenForms: ["kudo"])])
        ) { error in
            XCTAssertEqual(error as? PhoneticCorrectorError, .canonicalIsEmpty(index: 0))
        }
    }

    func testOversizedCanonicalThrows() {
        let canonical = String(repeating: "x", count: PhoneticCorrector.maxCanonicalCharacters + 1)
        XCTAssertThrowsError(
            try PhoneticCorrector(terms: [PhoneticTerm(canonical: canonical, spokenForms: ["kudo"])])
        ) { error in
            XCTAssertEqual(
                error as? PhoneticCorrectorError,
                .canonicalIsTooLong(index: 0, count: canonical.count)
            )
        }
    }

    func testBlankSpokenFormThrows() {
        XCTAssertThrowsError(
            try PhoneticCorrector(terms: [PhoneticTerm(canonical: "CUDA", spokenForms: ["   "])])
        ) { error in
            XCTAssertEqual(error as? PhoneticCorrectorError, .spokenFormIsEmpty(index: 0, formIndex: 0))
        }
    }

    func testDuplicateSpokenFormAcrossTermsThrows() throws {
        XCTAssertThrowsError(
            try corrector(("CUDA", ["kudo"]), ("CODA", ["kudo"]))
        ) { error in
            XCTAssertEqual(error as? PhoneticCorrectorError, .duplicateSpokenForm(index: 1, duplicateOf: 0))
        }
    }

    // MARK: - Static helpers

    func testPhoneticSkeletonCollapsesWithinWordOnly() {
        XCTAssertEqual(PhoneticCorrector.phoneticSkeleton("kudo"), "kd")
        XCTAssertEqual(PhoneticCorrector.phoneticSkeleton("CUDA"), "kd")
        XCTAssertEqual(PhoneticCorrector.phoneticSkeleton("circumstance"), "krkmstnk")
        // Doubled letters collapse inside a word…
        XCTAssertEqual(PhoneticCorrector.phoneticSkeleton("llm"), "lm")
        // …but each word collapses independently.
        XCTAssertEqual(PhoneticCorrector.phoneticSkeleton("gpt-5"), "gpt5")
    }

    func testLevenshteinCappingExitsEarly() {
        XCTAssertEqual(PhoneticCorrector.levenshtein("kubernetes", "kubernets", limit: 1), 1)
        // Transpositions cost two plain Levenshtein edits.
        XCTAssertEqual(PhoneticCorrector.levenshtein("kubernetes", "kuberntees", limit: 2), 2)
        XCTAssertEqual(PhoneticCorrector.levenshtein("aaaaaa", "bbbbbb", limit: 1), 2)
        XCTAssertEqual(PhoneticCorrector.levenshtein("same", "same", limit: 2), 0)
    }
}

// MARK: - TranscriptPostProcessor integration

final class PhoneticPostProcessorIntegrationTests: XCTestCase {
    func testPhoneticPassRunsBeforeCommandsAndExactCorrections() throws {
        let processor = try TranscriptPostProcessor(
            corrections: [
                TranscriptCorrection(heard: "ship CUDA fast now", written: "release the CUDA build immediately"),
            ],
            phoneticTerms: [PhoneticTerm(canonical: "CUDA", spokenForms: ["kudo"])]
        )
        let result = processor.process("kudo build is green new line ship kudo fast now")
        XCTAssertEqual(
            result.finalText,
            "CUDA build is green\nrelease the CUDA build immediately"
        )
        XCTAssertEqual(result.rawText, "kudo build is green new line ship kudo fast now")
    }

    func testProcessorWithoutPhoneticTermsBehavesAsBefore() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "hello wisp", written: "Hello, Wisp"),
        ])
        XCTAssertEqual(processor.process("hello wisp").finalText, "Hello, Wisp")
    }

    func testDeletionRulesStillCompileWhenFuzzyMatchingIsOn() throws {
        // Regression: a blank replacement became a blank phonetic canonical,
        // which threw and made startup drop every correction.
        let corrections = [
            TranscriptCorrection(heard: "um", written: ""),
            TranscriptCorrection(heard: "uh", written: "  "),
            TranscriptCorrection(heard: "kudo", written: "CUDA"),
            TranscriptCorrection(heard: "same", written: "same"),
            TranscriptCorrection(heard: "off", written: "OFF", isEnabled: false),
        ]
        let terms = TranscriptPostProcessor.phoneticTerms(for: corrections)
        XCTAssertEqual(terms, [PhoneticTerm(canonical: "CUDA", spokenForms: ["kudo"])])

        let processor = try TranscriptPostProcessor(corrections: corrections, phoneticTerms: terms)
        XCTAssertEqual(processor.process("um the coda").finalText, " the CUDA")
    }

    func testWordsAtLineBreaksOfTheCommonListAreProtected() throws {
        // Regression: splitting on spaces only fused "your\nable".
        XCTAssertTrue(PhoneticCorrector.commonWords.isSuperset(of: ["your", "able", "yesterday", "a"]))
        XCTAssertFalse(PhoneticCorrector.commonWords.contains(where: { $0.contains(where: \.isWhitespace) }))
        let orCorrector = try PhoneticCorrector(terms: [PhoneticTerm(canonical: "OR", spokenForms: ["or"])])
        XCTAssertEqual(orCorrector.correct("your able"), "your able")
    }
}

