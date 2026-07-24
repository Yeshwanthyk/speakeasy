import Foundation
import os

struct ASRModelDownloadManifest {
    let baseURL: URL
    let files: [String]

    func remoteURL(for file: String) -> URL {
        baseURL.appendingPathComponent(file)
    }
}

enum ASRModelInstallError: Error {
    case downloadUnavailable(String)
    case invalidHTTPStatus(URL, Int)
    case downloadedFileMissing(String)
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
    private let fileManager: FileManager
    private let downloader: ModelFileDownloading
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "models")

    init(
        fileManager: FileManager = .default,
        downloader: ModelFileDownloading = URLSessionModelFileDownloader()
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
    }

    func resolveOrInstall(kind: ASRModelKind) async throws -> ASRModelConfiguration {
        do {
            return try ModelPathResolver.configuredASRModel(kind: kind)
        } catch {
            switch error {
            case ModelPathError.modelNotFound, ModelPathError.modelIncomplete:
                guard kind.downloadManifest != nil else {
                    throw ASRModelInstallError.downloadUnavailable(kind.displayName)
                }
            default:
                throw error
            }
        }

        let targetURL = try ModelPathResolver.preferredInstallURL(kind: kind)
        try await install(kind: kind, at: targetURL)
        return try ModelPathResolver.configuredASRModel(kind: kind)
    }

    func install(kind: ASRModelKind, at targetURL: URL) async throws {
        if ModelPathResolver.isModelInstalled(kind: kind, at: targetURL) {
            return
        }

        guard let manifest = kind.downloadManifest else {
            throw ASRModelInstallError.downloadUnavailable(kind.displayName)
        }

        let parentURL = targetURL.deletingLastPathComponent()
        let tempURL = parentURL.appendingPathComponent(
            ".\(targetURL.lastPathComponent).download-\(UUID().uuidString)",
            isDirectory: true
        )

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true)

        var shouldRemoveTemp = true
        defer {
            if shouldRemoveTemp {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        logger.info("Installing \(kind.displayName, privacy: .public) model into \(targetURL.path, privacy: .public)")

        for file in manifest.files {
            let remoteURL = manifest.remoteURL(for: file)
            let destinationURL = tempURL.appendingPathComponent(file)
            logger.info("Downloading \(file, privacy: .public)")

            let downloadedURL = try await downloader.download(from: remoteURL)
            guard fileManager.fileExists(atPath: downloadedURL.path) else {
                throw ASRModelInstallError.downloadedFileMissing(file)
            }

            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: downloadedURL, to: destinationURL)
        }

        let missing = ModelPathResolver.missingRequiredFiles(kind: kind, at: tempURL)
        guard missing.isEmpty else {
            throw ModelPathError.modelIncomplete(tempURL.path, missing: missing)
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.moveItem(at: tempURL, to: targetURL)
        shouldRemoveTemp = false
        logger.info("Installed \(kind.displayName, privacy: .public) model")
    }
}

private extension ASRModelKind {
    var downloadManifest: ASRModelDownloadManifest? {
        switch self {
        case .parakeetTDT:
            return nil
        case .nemotron:
            return ASRModelDownloadManifest(
                baseURL: URL(string: "https://huggingface.co/smcleod/nemotron-3.5-asr-streaming-0.6b-int8/resolve/main")!,
                files: [
                    "config.json",
                    "decoder_joint.onnx",
                    "encoder.onnx",
                    "encoder.onnx.data",
                    "tokenizer.model"
                ]
            )
        }
    }
}
