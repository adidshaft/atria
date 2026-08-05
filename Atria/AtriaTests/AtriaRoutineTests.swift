import Combine
import XCTest
@testable import Atria

/// Coverage for the v1 Routine/streak card (gap spec d): per-day checkmark
/// derivation from `DailyRollupStoreEntry` + `BehaviorJournalEntry`, and the
/// streak-counting math, both pure and independent of any live store.
final class AtriaRoutineTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDown() {
        calendar = nil
        super.tearDown()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func rollup(day: Date, bedtimeMinutes: Int? = nil, strain: Double? = nil) -> DailyRollupStoreEntry {
        DailyRollupStoreEntry(day: day, bedtimeMinutes: bedtimeMinutes, strain: strain, calendar: calendar)
    }

    private func journalEntry(day: Date, tags: [BehaviorJournalEntry.Tag]) -> BehaviorJournalEntry {
        BehaviorJournalEntry(id: UUID().uuidString, day: day, createdAt: day, tags: tags)
    }

    /// Monday...Wednesday of the ISO week containing an arbitrary anchor date,
    /// derived the same way the production code derives "this week" -- so the
    /// test never has to hardcode which literal calendar date is a Monday.
    private func mondayThroughWednesday(anchoredNear anchor: Date) -> (monday: Date, tuesday: Date, wednesday: Date) {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)!.start
        let tuesday = calendar.date(byAdding: .day, value: 1, to: weekStart)!
        let wednesday = calendar.date(byAdding: .day, value: 2, to: weekStart)!
        return (weekStart, tuesday, wednesday)
    }

    func testRoutinePerDayCheckmarksFromRollups() {
        let (monday, tuesday, wednesday) = mondayThroughWednesday(anchoredNear: date(2026, 6, 24))

        // 28 days of a stable ~10:00 PM bedtime (target becomes ~10:20 PM
        // after the +20 minute grace), then explicit good/bad days for the
        // visible week. "Today" (Wednesday) has no rollup at all yet.
        var history: [DailyRollupStoreEntry] = []
        for offset in 3...30 {
            let day = calendar.date(byAdding: .day, value: -offset, to: wednesday)!
            history.append(rollup(day: day, bedtimeMinutes: 22 * 60, strain: 4))
        }
        history.append(rollup(day: monday, bedtimeMinutes: 22 * 60, strain: 12)) // on time, >=10 strain
        history.append(rollup(day: tuesday, bedtimeMinutes: 23 * 60 + 45, strain: 3)) // late, low strain
        // Wednesday: no entry at all.

        let summary = AtriaRoutineComputer.summary(rollups: history,
                                                    journalEntries: [],
                                                    now: wednesday,
                                                    calendar: calendar)

        let bedtime = summary.targets.first { $0.kind == .bedtime }!
        XCTAssertEqual(bedtime.week[0].state, .kept, "Monday bedtime was on time")
        XCTAssertEqual(bedtime.week[1].state, .missed, "Tuesday bedtime was late")
        XCTAssertEqual(bedtime.week[2].state, .noData, "Wednesday has no rollup yet -- honestly unknown, not missed")
        XCTAssertEqual(bedtime.week[3].state, .upcoming, "Thursday hasn't happened yet")

        let workout = summary.targets.first { $0.kind == .workout }!
        XCTAssertEqual(workout.week[0].state, .kept, "Monday strain 12 >= 10")
        XCTAssertEqual(workout.week[1].state, .missed, "Tuesday strain 3 < 10")
        XCTAssertEqual(workout.week[2].state, .noData, "Wednesday has no rollup yet")
    }

    func testRoutineJournalDayCreditedFromBehaviorEntries() {
        let (monday, tuesday, wednesday) = mondayThroughWednesday(anchoredNear: date(2026, 6, 24))

        let entries = [
            journalEntry(day: monday, tags: [.sleep, .training]),
            journalEntry(day: tuesday, tags: []) // empty entry: not a real log
        ]

        let summary = AtriaRoutineComputer.summary(rollups: [],
                                                    journalEntries: entries,
                                                    now: wednesday,
                                                    calendar: calendar)

        let journal = summary.targets.first { $0.kind == .journal }!
        XCTAssertEqual(journal.week[0].state, .kept, "Monday has a tagged entry")
        XCTAssertEqual(journal.week[1].state, .missed, "Tuesday's entry has no tags -- not credited")
    }

    func testRoutineStreakCountsConsecutiveKeptDays() {
        let states: [AtriaRoutineDayState] = [.missed, .kept, .kept, .kept]
        XCTAssertEqual(AtriaRoutineComputer.currentStreak(states), 3)
    }

    func testRoutineStreakResetsOnMissedDay() {
        XCTAssertEqual(AtriaRoutineComputer.currentStreak([.kept, .kept, .missed, .kept]), 1)
        XCTAssertEqual(AtriaRoutineComputer.currentStreak([.kept, .kept, .noData, .kept, .kept]), 2)
        // Upcoming (future) days don't count as a break -- they haven't happened.
        XCTAssertEqual(AtriaRoutineComputer.currentStreak([.kept, .kept, .upcoming, .upcoming]), 2)
    }
}

