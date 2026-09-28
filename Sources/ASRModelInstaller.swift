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

/// Downloads with byte progress and cooperative cancellation. Each download
/// uses its own session so progress callbacks never cross between files.
final class ProgressReportingModelFileDownloader: NSObject, ModelFileDownloading, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (_ received: Int64, _ expected: Int64?) -> Void

    private let progress: ProgressHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?

    init(progress: @escaping ProgressHandler) {
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                lock.withLock {
                    self.continuation = continuation
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns.
        let result: Result<URL, Error>
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode),
           let url = downloadTask.originalRequest?.url {
            result = .failure(ASRModelInstallError.invalidHTTPStatus(url, response.statusCode))
        } else {
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-model-\(UUID().uuidString)")
            result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        }
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil; self.task = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
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

        // Downloaders return a disposable temporary file; move it so large
        // models are never duplicated on disk.
        try fileManager.moveItem(at: downloadedURL, to: stagingURL)
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
