import Foundation
import os

struct TimingSnapshot: Codable, Equatable, Sendable {
    let captureStartMs: Double?
    let releaseToStopMs: Double?
    let transcriptionMs: Double?
    let releaseToTextMs: Double?
    let releaseToPasteMs: Double?
    let transcriptionEndToPasteMs: Double?
    let utteranceMs: Double?
}

struct TranscriptHistoryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var records: [TranscriptRecord]

    init(records: [TranscriptRecord], schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let rawText: String
    let finalText: String
    let backend: String
    var outcome: TranscriptionTrace.Outcome
    var timings: TimingSnapshot?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        finalText: String,
        backend: String,
        outcome: TranscriptionTrace.Outcome,
        timings: TimingSnapshot? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.backend = backend
        self.outcome = outcome
        self.timings = timings
    }
}

/// Ring-buffered structured transcript history, persisted to Application Support.
///
/// In-memory history is main-actor isolated. Disk writes are dispatched to a
/// background serial queue so the paste hot path is never blocked by I/O.
@MainActor
final class TranscriptStore {
    static let capacity = 50

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "transcripts")
    private let fileURL: URL
    private let writer = OrderedSnapshotWriter(label: "com.speakeasy.app.transcripts.write")
    private var records: [TranscriptRecord]

    func allRecords() -> [TranscriptRecord] {
        records
    }

    /// Compatibility projection used by the history menu and recovery actions.
    func allEntries() -> [String] {
        records.map(\.finalText)
    }

    init(fileURL: URL? = nil, legacyFileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        let fallbackURL = legacyFileURL ?? (fileURL == nil ? Self.defaultLegacyFileURL() : nil)
        self.fileURL = resolvedURL

        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            let loaded = Self.load(from: resolvedURL)
            self.records = loaded.records
            if loaded.shouldPersist {
                scheduleWrite()
            }
        } else if let fallbackURL, FileManager.default.fileExists(atPath: fallbackURL.path) {
            let loaded = Self.load(from: fallbackURL)
            self.records = loaded.records
            if loaded.shouldPersist {
                scheduleWrite()
            }
        } else {
            self.records = []
        }
    }

    /// Adds a durable-before-delivery record snapshot.
    @discardableResult
    func append(_ record: TranscriptRecord) -> Task<Bool, Never> {
        records.append(record)
        trimToCapacity()
        return scheduleWrite()
    }

    /// Keeps the old test/tooling convenience while writing the new envelope.
    @discardableResult
    func append(_ text: String) -> Task<Bool, Never> {
        append(
            TranscriptRecord(
                rawText: text,
                finalText: text,
                backend: "unknown",
                outcome: .eventsPosted
            )
        )
    }

    /// Updates delivery outcome/timings after the initial durable snapshot.
    @discardableResult
    func update(
        id: UUID,
        outcome: TranscriptionTrace.Outcome,
        timings: TimingSnapshot?
    ) -> Task<Bool, Never> {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return Task { false }
        }
        records[index].outcome = outcome
        records[index].timings = timings
        return scheduleWrite()
    }

    @discardableResult
    func clear() -> Task<Bool, Never> {
        guard !records.isEmpty else { return Task { true } }
        records.removeAll()
        return scheduleWrite()
    }

    private func trimToCapacity() {
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    @discardableResult
    private func scheduleWrite() -> Task<Bool, Never> {
        let snapshot = TranscriptHistoryDocument(records: records)
        let url = fileURL
        return writer.enqueue { [logger] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                logger.error("Failed to persist transcripts: \(String(describing: error))")
                return false
            }
        }
    }

    private struct LoadResult {
        let records: [TranscriptRecord]
        let shouldPersist: Bool
    }

    private static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(records: [], shouldPersist: false)
        }

        if let document = try? JSONDecoder().decode(TranscriptHistoryDocument.self, from: data),
           document.schemaVersion == TranscriptHistoryDocument.currentSchemaVersion
        {
            let bounded = Array(document.records.suffix(capacity))
            return LoadResult(
                records: bounded,
                shouldPersist: bounded.count != document.records.count
            )
        }

        guard let legacyEntries = try? JSONDecoder().decode([String].self, from: data) else {
            // A malformed canonical file is intentionally not replaced by a
            // legacy fallback or an empty snapshot.
            return LoadResult(records: [], shouldPersist: false)
        }

        let migratedAt = Date()
        let records = legacyEntries.suffix(capacity).map { text in
            TranscriptRecord(
                createdAt: migratedAt,
                rawText: text,
                finalText: text,
                backend: "unknown",
                outcome: .eventsPosted,
                timings: nil
            )
        }
        return LoadResult(records: Array(records), shouldPersist: true)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        return base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private static func defaultLegacyFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.wisp.app", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
