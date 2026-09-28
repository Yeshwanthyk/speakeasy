import Foundation

/// Chart-ready view of the locally stored diagnostics document for the
/// Advanced settings page. Built off the view body, on refresh.
struct SettingsInsights: Equatable {
    enum Tone: Equatable {
        case green, teal, blue, purple, yellow, orange, red, gray
    }

    struct Day: Equatable, Identifiable {
        let id: String
        let date: Date
        let words: Int
        let dictations: Int
        let isToday: Bool
    }

    struct Share: Equatable, Identifiable {
        let id: String
        let count: Int
        let tone: Tone
    }

    static let chartDayCount = 14
    static let empty = SettingsInsights(days: [], streakDays: 0, outcomes: [], latency: [], modelUsage: [:], averageWordsPerDictation: 0)

    let days: [Day]
    let streakDays: Int
    let outcomes: [Share]
    let latency: [Share]
    /// Lifetime dictations per model, keyed by `ASRModelKind.preferenceValue`.
    let modelUsage: [String: Int]
    let averageWordsPerDictation: Int

    var bestDay: Day? { days.max { $0.words < $1.words }.flatMap { $0.words > 0 ? $0 : nil } }
    var chartWordsTotal: Int { days.reduce(0) { $0 + $1.words } }
    var latencySampleCount: Int { latency.reduce(0) { $0 + $1.count } }
    var outcomeTotal: Int { outcomes.reduce(0) { $0 + $1.count } }

    func usage(of kind: ASRModelKind) -> Int { modelUsage[kind.preferenceValue, default: 0] }

    static func make(document: DiagnosticsDocument, now: Date, calendar: Calendar = .current) -> SettingsInsights {
        let byDay = Dictionary(document.dailyBuckets.map { ($0.day, $0.aggregate) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: now)

        let days: [Day] = (0..<chartDayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dayKey(for: date, calendar: calendar)
            let stats = byDay[key]
            return Day(
                id: key,
                date: date,
                words: stats?.wordCount ?? 0,
                dictations: stats?.attemptCount ?? 0,
                isToday: offset == 0
            )
        }

        var streak = 0
        var cursor = today
        if (byDay[dayKey(for: cursor, calendar: calendar)]?.attemptCount ?? 0) == 0,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while (byDay[dayKey(for: cursor, calendar: calendar)]?.attemptCount ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let lifetime = document.lifetime
        let outcomes = lifetime.outcomes
        let failed = outcomes.clipboardWriteFailed + outcomes.transcriptPersistenceFailed
            + outcomes.captureInterrupted + outcomes.transcriptionFailed + outcomes.timedOut
            + outcomes.warmupBlocked + outcomes.accessibilityDenied
        let outcomeShares = [
            Share(id: "Pasted", count: outcomes.eventsPosted, tone: .green),
            Share(id: "Copied to clipboard", count: outcomes.clipboardUpdated, tone: .blue),
            Share(id: "Saved to history", count: outcomes.transcriptPersisted, tone: .teal),
            Share(id: "No speech", count: outcomes.noSpeech + outcomes.emptyAudio, tone: .gray),
            Share(id: "Cancelled", count: outcomes.cancelled, tone: .yellow),
            Share(id: "Failed", count: failed, tone: .red)
        ].filter { $0.count > 0 }

        let latencyShares = latencyHistogram(document.latencySamples.compactMap(\.releaseToTextMs))

        let usage = [
            ASRModelKind.parakeet110M.preferenceValue: lifetime.backends.parakeet110M,
            ASRModelKind.parakeetUnified.preferenceValue: lifetime.backends.parakeetUnified
        ]

        let average = lifetime.attemptCount > 0 ? lifetime.wordCount / lifetime.attemptCount : 0

        return SettingsInsights(
            days: days,
            streakDays: streak,
            outcomes: outcomeShares,
            latency: latencyShares,
            modelUsage: usage,
            averageWordsPerDictation: average
        )
    }

    static func latencyHistogram(_ values: [Double]) -> [Share] {
        let buckets: [(label: String, upperMs: Double, tone: Tone)] = [
            ("< 0.3 s", 300, .green),
            ("0.3–0.6 s", 600, .green),
            ("0.6–1 s", 1_000, .teal),
            ("1–2 s", 2_000, .yellow),
            ("2–5 s", 5_000, .orange),
            ("5 s +", .infinity, .red)
        ]
        var counts = Array(repeating: 0, count: buckets.count)
        for value in values where value.isFinite {
            let index = buckets.firstIndex { value < $0.upperMs } ?? buckets.count - 1
            counts[index] += 1
        }
        return zip(buckets, counts).map { Share(id: $0.label, count: $1, tone: $0.tone) }
    }

    /// Daily bucket key (`yyyy-MM-dd` in `calendar`), shared with `DiagnosticsStore`.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
