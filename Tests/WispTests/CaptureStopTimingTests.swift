import XCTest
@testable import Wisp

final class CaptureStopTimingTests: XCTestCase {
    func testGraceIntervalFallsBackWithoutHistory() {
        let timing = CaptureStopTiming()
        XCTAssertEqual(timing.graceInterval(), CaptureStopTiming.fallbackGrace, accuracy: 0.000_1)
    }

    func testGraceIntervalFallsBackWithTooFewCallbacks() {
        var timing = CaptureStopTiming()
        timing.recordCallback(timestampNs: 0)
        timing.recordCallback(timestampNs: 10_000_000)
        timing.recordCallback(timestampNs: 20_000_000)

        XCTAssertEqual(timing.graceInterval(), CaptureStopTiming.fallbackGrace, accuracy: 0.000_1)
    }

    func testGraceIntervalUsesFloorForFastCadence() {
        var timing = CaptureStopTiming()
        for index in 0..<8 {
            timing.recordCallback(timestampNs: UInt64(index) * 1_000_000)
        }

        XCTAssertEqual(timing.graceInterval(), CaptureStopTiming.minGrace, accuracy: 0.000_1)
    }

    func testGraceIntervalUsesCapForSlowCadence() {
        var timing = CaptureStopTiming()
        for index in 0..<8 {
            timing.recordCallback(timestampNs: UInt64(index) * 200_000_000)
        }

        XCTAssertEqual(timing.graceInterval(), CaptureStopTiming.maxGrace, accuracy: 0.000_1)
    }

    func testGraceIntervalIsDeterministicForSteadyCadence() {
        var timing = CaptureStopTiming()
        for index in 0..<8 {
            timing.recordCallback(timestampNs: UInt64(index) * 20_000_000)
        }

        XCTAssertEqual(timing.graceInterval(), 0.04, accuracy: 0.000_1)
    }

    func testGraceIntervalUsesEmaAtMinimumCallbackCount() {
        var timing = CaptureStopTiming()
        for index in 0..<4 {
            timing.recordCallback(timestampNs: UInt64(index) * 100_000_000)
        }

        XCTAssertEqual(timing.graceInterval(), 0.15, accuracy: 0.000_1)
    }

    func testGraceIntervalUsesEmaForChangingCadence() {
        var timing = CaptureStopTiming()
        for timestamp in [0, 50_000_000, 100_000_000, 200_000_000] {
            timing.recordCallback(timestampNs: UInt64(timestamp))
        }

        XCTAssertEqual(timing.graceInterval(), 0.09, accuracy: 0.000_1)
    }
}
