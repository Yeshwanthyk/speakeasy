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
        return ASRModelConfiguration(kind: kind, url: targetURL, artifactVerified: true)
    }

    func install(kind: ASRModelKind, at targetURL: URL) async throws {
        let artifact = artifactProvider(kind)
        if (try? ModelPathResolver.verifyArtifact(artifact, at: targetURL)) != nil {
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
        do {
            try ModelPathResolver.verifyArtifact(artifact, at: stagingURL)
        } catch let error as ModelArtifactVerificationError {
            throw Self.installError(for: error)
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: targetURL)
        }
        shouldRemoveStaging = false
        logger.info("Installed and verified \(kind.displayName, privacy: .public)")
    }

    private static func installError(for error: ModelArtifactVerificationError) -> ASRModelInstallError {
        switch error {
        case .fileMissing(let path), .notRegularFile(let path):
            return .downloadedFileMissing(path)
        case .unexpectedFileSize(let expected, let actual):
            return .unexpectedFileSize(expected: expected, actual: actual)
        case .checksumMismatch(let expected, let actual):
            return .checksumMismatch(expected: expected, actual: actual)
        }
    }
}
