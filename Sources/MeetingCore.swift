import Foundation

// MARK: - Model

/// Who a meeting segment came from. Speakeasy separates the two capture
/// sources, not individual remote speakers.
enum MeetingTrack: String, Codable, CaseIterable, Sendable {
    /// The microphone.
    case you
    /// System audio: everyone else on the call.
    case them

    var label: String {
        switch self {
        case .you: return "You"
        case .them: return "Them"
        }
    }
}

struct MeetingSegment: Codable, Equatable, Sendable {
    let track: MeetingTrack
    /// Seconds from the start of the meeting.
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct MeetingManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    enum State: String, Codable, Sendable {
        case recording
        case finished
        /// Speakeasy quit or crashed mid-recording; audio up to the last
        /// flushed chunk and every logged segment survive.
        case interrupted
    }

    var schemaVersion = MeetingManifest.currentSchemaVersion
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    /// The call app that triggered or accompanied the recording.
    var appName: String?
    var state: State
    /// Chunk file names keyed by track raw value, in order, relative to the
    /// meeting folder. (String keys keep the JSON an object on macOS 12.)
    var audioChunks: [String: [String]] = [:]
    var audioDeleted = false
    var capturedSystemAudio = false

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var hasAudio: Bool {
        !audioDeleted && audioChunks.values.contains { !$0.isEmpty }
    }

    func chunks(for track: MeetingTrack) -> [String] {
        audioChunks[track.rawValue] ?? []
    }
}

// MARK: - Long recordings on disk

/// Streams 16 kHz mono PCM into a sequence of 16-bit WAV files so a meeting
/// of any length uses bounded memory. The header is rewritten after every
/// append, so a crash leaves each chunk playable up to its last write.
final class ChunkedWAVWriter {
    static let defaultChunkSeconds: TimeInterval = 300

    let directory: URL
    let prefix: String
    let sampleRate: Int
    private let samplesPerChunk: Int
    private var handle: FileHandle?
    private var samplesInChunk = 0
    private(set) var chunkNames: [String] = []
    private(set) var totalSamples = 0

    init(directory: URL, prefix: String, sampleRate: Int = 16_000, chunkSeconds: TimeInterval = defaultChunkSeconds) {
        self.directory = directory
        self.prefix = prefix
        self.sampleRate = sampleRate
        self.samplesPerChunk = max(1, Int(chunkSeconds * Double(sampleRate)))
    }

    deinit {
        try? handle?.close()
    }

    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        var offset = 0
        while offset < samples.count {
            if handle == nil { try openChunk() }
            let count = min(samples.count - offset, samplesPerChunk - samplesInChunk)
            var pcm = Data(count: count * 2)
            pcm.withUnsafeMutableBytes { raw in
                let output = raw.bindMemory(to: Int16.self)
                for index in 0..<count {
                    let value = samples[offset + index]
                    let clamped = value.isFinite ? min(max(value, -1), 1) : 0
                    output[index] = Int16(clamped * Float(Int16.max)).littleEndian
                }
            }
            try handle?.write(contentsOf: pcm)
            samplesInChunk += count
            totalSamples += count
            offset += count
            try writeHeader()
            if samplesInChunk == samplesPerChunk {
                try closeChunk()
            }
        }
    }

    func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    /// Finalizes the open chunk. Safe to call more than once.
    func finish() throws {
        try closeChunk()
    }

    private func openChunk() throws {
        let name = String(format: "%@-%04d.wav", prefix, chunkNames.count + 1)
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0, sampleRate: sampleRate)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
        samplesInChunk = 0
        chunkNames.append(name)
    }

    private func closeChunk() throws {
        guard let handle else { return }
        try writeHeader()
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }

    private func writeHeader() throws {
        guard let handle else { return }
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: samplesInChunk * 2, sampleRate: sampleRate))
        try handle.seek(toOffset: end)
    }

    static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        return data
    }
}

// MARK: - Segmenting live audio

/// Cuts one track's live audio at natural pauses so each piece can be
/// transcribed while the meeting continues. Stretches that never contain
/// speech-level energy are skipped, not transcribed.
struct MeetingSegmenter {
    static let sampleRate = 16_000
    static let frameSamples = 320
    static let minimumSamples = 3 * sampleRate
    static let maximumSamples = 30 * sampleRate
    /// 500 ms of quiet ends a segment once it is long enough.
    static let pauseFrames = 25
    /// Fewer voiced frames than this (100 ms) is not worth transcribing.
    static let minimumVoicedFrames = 5

    private(set) var segmentStart = 0
    private var position = 0
    private var quietFrames = 0
    private var voicedFrames = 0
    private var floor: Float = 0.002

