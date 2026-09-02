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

    func testHistoryFixtureOpensTheRestingHRSheetOverFixtureRollups() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("case \"rhr-detail\", \"rhr-detail-history\": return .restingHeartRate"))
        XCTAssertTrue(source.contains("|| Self.debugShowsDetailHistory(arguments: ProcessInfo.processInfo.arguments)"))
    }
}
