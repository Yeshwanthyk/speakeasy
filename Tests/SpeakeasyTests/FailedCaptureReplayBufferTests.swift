import XCTest
@testable import Speakeasy

final class FailedCaptureReplayBufferTests: XCTestCase {
    func testLeaseIsOneShotAndNewerFailureReplacesOlder() {
        let buffer = FailedCaptureReplayBuffer()
        let first = ContiguousArray<Float>([1, 2, 3])
        let second = ContiguousArray<Float>([4, 5])

        XCTAssertTrue(buffer.install(samples: first, reason: .transcriptionFailed))
        XCTAssertTrue(buffer.install(samples: second, reason: .timedOut))
        XCTAssertTrue(buffer.hasCapture)

        let lease = buffer.acquireLease()
        XCTAssertEqual(lease?.samples, second)
        XCTAssertEqual(lease?.reason, .timedOut)
        XCTAssertFalse(buffer.hasCapture)
        XCTAssertNil(buffer.acquireLease())
    }

    func testCeilingMatchesCaptureAndAcceptsMoreThanSixMinutes() {
        XCTAssertEqual(FailedCaptureReplayBuffer.maxSampleCount, AudioCapture.defaultMaxRecordingSamples)
        let buffer = FailedCaptureReplayBuffer()
        let samples = ContiguousArray<Float>(repeating: 0, count: 16_000 * 60 * 6 + 1)
        XCTAssertTrue(buffer.install(samples: samples, reason: .transcriptionFailed))
        XCTAssertEqual(buffer.acquireLease()?.samples.count, samples.count)
    }
}