@MainActor
final class AtriaRoutineProjectionStoreTests: XCTestCase {
    private func summary(hasAnyHistory: Bool = false) -> AtriaRoutineSummary {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let weekStart = calendar.date(
            from: DateComponents(weekOfYear: 28, yearForWeekOfYear: 2026)
        ) ?? Date(timeIntervalSince1970: 0)
        return AtriaRoutineSummary(isoYear: 2026,
                                   isoWeek: 28,
                                   weekStart: weekStart,
                                   targets: [],
                                   hasAnyHistory: hasAnyHistory)
    }

    func testEqualSummaryRefreshDoesNotPublish() {
        let initial = summary()
        let projection = AtriaRoutineProjectionStore(summary: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testChangedSummaryPublishesExactlyOnce() {
        let projection = AtriaRoutineProjectionStore(summary: summary())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refresh(summary(hasAnyHistory: true)))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testUnrelatedSessionStoreSignalDoesNotPublishRoutineSummary() {
        let sessionStore = SessionStore()
        let projection = AtriaRoutineProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        sessionStore.objectWillChange.send()

        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testJournalRevisionImmediatelyRefreshesJournalRoutineState() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 8))!
        let initial = AtriaRoutineComputer.summary(rollups: [],
                                                   journalEntries: [],
                                                   now: now,
                                                   calendar: calendar)
        let projection = AtriaRoutineProjectionStore(summary: initial)
        let entry = BehaviorJournalEntry(id: "routine-projection-journal",
                                         day: now,
                                         createdAt: now,
                                         tags: [.sleep])
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refreshForJournalRevision(1,
                                                           rollups: [],
                                                           journalEntries: [entry],
                                                           now: now))
        let journal = projection.summary.targets.first { $0.kind == .journal }
        XCTAssertEqual(journal?.week[2].state, .kept)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(projection.refreshForJournalRevision(1,
                                                            rollups: [],
                                                            journalEntries: [],
                                                            now: now),
                       "The same revision must not recompute or publish")
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testRoutineCardUsesNarrowProjectionAndJournalRevisionGate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaRoutineCard.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(source.contains("@StateObject private var projectionStore: AtriaRoutineProjectionStore"))
        XCTAssertTrue(source.contains("store.$dailyRollupHistory"))
        XCTAssertTrue(source.contains("store.$dashboardRevision"))
        XCTAssertTrue(source.contains("refreshForJournalRevision(store.behaviorJournalRevision"))
        XCTAssertTrue(source.contains("NotificationCenter.default.publisher(for: .NSCalendarDayChanged)"))
    }
}

// 2026-08-06: audit fix — dead twin deleted. AtriaPlanProjectionStoreTests
// covered AtriaPlanTab/AtriaPlanProjectionStore, the unmounted legacy Plan tab
// root removed with its file (the .plan slot mounts AtriaActivityMonitorTab).
