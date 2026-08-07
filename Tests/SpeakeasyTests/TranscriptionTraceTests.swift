import XCTest
@testable import Speakeasy

final class TranscriptionTraceTests: XCTestCase {
    func testDurationsAreComputedFromExplicitMarkers() {
        var trace = TranscriptionTrace(hotkeyPressedAt: 1_000_000)

        trace.markCaptureStarted(at: 3_000_000)
        trace.markHotkeyReleased(at: 4_000_000)
        trace.markStopReturned(sampleCount: 16_000, prependedSampleCount: 1_600, graceDurationMs: 12.5, at: 9_000_000)
        trace.markTranscriptionStarted(at: 10_000_000)
        trace.markTranscriptionEnded(at: 30_000_000)
        trace.markPasteRequested(at: 35_000_000)

        XCTAssertEqual(trace.hotkeyPressToCaptureStartMs, 2)
        XCTAssertEqual(trace.hotkeyReleaseToStopReturnMs, 5)
        XCTAssertEqual(trace.transcriptionDurationMs, 20)
        XCTAssertEqual(trace.transcriptionEndToPasteRequestMs, 5)
        XCTAssertEqual(trace.hotkeyReleaseToTextMs, 26)
        XCTAssertEqual(trace.hotkeyReleaseToPasteRequestMs, 31)
        XCTAssertEqual(trace.utteranceDurationMs, 1_000)
        XCTAssertEqual(trace.prependedDurationMs, 100)
        XCTAssertEqual(trace.graceDurationMs, 12.5)
    }

    func testDurationsStayNilUntilBothEndpointsExist() {
        let trace = TranscriptionTrace(hotkeyPressedAt: 1_000_000)

        XCTAssertNil(trace.hotkeyPressToCaptureStartMs)
        XCTAssertNil(trace.hotkeyReleaseToStopReturnMs)
        XCTAssertNil(trace.transcriptionDurationMs)
        XCTAssertNil(trace.transcriptionEndToPasteRequestMs)
        XCTAssertNil(trace.hotkeyReleaseToTextMs)
        XCTAssertNil(trace.hotkeyReleaseToPasteRequestMs)
    }

    func testDurationsStayNilWhenEndPrecedesStart() {
        var trace = TranscriptionTrace(hotkeyPressedAt: 10_000_000)

        trace.markCaptureStarted(at: 9_000_000)
        trace.markHotkeyReleased(at: 20_000_000)
        trace.markStopReturned(sampleCount: 0, at: 19_000_000)
        trace.markTranscriptionStarted(at: 40_000_000)
        trace.markTranscriptionEnded(at: 19_000_000)
        trace.markPasteRequested(at: 18_000_000)

        XCTAssertNil(trace.hotkeyPressToCaptureStartMs)
        XCTAssertNil(trace.hotkeyReleaseToStopReturnMs)
        XCTAssertNil(trace.transcriptionDurationMs)
        XCTAssertNil(trace.transcriptionEndToPasteRequestMs)
        XCTAssertNil(trace.hotkeyReleaseToTextMs)
        XCTAssertNil(trace.hotkeyReleaseToPasteRequestMs)
    }

    func testStopMarkerUpdatesSampleMetadata() {
        var trace = TranscriptionTrace()

        trace.markStopReturned(sampleCount: 8_000, prependedSampleCount: 800, graceDurationMs: 80)

        XCTAssertEqual(trace.sampleCount, 8_000)
        XCTAssertEqual(trace.prependedSampleCount, 800)
        XCTAssertEqual(trace.utteranceDurationMs, 500)
        XCTAssertEqual(trace.prependedDurationMs, 50)
        XCTAssertEqual(trace.graceDurationMs, 80)
        XCTAssertNotNil(trace.stopReturnedAt)
    }

}
