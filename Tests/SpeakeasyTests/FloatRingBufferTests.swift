import XCTest
@testable import Speakeasy

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

    func testCapacityRoundsUpToPowerOfTwo() {
        let buffer = FloatRingBuffer(capacity: 9)

        XCTAssertEqual(buffer.capacity, 16)
    }

    func testWritingEmptyBufferDoesNotChangeCount() {
        let buffer = FloatRingBuffer(capacity: 4)
        let samples: [Float] = [1, 2]
        samples.withUnsafeBufferPointer { buffer.write($0) }

        ContiguousArray<Float>().withUnsafeBufferPointer { buffer.write($0) }

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(Array(buffer.readLast(4)), [1, 2])
    }

    func testReadLastZeroReturnsEmpty() {
        let buffer = FloatRingBuffer(capacity: 4)
        let samples: [Float] = [1, 2, 3]
        samples.withUnsafeBufferPointer { buffer.write($0) }

        XCTAssertTrue(buffer.readLast(0).isEmpty)
        XCTAssertEqual(buffer.count, 3)
    }

    func testClearResetsCountAndAllowsReuse() {
        let buffer = FloatRingBuffer(capacity: 4)
        [1, 2, 3].map(Float.init).withUnsafeBufferPointer { buffer.write($0) }

        buffer.clear()
        [4, 5].map(Float.init).withUnsafeBufferPointer { buffer.write($0) }

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(Array(buffer.readLast(4)), [4, 5])
    }
}
