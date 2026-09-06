import XCTest
@testable import Atria

/// Owner report 2026-09-02: the axis is the window, not the extent of the
/// data. Trends and the combo chart already pin a trailing week. The weekly
/// report's trend bars still let Swift Charts size X to whatever days had a
/// reading, so two strain days stretched edge to edge and read as a full week.
final class AtriaWeeklyTrendWindowTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func day(_ day: Int) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: 7, day: day).date!
    }

    func testTrendWeekIsTheISOWeekContainingTheAnchor() {
        // Wednesday 8 July 2026 sits in the ISO week Mon 6 – Sun 12.
        let days = AtriaWeeklyReportSheet.trendWeekDays(anchor: day(8), calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, day(6))
        XCTAssertEqual(days.last, day(12))
        XCTAssertEqual(
            AtriaWeeklyReportSheet.trendWeekDays(anchor: day(6), calendar: calendar),
            days,
            "Monday and Wednesday of the same week share one axis"
        )
        XCTAssertEqual(
            AtriaWeeklyReportSheet.trendWeekDays(anchor: day(12), calendar: calendar),
            days
        )
    }

    func testDomainCoversSundayBarNotJustSundayMidnight() {
        let domain = AtriaWeeklyReportSheet.trendWeekXDomain(anchor: day(8), calendar: calendar)
        XCTAssertEqual(domain?.lowerBound, day(6))
        XCTAssertEqual(domain?.upperBound, day(13),
                       "Sunday's unit:.day bar occupies [12, 13); clipping at midnight 12 would drop it")
    }

    func testASparseWeekDoesNotShrinkTheAxis() {
        // The helper does not take the plotted points — that is the defect.
        let emptyWednesday = AtriaWeeklyReportSheet.trendWeekXDomain(anchor: day(8), calendar: calendar)
        let emptySunday = AtriaWeeklyReportSheet.trendWeekXDomain(anchor: day(12), calendar: calendar)
        XCTAssertEqual(emptyWednesday, emptySunday)
        XCTAssertEqual(emptyWednesday?.lowerBound, day(6))
        XCTAssertEqual(emptyWednesday?.upperBound, day(13))
    }

    func testChartBindsTheAxisToThatWindow() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var weeklyTrendChart: some View"))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "private var strainAverageText")?.lowerBound ?? rest.endIndex
        let chart = String(rest[..<end])
        XCTAssertTrue(chart.contains(".chartXScale(domain: Self.trendWeekXDomain(anchor: displayedReport.generatedAt,"),
                      "the weekly trend must scale to its ISO week, never to whatever bars exist")
        XCTAssertTrue(chart.contains("AxisMarks(values: weekDays)"),
                      "ticks are the seven weekdays, so empty days stay empty")
        XCTAssertFalse(chart.contains("AxisMarks(values: .automatic(desiredCount: 4)) { _ in"),
                       "the data-extent x-axis is what let two bars fill the week")
    }
}
