import Foundation
import XCTest
@testable import Speakeasy

final class LivePreviewTests: XCTestCase {
    // MARK: - Revision policy

    func testFirstNonEmptyPreviewIsAccepted() {
        let policy = PreviewRevisionPolicy()
        XCTAssertEqual(policy.revised(previous: nil, candidate: "hello"), "hello")
    }

    func testEmptyCandidateNeverReplacesAnything() {
        let policy = PreviewRevisionPolicy()
        XCTAssertNil(policy.revised(previous: nil, candidate: "  "))
        XCTAssertNil(policy.revised(previous: "hello world", candidate: ""))
    }

    func testCandidateMayNotShrinkWordCount() {
        let policy = PreviewRevisionPolicy()
        let previous = "deploy the service now"
        XCTAssertNil(policy.revised(previous: previous, candidate: "deploy"))
        XCTAssertNil(policy.revised(previous: previous, candidate: "deploy the service"))
    }

    func testMergedWordShrinkIsRejectedForPreviewDisplay() {
        // ASR often splits one spoken word ("service") into two tokens.
        // Merging shrinks the visible word count, so the preview keeps the
        // longer hypothesis; the final batch pass delivers the corrected
        // text regardless of what the preview showed.
        let policy = PreviewRevisionPolicy()
        XCTAssertNil(
            policy.revised(previous: "deploy the serv ice", candidate: "deploy the service")
        )
    }

    func testSameCountSwapIsAllowed() {
        let policy = PreviewRevisionPolicy()
        XCTAssertEqual(
            policy.revised(previous: "deploy the server", candidate: "deploy the service"),
            "deploy the service"
        )
    }

    func testGrowthIsAccepted() {
        let policy = PreviewRevisionPolicy()
        XCTAssertEqual(
            policy.revised(previous: "deploy the", candidate: "deploy the service today please"),
            "deploy the service today please"
        )
    }

    // MARK: - Scheduler

    private func makeController(
        interval: Double = 700,
        growth: Int = 8_000
    ) -> LivePreviewController {
        LivePreviewController(minimumIntervalMs: interval, minimumGrowthSamples: growth)
    }

    func testRequiresMinimumGrowthBeforeFirstPass() {
        let controller = makeController()
        XCTAssertFalse(controller.shouldTranscribe(nowMs: 1_000, bufferedSampleCount: 4_000))
        XCTAssertTrue(controller.shouldTranscribe(nowMs: 1_000, bufferedSampleCount: 8_000))
    }

    func testRespectsMinimumInterval() {
        let controller = makeController(interval: 700)
        controller.beginPass(nowMs: 0, bufferedSampleCount: 16_000)
        _ = controller.finishPass(candidate: nil)

        XCTAssertFalse(controller.shouldTranscribe(nowMs: 400, bufferedSampleCount: 48_000))
        XCTAssertTrue(controller.shouldTranscribe(nowMs: 701, bufferedSampleCount: 48_000))
    }

    func testOnlyOnePassInFlight() {
        let controller = makeController()
        controller.beginPass(nowMs: 0, bufferedSampleCount: 16_000)
        XCTAssertFalse(controller.shouldTranscribe(nowMs: 5_000, bufferedSampleCount: 80_000),
                       "no second pass while one is in flight")
        controller.finishPass(candidate: nil)
        XCTAssertTrue(controller.shouldTranscribe(nowMs: 5_000, bufferedSampleCount: 80_000))
    }

    func testFinishPassAdoptsThroughPolicy() {
        let controller = makeController()
        controller.beginPass(nowMs: 0, bufferedSampleCount: 16_000)

        // Shrinking hypothesis is rejected; previous text survives.
        XCTAssertEqual(controller.finishPass(candidate: "hello"), "hello")
        controller.beginPass(nowMs: 800, bufferedSampleCount: 32_000)
        XCTAssertEqual(controller.finishPass(candidate: ""), "hello",
                       "rejected pass leaves current preview untouched")
        XCTAssertEqual(controller.previewText, "hello")

        controller.beginPass(nowMs: 1_600, bufferedSampleCount: 48_000)
        XCTAssertEqual(controller.finishPass(candidate: "hello brave world"), "hello brave world")
        XCTAssertEqual(controller.adoptedCount, 2)
    }

    func testResetClearsEverything() {
        let controller = makeController()
        controller.beginPass(nowMs: 0, bufferedSampleCount: 16_000)
        _ = controller.finishPass(candidate: "hello")
        controller.reset()

        XCTAssertEqual(controller.previewText, nil)
        XCTAssertEqual(controller.adoptedCount, 0)
        XCTAssertTrue(controller.shouldTranscribe(nowMs: 1, bufferedSampleCount: 8_000))
    }
}

