import Foundation

/// A phrase the user fixed by hand: what the model wrote and what they meant.
struct LearnedSubstitution: Codable, Hashable, Sendable {
    let heard: String
    let written: String
}

/// Word-level diff between a transcript and the user's fixed version.
///
/// Only replacements count: a short span of words swapped for a short span
/// of different words between unchanged anchors. Case and punctuation edits,
/// insertions, deletions, and long rewrites teach nothing reusable.
enum CorrectionDiff {
    static let maximumWords = 3

    static func substitutions(from original: String, to fixed: String) -> [LearnedSubstitution] {
        let before = words(original)
        let after = words(fixed)
        let lcs = longestCommonSubsequence(before.map(\.key), after.map(\.key))

        var result: [LearnedSubstitution] = []
        var i = 0, j = 0
        for (anchorI, anchorJ) in lcs + [(before.count, after.count)] {
            let heard = before[i..<anchorI]
            let written = after[j..<anchorJ]
            if !heard.isEmpty, !written.isEmpty,
               heard.count <= maximumWords, written.count <= maximumWords {
                result.append(LearnedSubstitution(
                    heard: heard.map(\.key).joined(separator: " "),
                    written: written.map(\.text).joined(separator: " ")
                ))
            }
            i = anchorI + 1
            j = anchorJ + 1
        }
        return result
    }

    private struct Word {
        /// The word without surrounding punctuation, as typed.
        let text: String
        /// Case-folded form used for matching.
        let key: String
    }

    private static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { return nil }
            return Word(text: trimmed, key: trimmed.lowercased())
        }
    }

    /// Index pairs of one longest common subsequence, in order.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}

/// Counts repeated hand fixes so Speakeasy can offer a correction rule once
/// the user has made the same fix twice. Bounded and dismissible.
struct CorrectionTally: Codable, Equatable, Sendable {
    static let capacity = 200
    static let suggestionThreshold = 2

    private struct Entry: Codable, Equatable, Sendable {
        var substitution: LearnedSubstitution
        var count: Int
        var lastSeen: Int
    }

    private var entries: [String: Entry] = [:]
    private var dismissed: Set<String> = []
    private var clock = 0

    var entryCount: Int { entries.count }

    mutating func record(_ substitutions: [LearnedSubstitution]) {
        for substitution in substitutions {
            clock += 1
            let key = Self.key(substitution)
            if var entry = entries[key] {
                entry.count += 1
                entry.lastSeen = clock
                entries[key] = entry
            } else {
                entries[key] = Entry(substitution: substitution, count: 1, lastSeen: clock)
            }
        }
        if entries.count > Self.capacity {
            let evicted = entries
                .sorted { ($0.value.count, $0.value.lastSeen) < ($1.value.count, $1.value.lastSeen) }
                .prefix(entries.count - Self.capacity)
                .map(\.key)
            evicted.forEach { entries[$0] = nil }
        }
    }

    mutating func dismiss(_ substitution: LearnedSubstitution) {
        let key = Self.key(substitution)
        dismissed.insert(key)
        entries[key] = nil
    }

    mutating func accept(_ substitution: LearnedSubstitution) {
        entries[Self.key(substitution)] = nil
    }

    func suggestions(existing: [TranscriptCorrection]) -> [LearnedSubstitution] {
        let existingHeard = Set(existing.map { $0.heard.lowercased() })
        return entries
            .filter { key, entry in
                entry.count >= Self.suggestionThreshold
                    && !dismissed.contains(key)
                    && !existingHeard.contains(entry.substitution.heard.lowercased())
            }
            .values
            .sorted { $0.lastSeen < $1.lastSeen }
            .map(\.substitution)
    }

    private static func key(_ substitution: LearnedSubstitution) -> String {
        substitution.heard.lowercased() + "\u{1F}" + substitution.written
    }
}

enum CorrectionTallyStore {
    private static let key = "correctionTally"

    static func load(defaults: UserDefaults = .standard) -> CorrectionTally {
        guard let data = defaults.data(forKey: key),
              let tally = try? JSONDecoder().decode(CorrectionTally.self, from: data) else {
            return CorrectionTally()
        }
        return tally
    }

    static func save(_ tally: CorrectionTally, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(tally) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The last pasted dictation can be undone with the target app's own
/// Command-Z while that app is still in front and the paste is recent.
struct PasteUndoWindow: Equatable, Sendable {
    static let duration: TimeInterval = 30

    private var target: TranscriptDeliveryApplication?
    private var pastedAt: TimeInterval = 0

    mutating func record(target: TranscriptDeliveryApplication, at time: TimeInterval) {
        self.target = target
        pastedAt = time
    }

    func canUndo(current: TranscriptDeliveryTarget, now: TimeInterval) -> Bool {
        guard let target, case .external(let application) = current, application == target else {
            return false
        }
        return now >= pastedAt && now - pastedAt <= Self.duration
    }

    mutating func consume(current: TranscriptDeliveryTarget, now: TimeInterval) -> Bool {
        guard canUndo(current: current, now: now) else { return false }
        target = nil
        return true
    }

    mutating func clear() {
        target = nil
    }
}
