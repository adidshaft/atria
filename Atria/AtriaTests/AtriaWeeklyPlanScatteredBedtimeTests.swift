import XCTest
@testable import Atria

/// Device 2026-09-02: 24 recorded bedtimes over 28 nights, split between an
/// afternoon cluster and a pre-dawn one, minted "Lights out by 6:35 AM";
/// only three of them sat within ninety minutes of that median. A bedtime
/// target needs a rhythm to name a time from, so a scattered set yields a
/// withheld target that renders as Learning, and a saved time gives way to
/// it mid-week.
final class AtriaWeeklyPlanScatteredBedtimeTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_787_832_000)   // Thu 2026-08-27 12:00 UTC

    private func rollups(_ bedtimes: [Int]) -> [DailyRollupStoreEntry] {
        bedtimes.enumerated().map { offset, minute in
            DailyRollupStoreEntry(day: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(offset + 1), to: now)!),
                                  tzOffsetMinutes: 0,
                                  bedtimeMinutes: minute)
        }
    }

    /// The phone's 24 bedtimes as minutes of the day.
    private let scattered = [14, 19, 53, 61, 183, 203, 210, 225, 267, 277, 290, 375,
                             429, 607, 688, 795, 808, 845, 871, 896, 902, 910, 928, 938]

    private func bedtime(_ entries: [DailyRollupStoreEntry]) throws -> WeeklyPlanTarget {
        try XCTUnwrap(WeeklyPlan.generate(from: entries, now: now, calendar: calendar)
            .first { $0.kind == .bedtimeConsistency })
    }

    func testScatteredBedtimesWithholdTheTarget() throws {
        let target = try bedtime(rollups(scattered))
        XCTAssertTrue(target.isWithheld)
        XCTAssertFalse(target.isLearning)
        XCTAssertNil(target.targetMinute)
        XCTAssertFalse(target.title.contains("Lights out by"), target.title)
        XCTAssertEqual(target.detail, "No steady bedtime in the last 28 nights")
    }

    func testAClusteredMajorityStillMintsATime() throws {
        // Seven afternoon nights and three pre-dawn ones: the cluster holds.
        let target = try bedtime(rollups([795, 810, 800, 820, 805, 830, 815, 183, 277, 290]))
        XCTAssertFalse(target.isWithheld)
        XCTAssertNotNil(target.targetMinute)
        XCTAssertTrue(target.title.contains("PM"), target.title)
    }

    func testWithheldSortsAfterActionableTargets() {
        let plan = WeeklyPlan.generate(from: rollups(scattered), now: now, calendar: calendar)
        let bedtimeIndex = plan.firstIndex { $0.kind == .bedtimeConsistency }
        let actionable = plan.indices.filter { !plan[$0].isLearning && !plan[$0].isWithheld }
        for index in actionable { XCTAssertLessThan(index, bedtimeIndex ?? Int.max) }
    }

    func testASavedTimeYieldsToAWithheldFreshAnswer() throws {
        let fresh = try bedtime(rollups(scattered))
        let saved = WeeklyPlanTarget(id: WeeklyPlanTarget.Kind.bedtimeConsistency.rawValue,
                                     kind: .bedtimeConsistency,
                                     title: "Lights out by 6:35 AM · 4 nights",
                                     detail: "Based on your recent bedtime rhythm",
                                     goal: 4, current: 1, targetMinute: 395)
        XCTAssertTrue(WeeklyPlan.savedBedtimeTargetIsStale(saved, fresh: fresh))
    }

    func testStoreReplacesASavedTimeWhenTheWeekScatters() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-scattered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = WeeklyPlanStore(directory: directory)
        let minted = writer.currentPlan(rollups: rollups([795, 810, 800, 820, 805]), now: now, calendar: calendar)
        XCTAssertNotNil(minted.targets.first { $0.kind == .bedtimeConsistency }?.targetMinute)
        let reader = WeeklyPlanStore(directory: directory)
        let plan = reader.currentPlan(rollups: rollups(scattered), now: now, calendar: calendar)
        let target = try XCTUnwrap(plan.targets.first { $0.kind == .bedtimeConsistency })
        XCTAssertTrue(target.isWithheld, "the saved time is re-minted as withheld")
    }

    func testWithheldTargetDecodesFromAPlanSavedWithoutTheField() throws {
        let json = """
        {"id":"bedtimeConsistency","kind":"bedtimeConsistency","title":"Lights out by 6:35 AM · 4 nights",
         "detail":"Based on your recent bedtime rhythm","goal":4,"current":1,"targetMinute":395}
        """
        let target = try JSONDecoder().decode(WeeklyPlanTarget.self, from: Data(json.utf8))
        XCTAssertFalse(target.isWithheld)
    }

    func testTodayRowRendersAWithheldTargetAsLearning() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(": target.isWithheld ? \"Learning\" : target.progressText)"))
        XCTAssertTrue(source.contains(": target.isWithheld ? 0 : target.progress) {"), "an empty gauge")
        XCTAssertTrue(source.contains(": target.isWithheld ? \"\\(target.title). Learning. \\(target.detail).\""))
    }
}
