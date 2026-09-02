import XCTest
@testable import Atria

/// The weekly bedtime target must be a real rhythm on the 24h clock — never
/// a fabricated 23:00, and never a noon cut that puts an afternoon sleeper's
/// 11:28 and 12:08 a day apart.
final class AtriaWeeklyPlanBedtimeTargetTests: XCTestCase {
    // Mirrors the plan's private ISO calendar (Monday weeks, fixed zone).
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_787_832_000)   // Thu 2026-08-27 12:00 UTC, three days into the ISO week

    private func entry(daysAgo: Int, bedtimeMinutes: Int?) -> DailyRollupStoreEntry {
        DailyRollupStoreEntry(day: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!),
                              tzOffsetMinutes: 0,
                              bedtimeMinutes: bedtimeMinutes)
    }

    private func bedtimeTarget(_ rollups: [DailyRollupStoreEntry]) throws -> WeeklyPlanTarget {
        try XCTUnwrap(WeeklyPlan.generate(from: rollups, now: now, calendar: calendar)
            .first { $0.kind == .bedtimeConsistency })
    }

    func testCircularMedianKeepsAfternoonNightsTogether() {
        // 11:28, 12:08, 13:15, 13:30, 13:50 — the noon cut used to split these.
        XCTAssertEqual(WeeklyPlan.circularMedianMinute([688, 728, 795, 810, 830]), 795)
        // 23:30, 00:20, 23:20, 00:30, 23:00 — straddling midnight stays sane.
        XCTAssertEqual(WeeklyPlan.circularMedianMinute([1410, 20, 1400, 30, 1380]), 1410)
        XCTAssertNil(WeeklyPlan.circularMedianMinute([]))
    }

    func testNoLaterIsMeasuredOnTheClock() {
        XCTAssertTrue(WeeklyPlan.minuteIsNoLater(688, than: 815), "11:28 is earlier than 13:35")
        XCTAssertTrue(WeeklyPlan.minuteIsNoLater(1380, than: 20), "23:00 is earlier than 00:20")
        XCTAssertFalse(WeeklyPlan.minuteIsNoLater(20, than: 1400), "00:20 is later than 23:20")
        XCTAssertTrue(WeeklyPlan.minuteIsNoLater(815, than: 815), "on the minute counts")
    }

    func testFewerThanThreeBedtimesIsALearningTargetNotAFabricatedTime() throws {
        let none = try bedtimeTarget((1...5).map { entry(daysAgo: $0, bedtimeMinutes: nil) })
        XCTAssertTrue(none.isLearning)
        XCTAssertEqual(none.learningNightsRemaining, WeeklyPlan.minimumBedtimeNights)
        XCTAssertFalse(none.title.contains("Lights out by"), "no rhythm, no invented time: \(none.title)")
        XCTAssertEqual(none.current, 0)

        let two = try bedtimeTarget([entry(daysAgo: 8, bedtimeMinutes: 795), entry(daysAgo: 9, bedtimeMinutes: 810)])
        XCTAssertEqual(two.learningNightsRemaining, 1)

        let three = try bedtimeTarget([entry(daysAgo: 8, bedtimeMinutes: 795),
                                       entry(daysAgo: 9, bedtimeMinutes: 810),
                                       entry(daysAgo: 10, bedtimeMinutes: 800)])
        XCTAssertFalse(three.isLearning)
        XCTAssertTrue(three.title.hasPrefix("Lights out by"))
    }

    func testRHRTargetLearnsUntilTheBaselineHasTrustedMornings() throws {
        let targets = WeeklyPlan.generate(from: (1...5).map { entry(daysAgo: $0, bedtimeMinutes: 795) },
                                          now: now, calendar: calendar)
        let rhr = try XCTUnwrap(targets.first { $0.kind == .rhrInRange })
        XCTAssertTrue(rhr.isLearning, "no trusted RHR mornings, no range to keep")
        XCTAssertEqual(rhr.learningNightsRemaining, WeeklyPlan.minimumTrustedRHRDays)
        XCTAssertFalse(rhr.title.contains("Keep RHR in range"))
    }

    func testAfternoonSleeperGetsAnAfternoonTargetAndPreNoonNightsCount() throws {
        // Recent rhythm: 13:15 ± 20 over ten nights, all before this week.
        var rollups = (8...17).map { entry(daysAgo: $0, bedtimeMinutes: 795 + ($0 % 3) * 15) }
        // This week: 11:28, 12:08 and 14:30 — the first two must count.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        XCTAssertGreaterThanOrEqual(Int(now.timeIntervalSince(weekStart) / 86_400), 2,
                                    "the fixed instant must sit at least two days into the ISO week")
        rollups.append(entry(daysAgo: 0, bedtimeMinutes: 688))
        rollups.append(entry(daysAgo: 1, bedtimeMinutes: 728))
        rollups.append(entry(daysAgo: 2, bedtimeMinutes: 870))
        let target = try bedtimeTarget(rollups)

        XCTAssertFalse(target.isLearning)
        XCTAssertTrue(target.title.contains("PM"), "an afternoon rhythm gives an afternoon target: \(target.title)")
        XCTAssertEqual(target.current, 2, "11:28 and 12:08 are earlier than the target; 14:30 is later")
    }
}
