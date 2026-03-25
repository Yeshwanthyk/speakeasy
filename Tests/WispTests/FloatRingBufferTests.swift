import XCTest
@testable import Wisp

final class FloatRingBufferTests: XCTestCase {
    func testReadLastOnEmptyBufferReturnsEmpty() {
        let buffer = FloatRingBuffer(capacity: 8)
        XCTAssertTrue(buffer.readLast(4).isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }

    func testReadLastReturnsPartialBufferInOrder() {
        let buffer = FloatRingBuffer(capacity: 8)
        let samples: [Float] = [1, 2, 3]
        samples.withUnsafeBufferPointer { buffer.write($0) }

        XCTAssertEqual(Array(buffer.readLast(8)), samples)
        XCTAssertEqual(buffer.count, 3)
    }

    func testReadLastReturnsWrappedTailInChronologicalOrder() {
        let buffer = FloatRingBuffer(capacity: 4)
        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        samples.withUnsafeBufferPointer { buffer.write($0) }

        XCTAssertEqual(Array(buffer.readLast(4)), [3, 4, 5, 6])
        XCTAssertEqual(buffer.count, 4)
    }

    func testReadLastReturnsExactSuffix() {
        let buffer = FloatRingBuffer(capacity: 16)
        let samples = Array(0..<10).map(Float.init)
        samples.withUnsafeBufferPointer { buffer.write($0) }

        XCTAssertEqual(Array(buffer.readLast(4)), [6, 7, 8, 9])
    }
}
