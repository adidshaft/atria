import XCTest
@testable import Atria

/// The monthly report had no tests and, until 2026-09-02, no surface. These
/// pin its honesty gate and its arithmetic, and that the surface exists.
final class AtriaMonthlyReportTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    // 2026-08-20 12:00 UTC — twenty days into August.
    private let now = Date(timeIntervalSince1970: 1_787_313_600)

    private func entry(daysAgo: Int, recovery: Int? = nil, strain: Double? = nil,
                       sleepSeconds: TimeInterval? = nil, rhr: Int? = nil) -> DailyRollupStoreEntry {
        let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
        return DailyRollupStoreEntry(day: day, tzOffsetMinutes: 0, recovery: recovery, rhr: rhr,
                                     sleepSeconds: sleepSeconds, strain: strain)
    }

    func testFewerThanFourteenDaysWithholdsEveryStat() {
        let rollups = (0..<13).map { entry(daysAgo: $0, recovery: 60, strain: 9) }
        let report = MonthlyReport(rollups: rollups, now: now, calendar: calendar)
        XCTAssertTrue(report.isBuilding)
        XCTAssertEqual(report.daysWithData, 13)
        XCTAssertNil(report.recoveryAvg)
        XCTAssertNil(report.totalStrain)
        XCTAssertNil(report.hardestWeek)
        XCTAssertNil(report.consistencyScore)
    }

    func testAveragesTotalsAndPriorMonthDeltas() {
        // Aug 1–20: recovery 70, strain 8; July 1–20: recovery 60.
        var rollups = (0..<20).map { entry(daysAgo: $0, recovery: 70, strain: 8, rhr: 52) }
        rollups += (31..<51).map { entry(daysAgo: $0, recovery: 60, strain: 4, rhr: 55) }
        let report = MonthlyReport(rollups: rollups, now: now, calendar: calendar)
        XCTAssertFalse(report.isBuilding)
        XCTAssertEqual(report.recoveryAvg, 70)
        XCTAssertEqual(report.recoveryDeltaVsPriorMonth, 10)
        XCTAssertEqual(report.rhrAvg, 52)
        XCTAssertEqual(report.rhrDeltaVsPriorMonth, -3)
        XCTAssertEqual(report.totalStrain ?? 0, 160, accuracy: 0.001)
        XCTAssertNotNil(report.hardestWeek)
        XCTAssertNil(report.consistencyScore, "no qualified sleep nights → no fabricated schedule score")
    }

    func testMonthlyReportIsReachableFromTheWeeklySheet() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let overview = try String(contentsOf: appDirectory.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(overview.contains("struct AtriaMonthlyReportSheet: View"))
        XCTAssertTrue(overview.contains("AtriaMonthlyReportSheet(rollups: rollups, sleepNights: sleepNights)"),
                      "the weekly sheet must present the monthly report")
        XCTAssertTrue(overview.contains("Building this month's picture"),
                      "below the honesty gate the hero must say it is building")
        let today = try String(contentsOf: appDirectory.appendingPathComponent("AtriaTodayScreen.swift"),
                               encoding: .utf8)
        XCTAssertTrue(today.contains("sleepNights: sessionProjectionStore.state.sleepHistorySnapshot.nights"),
                      "consistency needs the qualified sleep windows, not bedtime-only rollups")
    }
}