    /// Feeds one 20 ms frame's RMS; returns a finished segment's sample range.
    mutating func feed(rms: Float) -> Range<Int>? {
        position += Self.frameSamples
        let level = rms.isFinite ? rms : 0
        floor = min(max(floor * 0.999, level * 0.25), max(0.002, level))
        if level < max(0.002, floor * 2) {
            quietFrames += 1
        } else {
            quietFrames = 0
            voicedFrames += 1
        }

        let length = position - segmentStart
        if quietFrames >= Self.pauseFrames, length >= Self.minimumSamples {
            return cut()
        }
        if length >= Self.maximumSamples {
            return cut()
        }
        return nil
    }

    /// Ends the current segment at the end of the recording.
    mutating func finish() -> Range<Int>? {
        position > segmentStart ? cut() : nil
    }

    private mutating func cut() -> Range<Int>? {
        let range = segmentStart..<position
        let hasSpeech = voicedFrames >= Self.minimumVoicedFrames
        segmentStart = position
        quietFrames = 0
        voicedFrames = 0
        return hasSpeech ? range : nil
    }
}

/// Holds one track's not-yet-segmented samples, trimmed as segments finish.
struct MeetingSampleWindow {
    private(set) var startOffset = 0
    private(set) var samples: [Float] = []

    var endOffset: Int { startOffset + samples.count }

    mutating func append(_ buffer: UnsafeBufferPointer<Float>) {
        samples.append(contentsOf: buffer)
    }

    /// Copies `range` (absolute offsets) and drops everything before its end.
    mutating func take(_ range: Range<Int>) -> ContiguousArray<Float> {
        let lower = max(range.lowerBound, startOffset) - startOffset
        let upper = min(range.upperBound, endOffset) - startOffset
        let slice = lower < upper ? ContiguousArray(samples[lower..<upper]) : []
        discard(through: range.upperBound)
        return slice
    }

    mutating func discard(through offset: Int) {
        let drop = min(max(0, offset - startOffset), samples.count)
        samples.removeFirst(drop)
        startOffset += drop
    }
}

// MARK: - Cleaning up the transcript

/// Without headphones the microphone hears the other side through the
/// speakers, so "You" repeats "Them". A mic segment is dropped when most of
/// its words were also said on the system track at about the same time.
enum MeetingEchoFilter {
    static let window: TimeInterval = 4
    static let overlapThreshold = 0.6

    static func removingEchoes(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        let them = segments.filter { $0.track == .them }
        guard !them.isEmpty else { return segments }
        return segments.filter { segment in
            segment.track == .them || !isEcho(segment, against: them)
        }
    }

    static func isEcho(_ mic: MeetingSegment, against them: [MeetingSegment]) -> Bool {
        let words = tokens(mic.text)
        guard !words.isEmpty else { return true }
        let nearby = them.filter {
            $0.end >= mic.start - window && $0.start <= mic.end + window
        }
        guard !nearby.isEmpty else { return false }
        let heard = Set(nearby.flatMap { tokens($0.text) })
        let shared = words.filter(heard.contains).count
        return Double(shared) / Double(words.count) >= overlapThreshold
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }
}

/// Deterministic notes that need no model: talk time and likely action items.
struct MeetingNotes: Equatable, Sendable {
    struct ActionItem: Equatable, Sendable {
        let track: MeetingTrack
        let time: TimeInterval
        let text: String
    }

    static let maximumActionItems = 12
    private static let actionCues = [
        "i'll ", "i will ", "we'll ", "we will ", "we need to ", "we should ", "you should ",
        "can you ", "could you ", "action item", "follow up", "follow-up", "let's ", "to do",
        "todo", "deadline", "by monday", "by tuesday", "by wednesday", "by thursday", "by friday",
        "by tomorrow", "by end of", "next week"
    ]

    let talkTime: [MeetingTrack: TimeInterval]
    let actionItems: [ActionItem]
    /// Model-written summary when Apple Intelligence is available.
    var summary: String?

    static func extract(from segments: [MeetingSegment]) -> MeetingNotes {
        var talkTime: [MeetingTrack: TimeInterval] = [:]
        var items: [ActionItem] = []
        for segment in segments {
            talkTime[segment.track, default: 0] += max(0, segment.end - segment.start)
            for sentence in sentences(segment.text) where items.count < maximumActionItems {
                let lowered = " " + sentence.lowercased() + " "
                if actionCues.contains(where: { lowered.contains(" " + $0) }) {
                    items.append(ActionItem(track: segment.track, time: segment.start, text: sentence))
                }
            }
        }
        return MeetingNotes(talkTime: talkTime, actionItems: items, summary: nil)
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            let trimmed = substring?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }
}

