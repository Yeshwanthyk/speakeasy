import Foundation
import XCTest
@testable import Speakeasy

final class ASRModelInstallerTests: XCTestCase {
    func testInstallDownloadsNemotronFilesIntoTargetDirectory() async throws {
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-installer-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nemotron-3.5-asr-streaming-0.6b-int8", isDirectory: true)
        let downloader = FakeModelFileDownloader()
        let installer = ASRModelInstaller(downloader: downloader)

        try await installer.install(kind: .nemotron, at: targetURL)

        XCTAssertTrue(ModelPathResolver.isModelInstalled(kind: .nemotron, at: targetURL))
        let downloadedFiles = downloader.requestedURLs.map(\.lastPathComponent)
        for file in ASRModelKind.nemotron.requiredFiles {
            XCTAssertTrue(downloadedFiles.contains(file), "Expected \(file) to be downloaded")
        }
        XCTAssertTrue(downloadedFiles.contains("config.json"))
    }

    func testInstallSkipsAlreadyInstalledModel() async throws {
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-installer-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nemotron-3.5-asr-streaming-0.6b-int8", isDirectory: true)
        try createModelDirectory(kind: .nemotron, at: targetURL)
        let downloader = FakeModelFileDownloader()
        let installer = ASRModelInstaller(downloader: downloader)

        try await installer.install(kind: .nemotron, at: targetURL)

        XCTAssertTrue(downloader.requestedURLs.isEmpty)
    }

    func testInstallRejectsZeroByteDownloadsAndDoesNotPromoteTarget() async throws {
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-installer-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nemotron-3.5-asr-streaming-0.6b-int8", isDirectory: true)
        let downloader = FakeModelFileDownloader(contents: Data())
        let installer = ASRModelInstaller(downloader: downloader)

        do {
            try await installer.install(kind: .nemotron, at: targetURL)
            XCTFail("Expected zero-byte model files to be rejected")
        } catch {
            guard case ModelPathError.modelIncomplete = error else {
                XCTFail("Expected modelIncomplete, got \(error)")
                return
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    private func createModelDirectory(kind: ASRModelKind, at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in kind.requiredFiles {
            try Data("test".utf8).write(to: url.appendingPathComponent(file))
        }
    }
}

private final class FakeModelFileDownloader: ModelFileDownloading {
    private let lock = UnfairLock()
    private let contents: Data
    private var _requestedURLs: [URL] = []

    var requestedURLs: [URL] {
        lock.withLock { _requestedURLs }
    }

    init(contents: Data = Data("test".utf8)) {
        self.contents = contents
    }

    func download(from url: URL) async throws -> URL {
        lock.withLock { _requestedURLs.append(url) }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-installer-tests-\(UUID().uuidString)")
        try contents.write(to: tempURL)
        return tempURL
    }
}
