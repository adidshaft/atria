import XCTest
@testable import Atria

/// 2026-09-02: the monthly report's strain row read "Daily strain summed
/// across the month" while its neighbours compared to the prior month. It
/// now compares as a daily average, never total against total, because a
/// partial month's sum cannot be compared to a full one.
final class AtriaMonthlyStrainDetailTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_787_313_600)   // 2026-08-20 12:00 UTC

    private func entry(daysAgo: Int, strain: Double?) -> DailyRollupStoreEntry {
        let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
        return DailyRollupStoreEntry(day: day, tzOffsetMinutes: 0, recovery: 60, rhr: nil,
                                     sleepSeconds: nil, strain: strain)
    }

    func testDailyAverageComparesAcrossAPartialMonth() {
        // Aug 1–20 at 8.0 a day (20 days) vs July 1–20 at 4.0 a day: the
        // totals differ by 80 but the honest comparison is +4.0 a day.
        var rollups = (0..<20).map { entry(daysAgo: $0, strain: 8) }
        rollups += (31..<51).map { entry(daysAgo: $0, strain: 4) }
        let report = MonthlyReport(rollups: rollups, now: now, calendar: calendar)
        XCTAssertEqual(report.totalStrain ?? 0, 160, accuracy: 0.001)
        XCTAssertEqual(report.strainDailyAverage ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(report.strainDailyAverageDeltaVsPriorMonth ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(MonthlyReport.strainDetailText(dailyAverage: report.strainDailyAverage,
                                                      delta: report.strainDailyAverageDeltaVsPriorMonth),
                       "8.0 a day · +4.0 vs last month")
    }

    func testNoPriorMonthShowsTheAverageAlone() {
        let rollups = (0..<20).map { entry(daysAgo: $0, strain: 8) }
        let report = MonthlyReport(rollups: rollups, now: now, calendar: calendar)
        XCTAssertNil(report.strainDailyAverageDeltaVsPriorMonth)
        XCTAssertEqual(MonthlyReport.strainDetailText(dailyAverage: report.strainDailyAverage, delta: nil), "8.0 a day")
    }

    func testBuildingMonthWithholdsTheAverage() {
        let rollups = (0..<13).map { entry(daysAgo: $0, strain: 8) }
        let report = MonthlyReport(rollups: rollups, now: now, calendar: calendar)
        XCTAssertTrue(report.isBuilding)
        XCTAssertNil(report.strainDailyAverage)
        XCTAssertEqual(MonthlyReport.strainDetailText(dailyAverage: nil, delta: nil),
                       "Daily strain summed across the month")
    }

    func testGrammar() {
        XCTAssertEqual(MonthlyReport.strainDetailText(dailyAverage: 7.96, delta: -1.25), "8.0 a day · \u{2212}1.2 vs last month")
        XCTAssertEqual(MonthlyReport.strainDetailText(dailyAverage: 5, delta: 0.04), "5.0 a day · same as last month")
    }
}
