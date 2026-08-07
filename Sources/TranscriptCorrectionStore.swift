import Foundation

struct TranscriptCorrectionDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var corrections: [TranscriptCorrection]

    init(corrections: [TranscriptCorrection], schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.corrections = corrections
    }
}

/// Local persistence for the user's exact corrections.
///
/// Loading happens when the store is created, outside the dictation path.
/// Updates validate and snapshot the bounded document before performing their
/// atomic write on a utility queue.
@MainActor
final class TranscriptCorrectionStore {
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.speakeasy.corrections.write", qos: .utility)
    private var corrections: [TranscriptCorrection]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.corrections = Self.load(from: self.fileURL)
    }

    func allCorrections() -> [TranscriptCorrection] {
        corrections
    }

    /// Replaces the complete correction set and schedules an atomic snapshot.
    @discardableResult
    func replace(_ corrections: [TranscriptCorrection]) throws -> Task<Bool, Never> {
        _ = try TranscriptPostProcessor(corrections: corrections)
        self.corrections = corrections
        let document = TranscriptCorrectionDocument(corrections: corrections)
        let url = fileURL
        return Task { [writeQueue] in
            await withCheckedContinuation { continuation in
                writeQueue.async {
                    do {
                        let data = try JSONEncoder().encode(document)
                        try FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try data.write(to: url, options: .atomic)
                        continuation.resume(returning: true)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private static func load(from url: URL) -> [TranscriptCorrection] {
        guard
            let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(TranscriptCorrectionDocument.self, from: data),
            document.schemaVersion == TranscriptCorrectionDocument.currentSchemaVersion,
            (try? TranscriptPostProcessor(corrections: document.corrections)) != nil
        else {
            return []
        }
        return document.corrections
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
