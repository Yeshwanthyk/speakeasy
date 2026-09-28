import Foundation
import XCTest
@testable import Speakeasy

final class ASRModelInstallerTests: XCTestCase {
    private static let testData = Data("test".utf8)
    private static let testArtifact = ASRModelArtifact(
        repository: "example/test",
        revision: "0123456789abcdef",
        filename: "model.gguf",
        expectedByteCount: 4,
        sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    )

    func testInstallDownloadsVerifiesAndPromotesGGUF() async throws {
        let targetURL = makeTargetURL()
        let downloader = FakeModelFileDownloader(contents: Self.testData)
        let installer = makeInstaller(downloader: downloader)

        try await installer.install(kind: .parakeetUnified, at: targetURL)

        XCTAssertEqual(try Data(contentsOf: targetURL), Self.testData)
        XCTAssertEqual(downloader.requestedURLs, [try XCTUnwrap(Self.testArtifact.remoteURL)])
    }

    func testInstallSkipsVerifiedArtifact() async throws {
        let targetURL = makeTargetURL()
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.testData.write(to: targetURL)
        let downloader = FakeModelFileDownloader(contents: Data("replacement".utf8))
        let installer = makeInstaller(downloader: downloader)

        try await installer.install(kind: .parakeetUnified, at: targetURL)

        XCTAssertTrue(downloader.requestedURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: targetURL), Self.testData)
    }

    func testInstallRejectsWrongSizeWithoutPromoting() async throws {
        let targetURL = makeTargetURL()
        let installer = makeInstaller(downloader: FakeModelFileDownloader(contents: Data()))

        do {
            try await installer.install(kind: .parakeetUnified, at: targetURL)
            XCTFail("Expected wrong-sized download to fail")
        } catch let ASRModelInstallError.unexpectedFileSize(expected, actual) {
            XCTAssertEqual(expected, 4)
            XCTAssertEqual(actual, 0)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testInstallRejectsWrongChecksumAndPreservesExistingTarget() async throws {
        let targetURL = makeTargetURL()
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previous = Data("old!".utf8)
        try previous.write(to: targetURL)
        let installer = makeInstaller(
            downloader: FakeModelFileDownloader(contents: Data("nope".utf8))
        )

        do {
            try await installer.install(kind: .parakeetUnified, at: targetURL)
            XCTFail("Expected checksum mismatch")
        } catch let ASRModelInstallError.checksumMismatch(expected, actual) {
            XCTAssertEqual(expected, Self.testArtifact.sha256)
            XCTAssertNotEqual(actual, expected)
        }

        XCTAssertEqual(try Data(contentsOf: targetURL), previous)
    }

    private func makeInstaller(downloader: ModelFileDownloading) -> ASRModelInstaller {
        ASRModelInstaller(
            downloader: downloader,
            artifactProvider: { _ in Self.testArtifact }
        )
    }

    private func makeTargetURL() -> URL {
        testScratchDirectory
            .appendingPathComponent("speakeasy-installer-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("model.gguf")
    }
}

private final class FakeModelFileDownloader: ModelFileDownloading {
    private let lock = UnfairLock()
    private let contents: Data
    private var requested: [URL] = []

    var requestedURLs: [URL] {
        lock.withLock { requested }
    }

    init(contents: Data) {
        self.contents = contents
    }

    func download(from url: URL) async throws -> URL {
        lock.withLock { requested.append(url) }
        let tempURL = testScratchDirectory
            .appendingPathComponent("speakeasy-installer-tests-\(UUID().uuidString)")
        try contents.write(to: tempURL)
        return tempURL
    }
}
