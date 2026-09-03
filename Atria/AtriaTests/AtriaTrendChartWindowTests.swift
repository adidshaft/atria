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

    /// Sparse data used to read as a broken chart. The card now says how much
    /// of the plotted window holds a reading, and stays silent when the window
    /// is full or has no fixed length.
    func testCardStatesHowMuchOfTheWindowHasData() throws {
        let s = try source
        XCTAssertTrue(s.contains("return \"\\(recorded) of \\(window) \\(metric.coverageNoun) recorded\""))
        XCTAssertTrue(s.contains("guard range != .all, !prepared.series.isEmpty else { return nil }"),
                      "no count for a window without a fixed length")
        XCTAssertTrue(s.contains("guard recorded < window else { return nil }"),
                      "a full window says nothing")
        XCTAssertTrue(s.contains("if let coverageText {"), "and it is actually rendered")
    }

    /// The metric detail sheet says the same thing in the same words, derived
    /// from the window it already plots, and stays silent where a day count
    /// would mislead.
    func testDetailSheetStatesCoverageToo() throws {
        let overview = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertTrue(overview.contains("return \"\\(points.count) of \\(days) \\(coverageNoun) recorded\""))
        XCTAssertTrue(overview.contains("guard days > 1, days <= 31, points.count < days else { return nil }"),
                      "silent on a full window, a single day, and the weekly-bucketed long ranges")
        XCTAssertTrue(overview.contains("if let coverageText {"), "and it is rendered under the summary line")
    }

    /// Resting HR, HRV, respiration, sleep and recovery are read from a
    /// night's wear, so counting them in "days" would overstate what the
    /// strap measured. Strain accumulates across a waking day and keeps days.
    func testOvernightMetricsCountNightsAndStrainCountsDays() throws {
        let overview = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertEqual(overview.components(separatedBy: "coverageNoun: \"nights\"").count - 1, 6,
                       "recovery, HRV, resting HR, respiration, sleep duration and sleep sufficiency")
        XCTAssertTrue(overview.contains("coverageNoun: String = \"days\""), "strain and pace of ageing keep days")
        let trend = try source
        XCTAssertTrue(trend.contains("case .restingHR, .hrv: return \"nights\""))
        XCTAssertTrue(trend.contains("case .strain: return \"days\""))
        XCTAssertTrue(trend.contains("\\(metric.coverageNoun) recorded"))
    }

    /// The expanded full-screen chart speaks the same way, and both routes
    /// into it pass the metric's own noun.
    func testExpandedChartUsesTheSameNoun() throws {
        let expanded = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaExpandedChart.swift"), encoding: .utf8)
        XCTAssertTrue(expanded.contains("coverageNoun: String = \"days\","))
        XCTAssertTrue(expanded.contains("\\(dataDayCount) \\(coverageNoun) of \\(title.lowercased()) recorded."))
        XCTAssertFalse(expanded.contains("\\(dataDayCount) days of"), "the hardcoded noun is gone")
        let overview = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertTrue(overview.contains("coverageNoun: metric.coverageNoun,"))
        XCTAssertTrue(overview.contains("case .recovery, .hrv, .restingHeartRate, .respiratoryRate,"))
        let trendSource = try source
        XCTAssertTrue(trendSource.contains("coverageNoun: metric.coverageNoun,"))
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
