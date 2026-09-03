import XCTest
@testable import Atria

/// Owner report 2026-09-02, "the graphs are inconsistent and incomplete":
/// the Trends card filtered its samples to a trailing window but gave the
/// chart no x-domain, so Swift Charts sized the axis to the data. Two
/// recorded days out of thirty stretched edge to edge and read as a full
/// month, and a single recorded day sat alone in the middle of the plot.
/// The window now travels with the prepared series and becomes the axis.
final class AtriaTrendChartWindowTests: XCTestCase {
    private var source: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaTrendChart.swift"), encoding: .utf8)
        }
    }

    func testPreparedSeriesCarriesItsPlottedWindow() throws {
        let s = try source
        XCTAssertTrue(s.contains("let windowStart: Date"))
        XCTAssertTrue(s.contains("let windowEnd: Date"))
        XCTAssertTrue(s.contains("windowStart: plottedStart,"))
        XCTAssertTrue(s.contains("windowEnd: windowEnd)"))
    }

    func testAxisIsBoundToThatWindowNotTheData() throws {
        let s = try source
        XCTAssertTrue(s.contains(".chartXScale(domain: prepared.xDomain,"),
                      "the trend chart must scale to its window, never to whatever data exists")
        XCTAssertFalse(s.contains(".chartXScale(range: .plotDimension(startPadding: 18, endPadding: 18))\n"),
                       "the domain-free scale is what let sparse data fill the plot")
    }

    func testAllRangeKeepsADataDerivedStart() throws {
        let s = try source
        XCTAssertTrue(s.contains("let plottedStart = range == .all"),
                      "`.all` has no trailing cutoff, so its window is the recorded span")
    }

    /// The window ends at the close of the anchor day, so a point recorded
    /// this morning is inside the axis rather than clipped at "now".
    func testWindowEndsAtTheCloseOfToday() throws {
        let s = try source
        XCTAssertTrue(s.contains("let windowEnd = calendar.date(byAdding: .day, value: 1,"))
        XCTAssertTrue(s.contains("to: calendar.startOfDay(for: now)) ?? now"))
    }

    /// Trailing windows: a week ending today contains today's own sample.
    func testTrailingWindowContainsTodayForEveryPrimaryRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 23))!
        for range in [AtriaTrendRange.week, .month] {
            let cutoff = range.cutoffDate(now: now, calendar: calendar)
            XCTAssertLessThan(cutoff, now, "\(range) must open before the anchor")
            let span = calendar.dateComponents([.day], from: cutoff, to: now).day ?? 0
            XCTAssertEqual(span, range.days, "\(range) trails exactly its own length")
        }
    }
}
