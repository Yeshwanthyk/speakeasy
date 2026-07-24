import CryptoKit
import Foundation
import os

enum ASRModelInstallError: Error {
    case invalidArtifactURL(String)
    case invalidHTTPStatus(URL, Int)
    case downloadedFileMissing(String)
    case unexpectedFileSize(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
}

protocol ModelFileDownloading {
    func download(from url: URL) async throws -> URL
}

struct URLSessionModelFileDownloader: ModelFileDownloading {
    func download(from url: URL) async throws -> URL {
        let (fileURL, response) = try await URLSession.shared.download(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ASRModelInstallError.invalidHTTPStatus(url, httpResponse.statusCode)
        }
        return fileURL
    }
}

final class ASRModelInstaller {
    typealias ArtifactProvider = (ASRModelKind) -> ASRModelArtifact

    private let fileManager: FileManager
    private let downloader: ModelFileDownloading
    private let artifactProvider: ArtifactProvider
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "models")

    init(
        fileManager: FileManager = .default,
        downloader: ModelFileDownloading = URLSessionModelFileDownloader(),
        artifactProvider: @escaping ArtifactProvider = { $0.artifact }
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
        self.artifactProvider = artifactProvider
    }

    func resolveOrInstall(kind: ASRModelKind) async throws -> ASRModelConfiguration {
        do {
            return try ModelPathResolver.configuredASRModel(kind: kind)
        } catch ModelPathError.modelNotFound(_), ModelPathError.modelInvalid(_, _) {
            // Download and atomically replace a missing or invalid catalog artifact.
        }

        let targetURL = try ModelPathResolver.preferredInstallURL(kind: kind)
        try await install(kind: kind, at: targetURL)
        return try ModelPathResolver.configuredASRModel(kind: kind)
    }

    func install(kind: ASRModelKind, at targetURL: URL) async throws {
        let artifact = artifactProvider(kind)
        if Self.isVerifiedArtifact(artifact, at: targetURL) {
            return
        }

        let parentURL = targetURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".\(targetURL.lastPathComponent).download-\(UUID().uuidString)"
        )

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        guard let remoteURL = artifact.remoteURL else {
            throw ASRModelInstallError.invalidArtifactURL(artifact.filename)
        }
        logger.info(
            "Downloading \(kind.displayName, privacy: .public) from pinned revision \(artifact.revision, privacy: .public)"
        )
        let downloadedURL = try await downloader.download(from: remoteURL)
        guard fileManager.fileExists(atPath: downloadedURL.path) else {
            throw ASRModelInstallError.downloadedFileMissing(artifact.filename)
        }

        try fileManager.copyItem(at: downloadedURL, to: stagingURL)
        let byteCount = try Self.fileSize(at: stagingURL)
        guard byteCount == artifact.expectedByteCount else {
            throw ASRModelInstallError.unexpectedFileSize(
                expected: artifact.expectedByteCount,
                actual: byteCount
            )
        }

        let checksum = try Self.sha256(at: stagingURL)
        guard checksum == artifact.sha256 else {
            throw ASRModelInstallError.checksumMismatch(
                expected: artifact.sha256,
                actual: checksum
            )
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: targetURL)
        }
        shouldRemoveStaging = false
        logger.info("Installed and verified \(kind.displayName, privacy: .public)")
    }

    private static func isVerifiedArtifact(_ artifact: ASRModelArtifact, at url: URL) -> Bool {
        guard (try? fileSize(at: url)) == artifact.expectedByteCount,
              let checksum = try? sha256(at: url) else {
            return false
        }
        return checksum == artifact.sha256
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func sha256(at url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw ASRModelInstallError.downloadedFileMissing(url.lastPathComponent)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 {
                break
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