enum MeetingFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Joins consecutive segments from the same track that are close together.
    static func turns(_ segments: [MeetingSegment], joinGap: TimeInterval = 2) -> [MeetingSegment] {
        var turns: [MeetingSegment] = []
        for segment in segments.sorted(by: { ($0.start, $0.track.rawValue) < ($1.start, $1.track.rawValue) }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.track == segment.track, segment.start - last.end <= joinGap {
                turns[turns.count - 1] = MeetingSegment(
                    track: last.track, start: last.start, end: max(last.end, segment.end),
                    text: last.text + " " + text
                )
            } else {
                turns.append(MeetingSegment(track: segment.track, start: segment.start, end: segment.end, text: text))
            }
        }
        return turns
    }

    static func markdown(manifest: MeetingManifest, segments: [MeetingSegment], notes: MeetingNotes) -> String {
        var lines = ["# \(manifest.title)", ""]
        var meta = [DateFormatter.localizedString(from: manifest.startedAt, dateStyle: .medium, timeStyle: .short)]
        if let duration = manifest.duration { meta.append(clock(duration)) }
        if let appName = manifest.appName { meta.append(appName) }
        if !manifest.capturedSystemAudio { meta.append("microphone only") }
        lines.append(meta.joined(separator: " · "))
        lines.append("")
        lines.append("## Notes")
        lines.append("")
        if let summary = notes.summary, !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        let talk = MeetingTrack.allCases.compactMap { track -> String? in
            guard let seconds = notes.talkTime[track], seconds > 0 else { return nil }
            return "\(track.label) \(clock(seconds))"
        }
        if !talk.isEmpty {
            lines.append("Talk time: " + talk.joined(separator: ", "))
            lines.append("")
        }
        if !notes.actionItems.isEmpty {
            lines.append("### Possible action items")
            lines.append("")
            for item in notes.actionItems {
                lines.append("- [\(item.track.label) \(clock(item.time))] \(item.text)")
            }
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        let turns = turns(segments)
        if turns.isEmpty {
            lines.append("_No speech was transcribed._")
        }
        for turn in turns {
            lines.append("**\(turn.track.label)** (\(clock(turn.start))): \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

// MARK: - Retention

enum MeetingRetention {
    /// Meetings whose audio is older than `keepDays`; transcripts are kept.
    /// `nil` keeps audio forever.
    static func audioToDelete(_ meetings: [MeetingManifest], now: Date, keepDays: Int?) -> [UUID] {
        guard let keepDays, keepDays >= 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return meetings
            .filter { $0.state != .recording && $0.hasAudio && ($0.endedAt ?? $0.startedAt) < cutoff }
            .map(\.id)
    }
}

// MARK: - Library on disk

/// One folder per meeting under Application Support:
/// `manifest.json`, `segments.jsonl`, `transcript.md`, and audio chunks.
final class MeetingLibrary: @unchecked Sendable {
    static let manifestName = "manifest.json"
    static let segmentsName = "segments.jsonl"
    static let transcriptName = "transcript.md"

    let root: URL
    private let lock = UnfairLock()

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot()
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Speakeasy", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func create(_ manifest: MeetingManifest) throws -> URL {
        let folder = folder(for: manifest.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try save(manifest)
        return folder
    }

    func save(_ manifest: MeetingManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try lock.withLock {
            try data.write(to: folder(for: manifest.id).appendingPathComponent(Self.manifestName), options: .atomic)
        }
    }

    func manifests() -> [MeetingManifest] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders.compactMap { load(folder: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    func manifest(id: UUID) -> MeetingManifest? {
        load(folder: folder(for: id))
    }

    private func load(folder: URL) -> MeetingManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(MeetingManifest.self, from: data),
              manifest.schemaVersion <= MeetingManifest.currentSchemaVersion else {
            return nil
        }
        return manifest
    }

    func appendSegment(_ segment: MeetingSegment, meeting id: UUID) throws {
        var line = try JSONEncoder().encode(segment)
        line.append(0x0A)
        let url = folder(for: id).appendingPathComponent(Self.segmentsName)
        try lock.withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    /// Reads logged segments; a torn final line from a crash is ignored.
    func segments(meeting id: UUID) -> [MeetingSegment] {
        guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent(Self.segmentsName)) else {
            return []
        }
        return Self.decodeSegments(data)
    }

    static func decodeSegments(_ data: Data) -> [MeetingSegment] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(MeetingSegment.self, from: Data($0))
        }
    }

    func writeTranscript(_ markdown: String, meeting id: UUID) throws {
        try Data(markdown.utf8).write(
            to: folder(for: id).appendingPathComponent(Self.transcriptName), options: .atomic
        )
    }

    func transcriptURL(meeting id: UUID) -> URL {
        folder(for: id).appendingPathComponent(Self.transcriptName)
    }

    func deleteAudio(meeting id: UUID) throws {
        guard var manifest = manifest(id: id) else { return }
        for name in manifest.audioChunks.values.flatMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder(for: id).appendingPathComponent(name))
        }
        manifest.audioDeleted = true
        try save(manifest)
    }

    func delete(meeting id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }

    /// Marks meetings left in `recording` by a crash as interrupted.
    func recoverInterrupted(except activeID: UUID?) {
        for var manifest in manifests() where manifest.state == .recording && manifest.id != activeID {
            manifest.state = .interrupted
            if manifest.endedAt == nil {
                let segments = segments(meeting: manifest.id)
                manifest.endedAt = manifest.startedAt.addingTimeInterval(segments.map(\.end).max() ?? 0)
            }
            try? save(manifest)
        }
    }
}
