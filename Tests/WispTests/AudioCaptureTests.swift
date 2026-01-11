import XCTest
@testable import Wisp

final class AudioCaptureTests: XCTestCase {
    func testAppendSamplesRespectsLimit() {
        var buffer = ContiguousArray<Float>()
        let input = Array(repeating: 1.0 as Float, count: 5)
        input.withUnsafeBufferPointer { pointer in
            let reachedLimit = AudioCapture.appendSamples(
                buffer: &buffer,
                newSamples: pointer,
                maxSamples: 3
            )
            XCTAssertEqual(buffer.count, 3)
            XCTAssertTrue(reachedLimit)
        }
    }

    func testAppendSamplesBelowLimit() {
        var buffer = ContiguousArray<Float>()
        let input = Array(repeating: 0.5 as Float, count: 2)
        input.withUnsafeBufferPointer { pointer in
            let reachedLimit = AudioCapture.appendSamples(
                buffer: &buffer,
                newSamples: pointer,
                maxSamples: 5
            )
            XCTAssertEqual(buffer.count, 2)
            XCTAssertFalse(reachedLimit)
        }
    }

    func testAppendSamplesWhenLimitAlreadyReached() {
        var buffer = ContiguousArray<Float>(repeating: 0.0, count: 4)
        let input = Array(repeating: 1.0 as Float, count: 2)
        input.withUnsafeBufferPointer { pointer in
            let reachedLimit = AudioCapture.appendSamples(
                buffer: &buffer,
                newSamples: pointer,
                maxSamples: 4
            )
            XCTAssertEqual(buffer.count, 4)
            XCTAssertTrue(reachedLimit)
        }
    }

    func testAppendSamplesWithZeroLimit() {
        var buffer = ContiguousArray<Float>()
        let input = [1.0 as Float]
        input.withUnsafeBufferPointer { pointer in
            let reachedLimit = AudioCapture.appendSamples(
                buffer: &buffer,
                newSamples: pointer,
                maxSamples: 0
            )
            XCTAssertEqual(buffer.count, 0)
            XCTAssertTrue(reachedLimit)
        }
    }
}
