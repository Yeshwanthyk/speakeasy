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

    func testOversizedCaptureIsRejectedWithoutTruncation() {
        let buffer = FailedCaptureReplayBuffer()
        let oversized = ContiguousArray<Float>(repeating: 0, count: FailedCaptureReplayBuffer.maxSampleCount + 1)

        XCTAssertFalse(buffer.install(samples: oversized, reason: .transcriptionFailed))
        XCTAssertFalse(buffer.hasCapture)
    }
}
