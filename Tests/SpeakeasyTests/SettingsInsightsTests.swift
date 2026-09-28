import XCTest
@testable import Speakeasy

final class SettingsInsightsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func stats(words: Int, attempts: Int) -> AggregateStats {
        var stats = AggregateStats()
        stats.wordCount = words
        stats.attemptCount = attempts
        return stats
    }

    func testDaysCoverFourteenDaysEndingTodayWithStreak() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10)))
        let document = DiagnosticsDocument(dailyBuckets: [
            DailyStats(day: "2026-09-26", aggregate: stats(words: 40, attempts: 2)),
            DailyStats(day: "2026-09-27", aggregate: stats(words: 90, attempts: 3)),
            DailyStats(day: "2026-09-28", aggregate: stats(words: 10, attempts: 1)),
            DailyStats(day: "2026-09-01", aggregate: stats(words: 500, attempts: 9))
        ])
        let insights = SettingsInsights.make(document: document, now: now, calendar: calendar)
        XCTAssertEqual(insights.days.count, 14)
        XCTAssertEqual(insights.days.last?.id, "2026-09-28")
        XCTAssertEqual(insights.days.last?.isToday, true)
        XCTAssertEqual(insights.days.first?.id, "2026-09-15")
        XCTAssertEqual(insights.chartWordsTotal, 140)
        XCTAssertEqual(insights.bestDay?.id, "2026-09-27")
        XCTAssertEqual(insights.streakDays, 3)
    }

    func testStreakCountsFromYesterdayWhenTodayIsEmpty() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)))
        let document = DiagnosticsDocument(dailyBuckets: [
            DailyStats(day: "2026-09-27", aggregate: stats(words: 5, attempts: 1))
        ])
        XCTAssertEqual(SettingsInsights.make(document: document, now: now, calendar: calendar).streakDays, 1)
    }

    func testLatencyHistogramAndOutcomes() {
        let histogram = SettingsInsights.latencyHistogram([100, 450, 700, 1_500, 3_000, 9_000, 200])
        XCTAssertEqual(histogram.map(\.count), [2, 1, 1, 1, 1, 1])

        var lifetime = AggregateStats()
        lifetime.outcomes.eventsPosted = 7
        lifetime.outcomes.timedOut = 1
        lifetime.outcomes.transcriptionFailed = 2
        let insights = SettingsInsights.make(document: DiagnosticsDocument(lifetime: lifetime), now: Date())
        XCTAssertEqual(insights.outcomes.map(\.id), ["Pasted", "Failed"])
        XCTAssertEqual(insights.outcomes.map(\.count), [7, 3])
    }

    func testLevelSamplerIgnoresStaleSnapshots() {
        var sampler = LiveLevelSampler()
        let stale = MicrophoneLevelSnapshot(normalizedLevel: 0.5, sequence: 42)
        _ = sampler.next(stale)
        _ = sampler.next(stale)
        XCTAssertFalse(sampler.isLive)
        var level: Float = 0
        for sequence in 43...52 {
            level = sampler.next(MicrophoneLevelSnapshot(normalizedLevel: 0.2, sequence: UInt64(sequence)))
        }
        XCTAssertTrue(sampler.isLive)
        XCTAssertGreaterThan(level, 0.1)
        for _ in 0..<LiveLevelSampler.idleAfterTicks { _ = sampler.next(MicrophoneLevelSnapshot(normalizedLevel: 0.2, sequence: 52)) }
        XCTAssertFalse(sampler.isLive)
    }
}
