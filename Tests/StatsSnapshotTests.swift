import Foundation

@main
struct StatsSnapshotTests {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
            preconditionFailure("Expected compiled production catalog fixture bundle")
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "America/Los_Angeles") else {
            preconditionFailure("Missing test time zone")
        }
        calendar.timeZone = timeZone
        func date(_ day: Int, month: Int = 9) -> Date {
            guard let value = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)) else {
                preconditionFailure("Invalid test date")
            }
            return value
        }
        func entry(_ day: Int, text: String, app: String = "Notes", ai: Bool = false, month: Int = 9) -> TranscriptionHistoryEntry {
            TranscriptionHistoryEntry(
                timestamp: date(day, month: month),
                rawText: "raw must not count",
                processedText: text,
                appName: app,
                windowTitle: "",
                wasAIProcessed: ai
            )
        }
        let entries = [
            entry(7, text: "one  two\nthree", ai: true),
            entry(7, text: "four", app: ""),
            entry(6, text: "five six"),
            entry(4, text: "seven"),
            entry(3, text: "eight"),
        ]
        let startingGoal = StatsDailyMilestone(words: 0)
        precondition(startingGoal.nextTarget == 100 && startingGoal.reachedTarget == nil && startingGoal.progress == 0)
        let approachingGoal = StatsDailyMilestone(words: 288)
        precondition(approachingGoal.nextTarget == 500 && approachingGoal.remaining == 212 && approachingGoal.reachedTarget == 250)
        let reachedGoal = StatsDailyMilestone(words: 500)
        precondition(reachedGoal.reachedTarget == 500 && reachedGoal.nextTarget == 1000 && reachedGoal.progress == 0.5)
        let completedGoal = StatsDailyMilestone(words: 50_000)
        precondition(completedGoal.nextTarget == nil && completedGoal.remaining == 0 && completedGoal.progress == 1)
        precondition(StatsDailyMilestone(words: 0).reachedTarget == nil, "A new day must not retain yesterday's achievement")
        let original = entries
        let snapshot = try StatsSnapshot.build(entries: entries, now: date(7), calendar: calendar)
        precondition(entries == original, "Summary must not mutate history")
        precondition(snapshot.totalWords == 8 && snapshot.totalTranscriptions == 5)
        precondition(snapshot.averageWordsPerTranscription == 1 && snapshot.aiEnhancementRate == 20)
        precondition(snapshot.currentStreak == 2 && snapshot.bestStreak == 2)
        precondition(snapshot.usingWeekdays(true).currentStreak == 3 && snapshot.usingWeekdays(true).bestStreak == 3)
        precondition(snapshot.currentStreak == 2, "Settings projection must not alter cached summary")
        precondition(snapshot.longestTranscriptionWords == 3 && snapshot.mostWordsInDay == 4 && snapshot.mostTranscriptionsInDay == 2)
        precondition(snapshot.dailyWordCounts(days: 7).count == 7 && snapshot.activity.count == 180)
        precondition(snapshot.activity.last?.words == 4 && snapshot.activity.reduce(0) { $0 + $1.words } == 8)
        precondition(snapshot.topAppsFormatted(limit: 3) == ["Notes", "Unknown"])
        precondition(snapshot.topAppUsage.map(\.sessions) == [4, 1])
        precondition(snapshot.hourlySessions.count == 24 && snapshot.hourlySessions[12] == 5)
        precondition(snapshot.hourlySessions.reduce(0, +) == snapshot.totalTranscriptions)
        let manyApps = try StatsSnapshot.build(entries: (0..<8).map { entry(7, text: "word", app: "App \($0)") }, now: date(7), calendar: calendar)
        precondition(manyApps.topAppUsage.count == 5 && manyApps.totalTranscriptions == 8, "Top apps stay bounded; percentages use all sessions")
        precondition(manyApps.topAppUsage.map(\.name) == ["App 0", "App 1", "App 2", "App 3", "App 4"], "Ties remain deterministic")
        precondition(snapshot.timeSavedMinutes(typingWPM: 0) == 0)
        precondition(snapshot.timeSavedMinutes(typingWPM: 200) == 0)
        precondition(abs(snapshot.timeSavedMinutes(typingWPM: 40) - (8.0 / 40 - 8.0 / 150)) < 0.000001)
        precondition(PichiLocalization.formattedTimeSaved(minutes: snapshot.timeSavedMinutes(typingWPM: 0), language: .english, bundle: bundle) == "< 1 min")
        precondition(PichiLocalization.formattedTimeSaved(minutes: snapshot.timeSavedMinutes(typingWPM: 200), language: .english, bundle: bundle) == "< 1 min")
        let empty = try StatsSnapshot.build(entries: [], now: date(7), calendar: calendar)
        precondition(empty.totalWords == 0 && empty.currentStreak == 0 && empty.bestStreak == 0 && empty.peakHourFormatted == "N/A")
        precondition(empty.topAppUsage.isEmpty && empty.hourlySessions == Array(repeating: 0, count: 24))
        precondition(empty.totalMilestonesAchieved == 0 && empty.totalMilestonesPossible == 18)
        for count in [30, 60, 90, 180] {
            let period = StatsActivityPeriod(activity: snapshot.dailyWordCounts(days: count), calendar: calendar)
            precondition(period.days.count == count && period.totalWords == 8 && period.activeDays == 4)
            precondition(period.days.last?.cumulativeWords == 8)
            precondition(period.weeks.flatMap { $0 }.compactMap { $0 }.count == count, "Padding must not duplicate days")
            for week in period.weeks {
                precondition(week.count == 7)
                for (row, day) in week.enumerated() {
                    if let day {
                        precondition((calendar.component(.weekday, from: day.date) - calendar.firstWeekday + 7) % 7 == row)
                    }
                }
            }
        }
        let emptyPeriod = StatsActivityPeriod(activity: empty.activity, calendar: calendar)
        precondition(emptyPeriod.totalWords == 0 && emptyPeriod.strongestWeekday == nil)
        let shortPeriod = StatsActivityPeriod(activity: snapshot.dailyWordCounts(days: 7), calendar: calendar)
        precondition(shortPeriod.weekdays.first { $0.id == 1 }?.averageWords == 4, "Monday average uses every Monday in range")
        precondition(snapshot.dailyWordCounts(days: 0).isEmpty && snapshot.dailyWordCounts(days: 999).count == 180)
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let mondayPeriod = StatsActivityPeriod(activity: snapshot.activity, calendar: mondayCalendar)
        precondition(mondayPeriod.weekdays.first?.id == 1)
        let russianUnits = [0: "дней подряд", 1: "день подряд", 2: "дня подряд", 5: "дней подряд", 11: "дней подряд", 21: "день подряд", 22: "дня подряд"]
        for (count, expected) in russianUnits {
            precondition(PichiLocalization.formattedStreakUnit(days: count, language: .russian, bundle: bundle) == expected)
            precondition(PichiLocalization.formattedStreakUnit(days: count, language: .english, bundle: bundle) == (count == 1 ? "day streak" : "days in a row"))
        }
        let french = PichiInterfaceLanguage(rawValue: "fr")!
        precondition(bundle.localizations.contains("fr"))
        precondition(PichiLocalization.formattedStreakUnit(days: 2, language: french, bundle: bundle) == "days in a row", "Missing partial-language unit must use English quantity rules")
        precondition(PichiLocalization.formattedStreakUnit(days: 0, language: french, bundle: bundle) == "days in a row", "French zero is singular, but an English fallback must retain its own plural rule")
        let emptyBundle = Bundle(path: bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("EmptyCatalog.bundle").path)!
        precondition(PichiLocalization.formattedStreakUnit(days: 2, language: .russian, bundle: emptyBundle) == "day streak", "Missing source resource must not expose a key or repeat the prominent number")
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "ru")] {
            for firstWeekday in [1, 2] {
                var injected = calendar
                injected.locale = locale
                injected.firstWeekday = firstWeekday
                for dates in [
                    [DateComponents(year: 2026, month: 10, day: 12), DateComponents(year: 2026, month: 10, day: 13)],
                    [DateComponents(year: 2026, month: 10, day: 31), DateComponents(year: 2026, month: 11, day: 1)],
                    [DateComponents(year: 2026, month: 12, day: 31), DateComponents(year: 2027, month: 1, day: 1)],
                ] {
                    let activity = dates.enumerated().map { (injected.date(from: $0.element)!, $0.offset == 0 ? 210 : 69) }
                    let period = StatsActivityPeriod(activity: activity, calendar: injected)
                    let heatmap = StatsHeatmapView(period: period)
                    precondition(heatmap.weekdayLabels == period.weekdays.map(\.label))
                    for week in period.weeks {
                        for (row, day) in week.enumerated() {
                            guard let day else { continue }
                            let weekday = injected.component(.weekday, from: day.date)
                            precondition(heatmap.weekdayLabels[row] == injected.shortWeekdaySymbols[weekday - 1], "Cell and row label must describe the same day")
                        }
                    }
                    precondition(period.totalWords == 279 && period.activeDays == 2)
                    precondition(period.weeks.flatMap { $0 }.compactMap { $0 }.count == 2)
                    for column in period.weeks.indices {
                        let firstOfMonth = period.weeks[column].compactMap { $0 }.first { injected.component(.day, from: $0.date) == 1 }
                        let expected = firstOfMonth.map { injected.shortMonthSymbols[injected.component(.month, from: $0.date) - 1] } ?? ""
                        precondition(period.monthLabel(for: column) == expected)
                    }
                    precondition(period.monthLabel(for: -1).isEmpty && period.monthLabel(for: period.weeks.count).isEmpty)
                }
            }
        }
        var west = calendar
        west.locale = Locale(identifier: "en_US")
        let nearMidnightUTC = ISO8601DateFormatter().date(from: "2027-01-01T00:30:00Z")!
        let day = StatsActivityPeriod.Day(date: nearMidnightUTC, words: 2, cumulativeWords: 2)
        let labels = StatsHeatmapView.dayLabels(for: day, calendar: west, bundle: bundle)
        precondition(labels.shortDate.contains("Dec") && labels.shortDate.contains("31"))
        precondition(labels.accessible.contains("December 31, 2026") && labels.words == "2 words", "Tooltip must keep its injected time zone instead of UTC")
        var utc = west
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcLabels = StatsHeatmapView.dayLabels(for: day, calendar: utc, bundle: bundle)
        precondition(utcLabels.shortDate.contains("Jan") && utcLabels.shortDate.contains("1"))
        precondition(utcLabels.accessible.contains("January 1, 2027") && utcLabels.words == "2 words")
        print("PASS: compiled native streak units, partial-language fallback, real Heatmap label consumption, Sun/Mon week starts, month/year bounds and time-zone labels")
        let oldHistory = try StatsSnapshot.build(entries: [entry(1, text: "old words", month: 1)] + entries, now: date(7), calendar: calendar)
        precondition(oldHistory.totalWords == 10 && oldHistory.dailyWordCounts(days: 180).reduce(0) { $0 + $1.words } == 8,
                     "Range truncation must not alter lifetime totals")
        let stale = try StatsSnapshot.build(entries: entries, now: date(10), calendar: calendar)
        precondition(stale.currentStreak == 0 && stale.weekdayCurrentStreak == 0 && stale.bestStreak == 2)
        let weekend = try StatsSnapshot.build(entries: [entry(3, text: "x"), entry(4, text: "x"), entry(6, text: "x")], now: date(6), calendar: calendar)
        precondition(weekend.weekdayCurrentStreak == 2 && weekend.weekdayBestStreak == 2)
        let dst = try StatsSnapshot.build(
            entries: [entry(7, text: "a", month: 3), entry(8, text: "b", month: 3), entry(9, text: "c", month: 3)],
            now: date(9, month: 3),
            calendar: calendar
        )
        precondition(dst.currentStreak == 3 && dst.bestStreak == 3, "Streaks must use calendar days across DST")
        let large = Array(repeating: entry(7, text: String(repeating: "word ", count: 100)), count: 9000)
        let start = Date()
        let big = try StatsSnapshot.build(entries: large, now: date(7), calendar: calendar)
        precondition(big.totalWords == 900_000 && big.longestTranscriptionWords == 100 && big.activity.count == 180)
        print("9,000-entry / 900,000-word summary: \(Int(Date().timeIntervalSince(start) * 1000)) ms off-main workload")
        let cancelled = Task.detached {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try StatsSnapshot.build(entries: large, now: Date(), calendar: Calendar.current)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled worker must not return a snapshot") } catch is CancellationError {}
        try await self.testStore(entries: entries)
        print("PASS: totals, records, chart bounds, immutable input, settings projection, empty, stale, weekends, DST, large history and cancellation")
    }

    @MainActor
    static func testStore(entries: [TranscriptionHistoryEntry]) async throws {
        let history = TranscriptionHistoryStore()
        let store = StatsSnapshotStore(history: history)
        let first = UUID()
        let second = UUID()
        history.entries = entries
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(store.snapshot == nil && !store.isUpdating, "Hidden Stats must not aggregate")
        store.activate(first)
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 8 && !store.isUpdating)
        store.deactivate(first)
        store.activate(first)
        precondition(!store.isUpdating, "Reopening unchanged Stats must use the cache")
        history.entries = Array(repeating: entries[0], count: 1000)
        history.entries = [entries[1]]
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 1, "Only newest publisher value may win")
        store.activate(second)
        store.deactivate(first)
        history.entries = entries
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 8, "One window closing must not cancel another")
        history.entries = Array(repeating: entries[0], count: 1000)
        store.deactivate(second)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!store.isUpdating && store.snapshot?.totalWords == 8, "Hidden cancelled work cannot publish")
        history.entries = []
        precondition(store.snapshot == nil, "Reset must discard old totals immediately")
        store.activate(first)
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 0 && store.snapshot?.totalTranscriptions == 0)
        precondition(history.entries.isEmpty, "Stats must never write to history")
        store.deactivate(first)
        print("PASS: hidden inactivity, cache reuse, rapid replacement, multiple windows, cancellation, reset and no history writes")
    }
}
