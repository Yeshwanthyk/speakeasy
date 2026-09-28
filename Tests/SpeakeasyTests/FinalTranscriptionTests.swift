import XCTest
@testable import Speakeasy

final class FinalTranscriptionTests: XCTestCase {
    func testOverlapWordDeduplication() {
        XCTAssertEqual(FinalTranscription.merge("We went to the store.", "the store and came back"),
                       "We went to the store. and came back")
        XCTAssertEqual(FinalTranscription.merge("First sentence", "another sentence"),
                       "First sentence another sentence")
        XCTAssertEqual(FinalTranscription.merge("", "  hello world  "), "hello world")
    }

    func testWindowsAndCancellationBetweenCalls() throws {
        let transcriber = WindowTranscriber()
        let samples = ContiguousArray<Float>(repeating: 0.1, count: FinalTranscription.windowSamples + 16_000)
        let result = try FinalTranscription.run(samples: samples, transcriber: transcriber, runID: 42) { false }
        XCTAssertEqual(transcriber.lengths, [FinalTranscription.windowSamples, 48_000])
        XCTAssertEqual(result.0, "hello world again")
        XCTAssertThrowsError(try FinalTranscription.run(samples: samples, transcriber: transcriber, runID: 43) {
            transcriber.lengths.count >= 3
        })
        XCTAssertEqual(transcriber.lengths.count, 3)
    }

    func testTimeoutScalesBeyondTenMinutes() {
        let samples = ContiguousArray<Float>(repeating: 0, count: 16_000 * 60 * 11)
        XCTAssertEqual(AppCoordinator.defaultTranscriptionTimeout(samples: samples), 690)
        XCTAssertEqual(AppCoordinator.defaultTranscriptionTimeout(samples: []), 30)
    }
}

private final class WindowTranscriber: Transcriber, @unchecked Sendable {
    var lengths: [Int] = []

    func transcribe(samples: ContiguousArray<Float>) throws -> String { "" }
    func warmUp(runID: UInt64) throws {}
    func transcribeWithTimings(samples: ContiguousArray<Float>, runID: UInt64) throws -> (String, NativeASRTimings?) {
        lengths.append(samples.count)
        return (lengths.count == 1 ? "hello world" : "world again", nil)
    }
}
