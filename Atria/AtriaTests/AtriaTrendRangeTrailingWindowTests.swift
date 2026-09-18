import XCTest
@testable import Atria

/// Owner 2026-09-02: with twenty days of wear on the phone, the resting-HR
/// Week chart showed two days and the Month chart two days, because both
/// ranges were the calendar period containing the anchor. On Wednesday
/// September 2 that is Monday plus today, and two days of September. The
/// segment labels promise "7 days" and "30 days": trailing windows ending on
/// the anchor day, so today's point is always inside.
final class AtriaTrendRangeTrailingWindowTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()
    private var wednesday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 23))!
    }

    func testWeekAndMonthTrailTheAnchorDay() {
        let week = AtriaTrendRange.week.periodInterval(containing: wednesday, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .month], from: week.start).day, 27)
        XCTAssertEqual(calendar.dateComponents([.month], from: week.start).month, 8)
        XCTAssertTrue(week.contains(wednesday))
        let month = AtriaTrendRange.month.periodInterval(containing: wednesday, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: month.start).day, 4)
        XCTAssertEqual(calendar.dateComponents([.month], from: month.start).month, 8)
        XCTAssertEqual(month.end, week.end)
    }

    func testLabelsAreDateRangesNotMonthNames() {
        // Locale decides day/month order; the range's endpoints and the
        // absence of a month name are what matter.
        let week = AtriaTrendRange.week.periodLabel(containing: wednesday, calendar: calendar)
        XCTAssertTrue(week.contains("27") && week.contains("Aug") && week.contains("Sep"), week)
        let month = AtriaTrendRange.month.periodLabel(containing: wednesday, calendar: calendar)
        XCTAssertTrue(month.contains("4") && month.contains("Aug") && month.contains("Sep"), month)
        XCTAssertFalse(month.contains("September 2026"), "a trailing window is not a month name")
    }

    func testSameMonthWeekPutsTheMonthOnTheStartNotBetweenTheDays() {
        var calendar = self.calendar
        calendar.locale = Locale(identifier: "en_US")
        let friday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 15))!
        let week = AtriaTrendRange.week.periodLabel(containing: friday, calendar: calendar)
        XCTAssertEqual(week, "Sep 12–18", week)
        XCTAssertFalse(week.contains("12–Sep"), "device Recovery Week printed 12–Sep 18 under bars for Sep 13–18")
    }

    func testTwentyDaysOfRollupsFillTheWindows() {
        let days = (0..<20).map { calendar.startOfDay(for: calendar.date(byAdding: .day, value: -$0, to: wednesday)!) }.sorted()
        let week = AtriaMetricPeriodIndexProjection(days: days, referenceDate: calendar.startOfDay(for: wednesday),
                                                    range: .week, calendar: calendar)
        XCTAssertEqual(week.currentIndices.count, 7)
        XCTAssertEqual(week.priorIndices.count, 7, "the prior window is the seven days before")
        let month = AtriaMetricPeriodIndexProjection(days: days, referenceDate: calendar.startOfDay(for: wednesday),
                                                     range: .month, calendar: calendar)
        XCTAssertEqual(month.currentIndices.count, 20, "every recorded day of a partial month shows")
    }

    func testNewestOvernightHRVStaysInsideWeekAndMonth() {
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 10))!
        let nights = [14, 15, 16].map { day in
            calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!)
        }
        let values = [42, 45, 77]
        let week = AtriaMetricPeriodIndexProjection(
            days: nights,
            referenceDate: thursday,
            range: .week,
            calendar: calendar
        )
        let month = AtriaMetricPeriodIndexProjection(
            days: nights,
            referenceDate: thursday,
            range: .month,
            calendar: calendar
        )
        XCTAssertEqual(week.currentIndices.map { values[$0] }, values)
        XCTAssertEqual(month.currentIndices.map { values[$0] }, values)
        XCTAssertEqual(week.currentIndices.map { values[$0] }.last, 77)
        XCTAssertEqual(month.currentIndices.map { values[$0] }.last, 77)
    }

    func testMonthKeepsNightsTheWeekWindowHasNotReachedYet() {
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 10))!
        let nights = [1, 14, 15, 16].map { day in
            calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!)
        }
        let week = AtriaMetricPeriodIndexProjection(
            days: nights,
            referenceDate: thursday,
            range: .week,
            calendar: calendar
        )
        let month = AtriaMetricPeriodIndexProjection(
            days: nights,
            referenceDate: thursday,
            range: .month,
            calendar: calendar
        )
        XCTAssertEqual(week.currentIndices.count, 3)
        XCTAssertEqual(month.currentIndices.count, 4)
        XCTAssertFalse(week.currentIndices.contains(0))
        XCTAssertTrue(month.currentIndices.contains(0))
    }

    func testHistoryFixtureOpensTheRestingHRSheetOverFixtureRollups() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("case \"rhr-detail\", \"rhr-detail-history\": return .restingHeartRate"))
        XCTAssertTrue(source.contains("|| Self.debugShowsDetailHistory(arguments: ProcessInfo.processInfo.arguments)"))
    }
}
