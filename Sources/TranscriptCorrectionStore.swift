import Foundation
import os

enum TranscriptCorrectionDocumentError: Error, Equatable {
    case malformed
    case unsupportedSchemaVersion(Int)
    case invalidCorrections(TranscriptPostProcessorError)
}

struct TranscriptCorrectionDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var corrections: [TranscriptCorrection]

    init(corrections: [TranscriptCorrection], schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.corrections = corrections
    }

    /// Decodes untrusted file bytes into corrections that are guaranteed to
    /// compile into a `TranscriptPostProcessor`.
    static func validatedCorrections(from data: Data) throws -> [TranscriptCorrection] {
        let document: TranscriptCorrectionDocument
        do {
            document = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw TranscriptCorrectionDocumentError.malformed
        }
        guard document.schemaVersion == currentSchemaVersion else {
            throw TranscriptCorrectionDocumentError.unsupportedSchemaVersion(document.schemaVersion)
        }
        do {
            _ = try TranscriptPostProcessor(corrections: document.corrections)
        } catch let error as TranscriptPostProcessorError {
            throw TranscriptCorrectionDocumentError.invalidCorrections(error)
        }
        return document.corrections
    }
}

/// Local persistence for the user's exact corrections.
///
/// Loading happens when the store is created, outside the dictation path.
/// Updates validate and snapshot the bounded document before performing their
/// atomic write on a utility queue.
@MainActor
final class TranscriptCorrectionStore {
    private static let logger = Logger(subsystem: "com.speakeasy.app", category: "corrections")

    private let fileURL: URL
    private let writer = OrderedSnapshotWriter(label: "com.speakeasy.corrections.write")
    private var corrections: [TranscriptCorrection]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.corrections = Self.load(from: self.fileURL)
    }

    func allCorrections() -> [TranscriptCorrection] {
        corrections
    }

    /// Persists a validated replacement set, then publishes it in memory.
    /// A failed write leaves the last-known-good corrections active.
    @discardableResult
    func replace(_ corrections: [TranscriptCorrection]) throws -> Task<Bool, Never> {
        _ = try TranscriptPostProcessor(corrections: corrections)
        let document = TranscriptCorrectionDocument(corrections: corrections)
        let url = fileURL
        let persistence = writer.enqueue {
            do {
                let data = try JSONEncoder().encode(document)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        return Task { @MainActor [weak self] in
            let didPersist = await persistence.value
            if didPersist {
                self?.corrections = corrections
            }
            return didPersist
        }
    }

    /// Missing files mean no corrections; an invalid file is set aside.
    private static func load(from url: URL) -> [TranscriptCorrection] {
        PersistedDocumentFile.load(
            from: url,
            logger: logger,
            decode: TranscriptCorrectionDocument.validatedCorrections(from:)
        ) ?? []
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        return base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("corrections.json")
    }
}
