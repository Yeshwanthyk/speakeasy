import XCTest
@testable import Speakeasy

final class CorrectionLearningTests: XCTestCase {
    func testSingleWordSubstitutionIsLearned() {
        XCTAssertEqual(
            CorrectionDiff.substitutions(from: "run cube control get pods", to: "run kubectl get pods"),
            [LearnedSubstitution(heard: "cube control", written: "kubectl")]
        )
    }

    func testPunctuationAndCaseOnlyEditsAreIgnored() {
        XCTAssertEqual(CorrectionDiff.substitutions(from: "hello world", to: "Hello, world."), [])
    }

    func testInsertionsAndDeletionsAreNotSubstitutions() {
        XCTAssertEqual(CorrectionDiff.substitutions(from: "send the file", to: "send the new file"), [])
        XCTAssertEqual(CorrectionDiff.substitutions(from: "send the the file", to: "send the file"), [])
    }

    func testLongRewritesAreNotLearned() {
        XCTAssertEqual(
            CorrectionDiff.substitutions(
                from: "please book a meeting for tomorrow morning",
                to: "please cancel everything we talked about yesterday"
            ),
            []
        )
    }

    func testMultipleSeparateSubstitutionsAreLearned() {
        XCTAssertEqual(
            CorrectionDiff.substitutions(from: "ask yesh about post grass", to: "ask Yesh about Postgres"),
            [LearnedSubstitution(heard: "post grass", written: "Postgres")]
        )
        XCTAssertEqual(
            CorrectionDiff.substitutions(from: "open get hub and jura", to: "open GitHub and Jira"),
            [
                LearnedSubstitution(heard: "get hub", written: "GitHub"),
                LearnedSubstitution(heard: "jura", written: "Jira")
            ]
        )
    }

    func testTrailingPunctuationOnTheFixIsKeptOutOfTheRule() {
        XCTAssertEqual(
            CorrectionDiff.substitutions(from: "deploy to cube control.", to: "deploy to kubectl."),
            [LearnedSubstitution(heard: "cube control", written: "kubectl")]
        )
    }

    func testTallySuggestsAfterTheSameFixTwice() {
        var tally = CorrectionTally()
        let fix = LearnedSubstitution(heard: "cube control", written: "kubectl")

        tally.record([fix])
        XCTAssertEqual(tally.suggestions(existing: []), [])
        tally.record([fix])
        XCTAssertEqual(tally.suggestions(existing: []), [fix])
    }

    func testTallyMatchesHeardCaseInsensitively() {
        var tally = CorrectionTally()
        tally.record([LearnedSubstitution(heard: "Cube control", written: "kubectl")])
        tally.record([LearnedSubstitution(heard: "cube Control", written: "kubectl")])

        XCTAssertEqual(tally.suggestions(existing: []).map(\.written), ["kubectl"])
    }

    func testTallySkipsRulesThatAlreadyExistAndDismissedOnes() {
        var tally = CorrectionTally()
        let fix = LearnedSubstitution(heard: "jura", written: "Jira")
        let other = LearnedSubstitution(heard: "get hub", written: "GitHub")
        tally.record([fix, other])
        tally.record([fix, other])

        let existing = [TranscriptCorrection(heard: "JURA", written: "Jira")]
        XCTAssertEqual(tally.suggestions(existing: existing), [other])

        tally.dismiss(other)
        XCTAssertEqual(tally.suggestions(existing: existing), [])
        tally.record([other])
        XCTAssertEqual(tally.suggestions(existing: existing), [], "a dismissed fix stays dismissed")
    }

    func testTallyIsBounded() {
        var tally = CorrectionTally()
        for index in 0..<(CorrectionTally.capacity + 50) {
            tally.record([LearnedSubstitution(heard: "word\(index)", written: "fix\(index)")])
        }
        XCTAssertLessThanOrEqual(tally.entryCount, CorrectionTally.capacity)
    }

    func testTallyRoundTripsThroughJSON() throws {
        var tally = CorrectionTally()
        let fix = LearnedSubstitution(heard: "a", written: "b")
        tally.record([fix])
        tally.record([fix])

        let decoded = try JSONDecoder().decode(CorrectionTally.self, from: JSONEncoder().encode(tally))
        XCTAssertEqual(decoded.suggestions(existing: []), [fix])
    }
}

final class PasteUndoWindowTests: XCTestCase {
    private let app = TranscriptDeliveryApplication(processIdentifier: 7, bundleIdentifier: "com.example.editor")

    func testUndoIsAvailableOnlyInTheSameAppWithinTheWindow() {
        var window = PasteUndoWindow()
        window.record(target: app, at: 100)

        XCTAssertTrue(window.canUndo(current: .external(app), now: 101))
        XCTAssertFalse(window.canUndo(current: .external(app), now: 100 + PasteUndoWindow.duration + 0.1))
        XCTAssertFalse(window.canUndo(current: .unavailable, now: 101))
        let other = TranscriptDeliveryApplication(processIdentifier: 8, bundleIdentifier: "com.example.other")
        XCTAssertFalse(window.canUndo(current: .external(other), now: 101))
    }

    func testUndoIsSingleUse() {
        var window = PasteUndoWindow()
        window.record(target: app, at: 0)

        XCTAssertTrue(window.consume(current: .external(app), now: 1))
        XCTAssertFalse(window.consume(current: .external(app), now: 2))
    }

    func testNothingRecordedMeansNothingToUndo() {
        var window = PasteUndoWindow()
        XCTAssertFalse(window.canUndo(current: .external(app), now: 0))
    }
}
