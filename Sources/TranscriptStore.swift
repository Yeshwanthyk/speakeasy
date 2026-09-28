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

    /// Decodes a stored history file; throws `PersistedDocumentError`.
    static func validatedRecords(from data: Data) throws -> [TranscriptRecord] {
        let document = try PersistedDocumentFile.decode(Self.self, from: data, schemaVersion: currentSchemaVersion)
        return document.records
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
    var correctionsUndone: Bool? = nil
    var stageChanges: [StageChange]?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        finalText: String,
        backend: String,
        outcome: TranscriptionTrace.Outcome,
        timings: TimingSnapshot? = nil,
        stageChanges: [StageChange]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.backend = backend
        self.outcome = outcome
        self.timings = timings
        self.stageChanges = stageChanges
    }
}

/// Ring-buffered structured transcript history, persisted to Application Support.
///
/// In-memory history is main-actor isolated. Disk writes are dispatched to a
/// background serial queue so the paste hot path is never blocked by I/O.
@MainActor
final class TranscriptStore {
    static let capacity = 50

    private static let logger = Logger(subsystem: "com.speakeasy.app", category: "transcripts")
    private let fileURL: URL
    private let writer = OrderedSnapshotWriter(label: "com.speakeasy.app.transcripts.write")
    private var records: [TranscriptRecord]

    func allRecords() -> [TranscriptRecord] {
        records
    }

    /// Text projection used by the history menu and recovery actions.
    func allEntries() -> [String] {
        records.map(\.finalText)
    }

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL

        let loaded = PersistedDocumentFile.load(
            from: resolvedURL,
            logger: Self.logger,
            decode: TranscriptHistoryDocument.validatedRecords(from:)
        ) ?? []
        self.records = Array(loaded.suffix(Self.capacity))
        if records.count != loaded.count {
            scheduleWrite()
        }
    }

    /// Adds a durable-before-delivery record snapshot.
    @discardableResult
    func append(_ record: TranscriptRecord) -> Task<Bool, Never> {
        records.append(record)
        trimToCapacity()
        return scheduleWrite()
    }

    /// Convenience for text-only transcript entries.
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
    func markCorrectionsUndone(id: UUID) -> Task<Bool, Never> {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return Task { false } }
        records[index].correctionsUndone = true
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
        return writer.enqueue { [logger = Self.logger] in
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

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        return base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
