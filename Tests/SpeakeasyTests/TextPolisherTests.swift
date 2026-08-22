import Foundation
import XCTest
@testable import Speakeasy

final class TextPolisherTests: XCTestCase {
    // MARK: - Budget

    func testBudgetFloorForShortUtterances() {
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 0), 48)
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 1), 48)
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 10), 48)
    }

    func testBudgetScalesWithUtteranceLength() {
        // ceil(50 * 1.8) + 24 = 114
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 50), 114)
        // ceil(100 * 1.8) + 24 = 204
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 100), 204)
    }

    func testBudgetCapsForLongUtterances() {
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 500), 256)
        XCTAssertEqual(PolishBudget.maxOutputTokens(spokenTokenEstimate: 10_000), 256)
    }

    func testBudgetFromTextUsesWordEstimate() {
        XCTAssertEqual(
            PolishBudget.maxOutputTokens(forText: "one two three four five six"),
            PolishBudget.maxOutputTokens(spokenTokenEstimate: 6)
        )
    }

    // MARK: - Guard acceptance

    func testGuardAcceptsUnchangedText() {
        let verdict = PolishGuard.validate(source: "hello world", output: "hello world")
        XCTAssertEqual(verdict, .accepted("hello world"))
    }

    func testGuardAcceptsPunctuationAndFillerCleanup() throws {
        let source = "um deploy the service uh please"
        let output = "Deploy the service, please."
        let verdict = PolishGuard.validate(source: source, output: output)
        XCTAssertEqual(try XCTUnwrap(PolishGuard.acceptedText(of: verdict)), output)
    }

    func testGuardAcceptsStutterDeduplication() {
        let verdict = PolishGuard.validate(
            source: "the the kernel compiled",
            output: "the kernel compiled"
        )
        XCTAssertEqual(verdict, .accepted("the kernel compiled"))
    }

    func testGuardAcceptsEmptyOutputForSingleWordSource() {
        let verdict = PolishGuard.validate(source: "okay", output: "")
        XCTAssertEqual(verdict, .accepted(""))
    }

    // MARK: - Guard rejection

    func testGuardRejectsCollapseOfMultiWordSource() {
        let verdict = PolishGuard.validate(source: "deploy the service", output: "")
        XCTAssertEqual(verdict, .rejected(reason: .collapse, source: "deploy the service"))
    }

    func testGuardRejectsOneWordMeaningLoss() {
        let verdict = PolishGuard.validate(
            source: "deploy the service today please",
            output: "deploy the today"
        )
        XCTAssertEqual(verdict, .rejected(reason: .meaningLoss, source: "deploy the service today please"))
    }

    func testGuardRejectsTwoWordMeaningLoss() {
        let verdict = PolishGuard.validate(
            source: "restart the database cluster tonight",
            output: "restart the cluster"
        )
        XCTAssertEqual(verdict, .rejected(reason: .meaningLoss, source: "restart the database cluster tonight"))
    }

    func testGuardRejectsLargeDeletionAsCollapse() {
        let verdict = PolishGuard.validate(
            source: "alpha beta gamma delta epsilon zeta eta theta",
            output: "alpha"
        )
        XCTAssertEqual(verdict, .rejected(reason: .collapse, source: "alpha beta gamma delta epsilon zeta eta theta"))
    }

    func testGuardRejectsWordExpansion() {
        let source = "fix it"
        let output = Array(repeating: "word", count: 13).joined(separator: " ")
        let verdict = PolishGuard.validate(source: source, output: output)
        XCTAssertEqual(verdict, .rejected(reason: .expansion, source: source))
    }

    func testGuardRejectsCharacterExpansion() {
        let source = String(repeating: "a ", count: 5)
        let output = String(repeating: "b", count: 200)
        let verdict = PolishGuard.validate(source: source, output: output)
        XCTAssertEqual(verdict, .rejected(reason: .expansion, source: source))
    }

    func testSanitizedFallsBackToSourceOnRejection() {
        var reportedReason: PolishRejectionReason?
        let delivered = PolishGuard.sanitized(
            source: "deploy the service",
            output: "",
            onRejection: { reportedReason = $0 }
        )
        XCTAssertEqual(delivered, "deploy the service")
        XCTAssertEqual(reportedReason, .collapse)
    }

    func testSanitizedReturnsOutputOnAcceptance() {
        let delivered = PolishGuard.sanitized(source: "hello world", output: "Hello, world!")
        XCTAssertEqual(delivered, "Hello, world!")
    }

    // MARK: - Identity polisher

    func testIdentityPolisherReturnsInputUnchanged() async {
        let polisher = IdentityPolisher()
        let output = await polisher.polish("untouched text")
        XCTAssertEqual(output, "untouched text")
    }
}

extension PolishGuard {
    static func acceptedText(of verdict: PolishGuardVerdict) -> String? {
        if case .accepted(let text) = verdict { return text }
        return nil
    }
}
