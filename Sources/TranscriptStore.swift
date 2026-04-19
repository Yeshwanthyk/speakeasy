import Foundation
import os

/// Ring-buffered history of transcribed strings, persisted to Application Support.
///
/// Reads/writes to the in-memory array happen on the main thread (append is called
/// from `AppCoordinator.handleTranscriptionResult`, which runs on main; menu reads
/// also run on main). Disk writes are dispatched to a background serial queue so
/// the paste hot path is never blocked by I/O.
final class TranscriptStore {
    static let capacity = 50

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "transcripts")
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.speakeasy.app.transcripts.write", qos: .utility)
    private var entries: [String]

    /// Entries in insertion order (oldest first).
    var all: [String] { entries }

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.entries = Self.load(from: resolvedURL)
    }

    func append(_ text: String) {
        entries.append(text)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        scheduleWrite()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleWrite()
    }

    private func scheduleWrite() {
        let snapshot = entries
        let url = fileURL
        writeQueue.async { [logger] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to persist transcripts: \(String(describing: error))")
            }
        }
    }

    private static func load(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        if decoded.count > capacity {
            return Array(decoded.suffix(capacity))
        }
        return decoded
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Wisp"
        return base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
