import Darwin
import Foundation
import XCTest

/// Per-process root for every file a test writes. Removed when the test
/// bundle finishes; roots left by crashed runs are swept on first use.
let testScratchDirectory: URL = {
    let fileManager = FileManager.default
    let prefix = "speakeasy-tests-"
    let temporary = fileManager.temporaryDirectory

    let names = (try? fileManager.contentsOfDirectory(atPath: temporary.path)) ?? []
    for name in names where name.hasPrefix(prefix) {
        guard let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0, errno == ESRCH else {
            continue
        }
        try? fileManager.removeItem(at: temporary.appendingPathComponent(name))
    }

    let root = temporary.appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    XCTestObservationCenter.shared.addTestObserver(TestScratchCleaner(root: root))
    return root
}()

private final class TestScratchCleaner: NSObject, XCTestObservation {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        try? FileManager.default.removeItem(at: root)
    }
}
