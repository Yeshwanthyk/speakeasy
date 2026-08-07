import XCTest
@testable import Speakeasy

final class HallucinationFilterTests: XCTestCase {
    func testDefaultPatternsFilterKnownShortResponses() {
        let filter = HallucinationFilter()

        XCTAssertTrue(filter.isLikelyHallucination("yeah"))
        XCTAssertTrue(filter.isLikelyHallucination("okay."))
        XCTAssertTrue(filter.isLikelyHallucination("uh-huh"))
    }

    func testFilterNormalizesWhitespaceAndCase() {
        let filter = HallucinationFilter()

        XCTAssertTrue(filter.isLikelyHallucination("  Yeah. \n"))
    }

    func testRealPhraseIsNotFiltered() {
        let filter = HallucinationFilter()

        XCTAssertFalse(filter.isLikelyHallucination("Yeah, that sounds good."))
    }

    func testCustomPatternsCanBeInjected() {
        let filter = HallucinationFilter(patterns: ["custom"])

        XCTAssertTrue(filter.isLikelyHallucination("custom"))
        XCTAssertFalse(filter.isLikelyHallucination("yeah"))
    }

    func testVerdictReturnsTypedReasonWithoutTranscriptContent() {
        let filter = HallucinationFilter()

        XCTAssertEqual(
            filter.verdict(for: "  YÉAH. "),
            .rejected(.exactPattern)
        )
        XCTAssertEqual(
            filter.rejectionReason(for: "okay."),
            .exactPattern
        )
    }

    func testNearSilenceInventionRequiresBothRMSAndKnownPattern() {
        let filter = HallucinationFilter(
            patterns: [],
            knownInventionPatterns: ["Thanks for watching"]
        )

        XCTAssertEqual(
            filter.verdict(
                for: "thanks for watching",
                activeDurationSeconds: 2,
                activeRMS: 0.002
            ),
            .rejected(.nearSilenceInvention)
        )
        XCTAssertEqual(
            filter.verdict(
                for: "thanks for watching",
                activeDurationSeconds: 2,
                activeRMS: 0.0021
            ),
            .accepted
        )
        XCTAssertEqual(
            filter.verdict(
                for: "a quiet sentence",
                activeDurationSeconds: 2,
                activeRMS: 0.001
            ),
            .accepted
        )
    }

    func testDensityGuardsUseDurationAndHaveMinimumBudgets() {
        let filter = HallucinationFilter(patterns: [], knownInventionPatterns: [])

        XCTAssertEqual(
            filter.verdict(
                for: (1...13).map(String.init).joined(separator: " "),
                activeDurationSeconds: 1,
                activeRMS: 0.1
            ),
            .rejected(.excessiveTokenDensity(wordCount: 13, maximum: 12))
        )
        XCTAssertEqual(
            filter.verdict(
                for: String(repeating: "a", count: 65),
                activeDurationSeconds: 0.1,
                activeRMS: 0.1
            ),
            .rejected(.excessiveCharacterDensity(characterCount: 65, maximum: 64))
        )
        XCTAssertEqual(
            filter.verdict(
                for: (1...12).map(String.init).joined(separator: " "),
                activeDurationSeconds: 0.1,
                activeRMS: 0.1
            ),
            .accepted
        )
    }

    func testRepeatedNGramRequiresFourContiguousRepetitions() {
        let filter = HallucinationFilter(patterns: [], knownInventionPatterns: [])
        let loop = Array(repeating: "one two three", count: 4).joined(separator: " ")
        let validRepetition = Array(repeating: "one two three", count: 3).joined(separator: " ")

        XCTAssertEqual(
            filter.verdict(for: loop),
            .rejected(.repeatedNGram(tokenCount: 3, repetitions: 4))
        )
        XCTAssertEqual(filter.verdict(for: validRepetition), .accepted)
    }

    func testRepeatedLongSentenceIsRejectedButDifferentSentencesPass() {
        let filter = HallucinationFilter(patterns: [], knownInventionPatterns: [])
        let sentence = "one two three four five six seven eight"

        XCTAssertEqual(
            filter.verdict(for: "\(sentence). \(sentence)."),
            .rejected(.repeatedSentence(tokenCount: 8))
        )
        XCTAssertEqual(
            filter.verdict(for: "\(sentence). one two three four five six seven nine."),
            .accepted
        )
    }
}
