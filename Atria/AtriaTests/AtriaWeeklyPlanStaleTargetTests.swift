import XCTest
@testable import Atria

/// Device 2026-09-02 (W36): the saved weekly plan said "Lights out by
/// 1:21 AM" for an afternoon sleeper, minted by the old noon-cut median
/// before the clock fix, and the store kept it for the week because only
/// learning targets were re-minted mid-week. A saved bedtime target with no
/// stored minute, or more than three hours from the fresh answer on the
/// clock, is a defect rather than a commitment and yields to the fresh one.
final class AtriaWeeklyPlanStaleTargetTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_787_832_000)   // Thu 2026-08-27 12:00 UTC

    private func entry(daysAgo: Int, bedtimeMinutes: Int?) -> DailyRollupStoreEntry {
        DailyRollupStoreEntry(day: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!),
                              tzOffsetMinutes: 0,
                              bedtimeMinutes: bedtimeMinutes)
    }

    /// Five afternoon bedtimes around 13:15–13:40.
    private var afternoonRollups: [DailyRollupStoreEntry] {
        [795, 810, 800, 820, 805].enumerated().map { entry(daysAgo: $0.offset + 1, bedtimeMinutes: $0.element) }
    }

    private func legacyBedtimeTarget(minute: Int?) -> WeeklyPlanTarget {
        WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue,
                         kind: .bedtimeConsistency,
                         title: "Lights out by 1:21 AM · 4 nights",
                         detail: "Based on your recent bedtime rhythm",
                         goal: 4, current: 1,
                         targetMinute: minute)
    }

    func testFreshBedtimeTargetStoresItsMinute() throws {
        let fresh = try XCTUnwrap(WeeklyPlan.generate(from: afternoonRollups, now: now, calendar: calendar)
            .first { $0.kind == .bedtimeConsistency })
        XCTAssertFalse(fresh.isLearning)
        XCTAssertNotNil(fresh.targetMinute)
        XCTAssertTrue(fresh.title.contains("PM"), "an afternoon sleeper's target lands in the afternoon: \(fresh.title)")
    }

    func testStaleRuleFlagsMissingMinuteAndFarClockDistanceOnly() throws {
        let fresh = try XCTUnwrap(WeeklyPlan.generate(from: afternoonRollups, now: now, calendar: calendar)
            .first { $0.kind == .bedtimeConsistency })
        XCTAssertTrue(WeeklyPlan.savedBedtimeTargetIsStale(legacyBedtimeTarget(minute: nil), fresh: fresh),
                      "no stored minute means the old arithmetic minted it")
        XCTAssertTrue(WeeklyPlan.savedBedtimeTargetIsStale(legacyBedtimeTarget(minute: 81), fresh: fresh),
                      "1:21 AM is far from an afternoon target on the clock")
        let nearby = legacyBedtimeTarget(minute: (fresh.targetMinute ?? 0) + 40)
        XCTAssertFalse(WeeklyPlan.savedBedtimeTargetIsStale(nearby, fresh: fresh),
                       "a target within three hours is a commitment for the week and stays")
    }

    func testStoreReMintsALegacyBedtimeTargetMidWeek() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-stale-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Persist a real plan, then rewrite its bedtime target on disk the way
        // the pre-fix build did: the old title and no stored minute.
        let writer = WeeklyPlanStore(directory: directory)
        _ = writer.currentPlan(rollups: afternoonRollups, now: now, calendar: calendar)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let file = directory.appendingPathComponent("weekly-plan-\(components.yearForWeekOfYear!)-W\(components.weekOfYear!).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
        for index in targets.indices where (targets[index]["kind"] as? String) == WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue {
            targets[index]["title"] = "Lights out by 1:21 AM · 4 nights"
            targets[index].removeValue(forKey: "targetMinute")
        }
        json["targets"] = targets
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let reader = WeeklyPlanStore(directory: directory)
        let plan = reader.currentPlan(rollups: afternoonRollups, now: now, calendar: calendar)
        let bedtime = try XCTUnwrap(plan.targets.first { $0.kind == .bedtimeConsistency })
        XCTAssertNotEqual(bedtime.title, "Lights out by 1:21 AM · 4 nights", "the stale target is re-minted")
        XCTAssertNotNil(bedtime.targetMinute)
        XCTAssertTrue(bedtime.title.contains("PM"))
    }
}
