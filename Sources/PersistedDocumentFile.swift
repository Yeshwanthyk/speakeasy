import Foundation
import os

/// Why a stored JSON document was rejected on load.
enum PersistedDocumentError: Error, Equatable {
    case malformed
    case unsupportedSchemaVersion(Int)
    case outOfRange
}

/// Load rules shared by the JSON documents under Application Support.
enum PersistedDocumentFile {
    /// Decodes the file at `url`. A missing file returns nil. A file that
    /// exists but fails to read or `decode` is logged and moved to
    /// `invalidFileURL(for:)` so the next save cannot destroy it; that also
    /// returns nil.
    static func load<Value>(
        from url: URL,
        logger: Logger,
        decode: (Data) throws -> Value
    ) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            let invalidURL = invalidFileURL(for: url)
            logger.error(
                "Setting aside unreadable \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            try? FileManager.default.removeItem(at: invalidURL)
            try? FileManager.default.moveItem(at: url, to: invalidURL)
            return nil
        }
    }

    /// Decodes a versioned document, checking `schemaVersion` first so a
    /// newer file reports its version rather than a shape mismatch.
    static func decode<Document: Decodable>(
        _ type: Document.Type,
        from data: Data,
        schemaVersion expected: Int
    ) throws -> Document {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw PersistedDocumentError.malformed
        }
        guard probe.schemaVersion == expected else {
            throw PersistedDocumentError.unsupportedSchemaVersion(probe.schemaVersion)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PersistedDocumentError.malformed
        }
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    static func invalidFileURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("invalid.json")
    }
}
