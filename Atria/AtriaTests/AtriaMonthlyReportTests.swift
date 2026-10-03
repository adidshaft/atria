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
        XCTAssertTrue(overview.contains("AtriaMonthlyReportSheet(rollups: rollups,"),
                      "the weekly sheet must present the monthly report")
        XCTAssertTrue(overview.contains("cycleStrainByDisplayDay: cycleStrainByDisplayDay"),
                      "the monthly sheet must overlay the same cycle series the weekly report uses")
        XCTAssertTrue(overview.contains("Building this month's picture"),
                      "below the honesty gate the hero must say it is building")
        let today = try String(contentsOf: appDirectory.appendingPathComponent("AtriaTodayScreen.swift"),
                               encoding: .utf8)
        XCTAssertTrue(today.contains("sleepNights: sessionProjectionStore.state.sleepHistorySnapshot.nights"),
                      "consistency needs the qualified sleep windows, not bedtime-only rollups")
    }

    /// 2026-09-02: the sheet carries a month-at-a-glance strip of daily
    /// recovery. Cells come from rollup scores only, tinted by the shared
    /// zone authority; unscored days stay hollow and the block is omitted
    /// until one day has scored.
    func testSheetCarriesARecoveryByDayStripFromRealScoresOnly() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Atria")
        let overview = try String(contentsOf: appDirectory.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(overview.contains("if scoredDayCount > 0 {\n                        kicker(\"Recovery by day\")"))
        XCTAssertTrue(overview.contains("Metrics.recoveryZone(recovery)?.tint"),
                      "cells use the same zone authority as the Today ring")
        XCTAssertTrue(overview.contains(".strokeBorder(.quaternary, lineWidth: 1)"),
                      "unscored days are hollow, never filled or interpolated")
        // 2026-09-02 (strain strip): the builder collects recovery and strain in
        // one pass; the nil check is now an `if let` on the same rollup field.
        XCTAssertTrue(overview.contains("if let recovery = entry.recovery, recoveryByDay[key] == nil"))
    }

    /// 2026-09-02 (same fire's follow-on): a strain-by-day strip beside the
    /// recovery one — single strain hue, magnitude as intensity per the
    /// palette rule; hollow without a value; omitted until one day has one.
    func testSheetCarriesAStrainByDayStripInOneHueByIntensity() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Atria")
        let overview = try String(contentsOf: appDirectory.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(overview.contains("if strainDayCount > 0 {\n                        kicker(\"Strain by day\")"))
        XCTAssertTrue(overview.contains(".fill(Metrics.electricStrain.opacity(Self.strainIntensity(strain)))"),
                      "one hue; the fill carries the magnitude")
        XCTAssertFalse(overview.contains("strainColor(strain)?.tint"), "no zone colours for strain")
        XCTAssertEqual(AtriaMonthlyReportSheet.strainIntensity(0), 0.22, accuracy: 0.0001)
        XCTAssertEqual(AtriaMonthlyReportSheet.strainIntensity(21), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AtriaMonthlyReportSheet.strainIntensity(40), 1.0, accuracy: 0.0001, "clamped")
        XCTAssertGreaterThan(AtriaMonthlyReportSheet.strainIntensity(14), AtriaMonthlyReportSheet.strainIntensity(7))
    }

    /// 2026-09-02: the third strip completes the ring trio — sleep by day,
    /// tinted by percent of the night's own need through the ring's zone
    /// function; hollow without a figure; omitted until one night has one.
    func testSheetCarriesASleepByDayStripByPercentOfNeed() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Atria")
        let overview = try String(contentsOf: appDirectory.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(overview.contains("if sleepDayCount > 0 {\n                        kicker(\"Sleep by day\")"))
        XCTAssertTrue(overview.contains(".fill(AtriaTriRing.zoneTint(.sleep, percent: Double(percent)).opacity(0.9))"),
                      "the same zone function as the ring, keyed on percent of need")
        XCTAssertTrue(overview.contains("if let sleep = entry.sleepPerformance, sleepByDay[key] == nil"),
                      "cells come from the rollup's own performance figure only")
    }
}
