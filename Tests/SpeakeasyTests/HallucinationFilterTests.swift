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
}
