import XCTest
@testable import Atria

/// 2026-09-02: the weekly report's recovery row compared against the prior
/// week while the strain and sleep rows carried generic subtitles. Both now
/// carry the same comparison, gated the same way (both weeks need a value),
/// and read "Same as prior week" within a tenth of strain or a minute of
/// sleep.
final class AtriaWeeklyReportDeltaTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func rollups(strains: [Double?], sleeps: [TimeInterval?], today: Date) -> [DailyRollupStoreEntry] {
        (0..<14).map { offset in
            var entry = DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                                              tzOffsetMinutes: 0,
                                              bedtimeMinutes: nil)
            entry.strain = strains[offset]
            entry.sleepSeconds = sleeps[offset]
            return entry
        }
    }

    func testDeltasCompareThisWeekToThePriorWeek() {
        let today = DateComponents(calendar: calendar, year: 2026, month: 7, day: 6).date!
        let strains: [Double?] = [10, 12, 8, 10, 11, 9, 10, 8, 8, 9, 7, 8, 8, 8]      // 10.0 vs 8.0
        let sleeps: [TimeInterval?] = Array(repeating: 7.5 * 3_600, count: 7)
            + Array(repeating: 8 * 3_600, count: 7)                                      // −30m
        let report = WeeklyReport(rollups: rollups(strains: strains, sleeps: sleeps, today: today),
                                  now: today, calendar: calendar)
        XCTAssertEqual(report.strainDeltaVsPriorWeek.map { ($0 * 10).rounded() / 10 }, 2.0)
        XCTAssertEqual(report.sleepDeltaVsPriorWeekSeconds, -1_800)
        XCTAssertEqual(WeeklyReport.strainDeltaText(report.strainDeltaVsPriorWeek), "+2.0 vs prior week")
        XCTAssertEqual(WeeklyReport.sleepDeltaText(report.sleepDeltaVsPriorWeekSeconds), "\u{2212}30m vs prior week")
    }

    func testDeltasStayBuildingWithoutAPriorWeek() {
        let today = DateComponents(calendar: calendar, year: 2026, month: 7, day: 6).date!
        let strains: [Double?] = [10, 12, 8, 10, 11, 9, 10] + Array(repeating: nil, count: 7)
        let sleeps: [TimeInterval?] = Array(repeating: 7 * 3_600, count: 7) + Array(repeating: nil, count: 7)
        let report = WeeklyReport(rollups: rollups(strains: strains, sleeps: sleeps, today: today),
                                  now: today, calendar: calendar)
        XCTAssertNil(report.strainDeltaVsPriorWeek)
        XCTAssertNil(report.sleepDeltaVsPriorWeekSeconds)
        XCTAssertEqual(WeeklyReport.strainDeltaText(nil), "Prior week comparison building")
        XCTAssertEqual(WeeklyReport.sleepDeltaText(nil), "Prior week comparison building")
    }

    func testTextGrammar() {
        XCTAssertEqual(WeeklyReport.strainDeltaText(0.04), "Same as prior week")
        XCTAssertEqual(WeeklyReport.strainDeltaText(-1.25), "\u{2212}1.2 vs prior week")
        XCTAssertEqual(WeeklyReport.sleepDeltaText(20), "Same as prior week")
        XCTAssertEqual(WeeklyReport.sleepDeltaText(65 * 60), "+1h 05m vs prior week")
        XCTAssertEqual(WeeklyReport.sleepDeltaText(-2 * 3_600), "\u{2212}2h 00m vs prior week")
    }

    func testCycleStrainOverridesTheCivilBucketOnTheSameDay() {
        let today = DateComponents(calendar: calendar, year: 2026, month: 7, day: 6).date!
        // Civil: 10 a day this week. Cycle says the most recent day was 16.5
        // (evening work that the civil split put on the next morning).
        let strains: [Double?] = Array(repeating: 10, count: 14)
        let sleeps: [TimeInterval?] = Array(repeating: 7.5 * 3_600, count: 14)
        let rollups = rollups(strains: strains, sleeps: sleeps, today: today)
        // Rollups normalize `day` with Calendar.current, which is also how
        // the store keys the cycle series. Key the overlay the same way.
        let shiftedDay = rollups[0].day
        let report = WeeklyReport(rollups: rollups,
                                  now: today,
                                  calendar: calendar,
                                  cycleStrainByDisplayDay: [shiftedDay: 16.5])
        XCTAssertEqual(report.hardestDay?.strain, 16.5)
        XCTAssertEqual(report.strainAvg.map { ($0 * 10).rounded() / 10 }, 10.9)
        let untouched = WeeklyReport(rollups: rollups, now: today, calendar: calendar)
        XCTAssertEqual(untouched.strainAvg, 10)
        XCTAssertEqual(untouched.hardestDay?.strain, 10)
    }

    func testAnEmptyCycleMapLeavesTheCivilWeekUntouched() {
        let today = DateComponents(calendar: calendar, year: 2026, month: 7, day: 6).date!
        let strains: [Double?] = Array(repeating: 8, count: 14)
        let sleeps: [TimeInterval?] = Array(repeating: 7 * 3_600, count: 14)
        let rollups = rollups(strains: strains, sleeps: sleeps, today: today)
        XCTAssertEqual(
            WeeklyReport(rollups: rollups, now: today, calendar: calendar,
                         cycleStrainByDisplayDay: [:]),
            WeeklyReport(rollups: rollups, now: today, calendar: calendar)
        )
    }

    func testReportRowsUseTheDeltas() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("detail: WeeklyReport.strainDeltaText(displayedReport.strainDeltaVsPriorWeek),"))
        XCTAssertTrue(source.contains("detail: WeeklyReport.sleepDeltaText(displayedReport.sleepDeltaVsPriorWeekSeconds),"))
        XCTAssertFalse(source.contains("Daily strain across the week"))
        XCTAssertFalse(source.contains("Nightly duration across the week"))
        XCTAssertTrue(source.contains("cycleStrainByDisplayDay: cycleStrainByDisplayDay"),
                      "paged weeks must overlay the same cycle series")
    }

    func testTodayAndThePersistedReportFeedTheCycleMap() throws {
        let today = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(today.contains("cycleStrainByDisplayDay: store.physiologicalCycleStrainByDisplayDay"))
        let sessions = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)
        XCTAssertTrue(sessions.contains("cycleStrainByDisplayDay: physiologicalCycleStrainByDisplayDay"))
        let assistant = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaAssistantScreen.swift"), encoding: .utf8)
        XCTAssertTrue(assistant.contains("cycleStrainByDisplayDay: store.physiologicalCycleStrainByDisplayDay"))
    }
}
