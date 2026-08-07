import Foundation
import XCTest
@testable import Speakeasy

final class OrderedSnapshotWriterTests: XCTestCase {
    func testBlockedFirstWriteCannotBeOvertakenByNewerSnapshots() async {
        let writer = OrderedSnapshotWriter(label: "com.speakeasy.tests.ordered-writer")
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let written = LockedIntegers()

        let first = writer.enqueue {
            firstStarted.signal()
            releaseFirst.wait()
            written.append(1)
            return true
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        let second = writer.enqueue {
            written.append(2)
            return true
        }
        let newest = writer.enqueue {
            written.append(3)
            return true
        }

        releaseFirst.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        let newestResult = await newest.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertTrue(newestResult)
        XCTAssertEqual(written.values, [1, 2, 3])
    }
}

private final class LockedIntegers: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] { lock.withLock { storage } }

    func append(_ value: Int) {
        lock.withLock { storage.append(value) }
    }
}
