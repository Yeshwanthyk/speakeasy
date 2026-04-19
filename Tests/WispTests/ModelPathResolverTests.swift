import Foundation
import XCTest
@testable import Wisp

final class ModelPathResolverTests: XCTestCase {
    private static let environmentLock = UnfairLock()

    private func withModelDirectoryOverride(_ path: String, _ body: () throws -> Void) rethrows {
        try Self.environmentLock.withLock {
            let previous = ProcessInfo.processInfo.environment["PARAKEET_MODEL_DIR"]
            setenv("PARAKEET_MODEL_DIR", path, 1)
            defer {
                if let previous {
                    setenv("PARAKEET_MODEL_DIR", previous, 1)
                } else {
                    unsetenv("PARAKEET_MODEL_DIR")
                }
            }
            try body()
        }
    }

    func testEnvironmentOverrideReturnsExistingDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        try withModelDirectoryOverride(url.path) {
            XCTAssertEqual(try ModelPathResolver.parakeetV3Path(), url)
        }
    }

    func testEnvironmentOverrideThrowsForMissingDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try withModelDirectoryOverride(url.path) {
            XCTAssertThrowsError(try ModelPathResolver.parakeetV3Path()) { error in
                guard case let ModelPathError.modelNotFound(path) = error else {
                    XCTFail("Expected modelNotFound, got \(error)")
                    return
                }
                XCTAssertEqual(path, url.path)
            }
        }
    }
}
