import XCTest
@testable import Atria

/// 2026-09-03, from a seeded render of the resting-HR detail on Week and
/// Month. Three things in that chart were drawn from the data's extent rather
/// than from the window, and one was drawn from the wrong palette:
///
///  * the baseline ("typical") band ran from the first point to the last, so
///    on a window with a trailing gap it stopped mid-chart and read as an
///    unexplained rectangle;
///  * the gradient fill under the line needs two consecutive days, so on a
///    sparse window it shaded some points and not others — a solid block under
///    an arbitrary stretch of the chart;
///  * the coverage line counted plotted points against calendar days, which is
///    wrong for a bucketed series whose points are weekly averages;
///  * the newest reading was repainted in the metric's identity hue over its
///    own status hue, making the one point a reader looks at first the only
///    one whose colour said nothing about the value.
final class AtriaDetailChartBandHonestyTests: XCTestCase {
    private var source: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        }
    }

    func testBaselineBandSpansTheVisibleWindowNotTheDataExtent() throws {
        let source = try source
        XCTAssertTrue(source.contains("RectangleMark(xStart: .value(\"Start\", prepared.xDomain?.lowerBound ?? points.first?.day ?? Date()),"),
                      "the band starts at the window, falling back to the data only without a domain")
        XCTAssertTrue(source.contains("xEnd: .value(\"End\", prepared.xDomain?.upperBound ?? points.last?.day ?? Date()),"))
    }

    func testAreaFillIsWithheldOnAWindowWithMissingDays() throws {
        let source = try source
        XCTAssertTrue(source.contains("private var rendersAreaFill: Bool { windowMissingDayCount == nil }"))
        XCTAssertTrue(source.contains("ForEach(rendersAreaFill ? points.contiguousDayRuns() : [], id: \\.point.day)"),
                      "the gradient fill is gated; the line and the points are not")
        XCTAssertTrue(source.contains("ForEach(rendersAsDailyBar ? [] : points.contiguousDayRuns(), id: \\.point.day)"),
                      "the stroke still draws its own runs, so gaps stay visible")
    }

    func testCoverageLineIsSkippedForABucketedSeries() throws {
        let source = try source
        XCTAssertTrue(source.contains("guard !prepared.hasMinMaxBand, let xDomain = prepared.xDomain else { return nil }"),
                      "weekly averages must not be counted as nights")
        XCTAssertTrue(source.contains("guard let days = windowMissingDayCount, days <= 31 else { return nil }"),
                      "the copy keeps its month-length cap while the count moved out")
        XCTAssertFalse(source.contains("guard days > 1, days <= 31, points.count < days else { return nil }"),
                       "the old inline rule is gone")
    }

    func testNewestReadingKeepsItsOwnStatusHue() throws {
        let source = try source
        XCTAssertTrue(source.contains(".foregroundStyle(last.tint).symbolSize(110)"),
                      "emphasis by size; colour still reports the value")
        XCTAssertFalse(source.contains(".foregroundStyle(tint).symbolSize(110)"))
    }

    func testBaselineBandsCarryTheirMetricIdentityHue() throws {
        let source = try source
        for hue in ["AtriaMetricDetailKind.hrv.tint",
                    "AtriaMetricDetailKind.restingHeartRate.tint",
                    "AtriaMetricDetailKind.respiratoryRate.tint"] {
            XCTAssertTrue(source.contains(hue), "missing identity hue \(hue)")
        }
        let bandWindow = source.components(separatedBy: "AtriaDetailBaselineBand(lower:")
            .dropFirst()
            .map { String($0.prefix(320)) }
        XCTAssertEqual(bandWindow.count, 3)
        for window in bandWindow {
            XCTAssertFalse(window.contains("tint: .pink"), "raw hue left on a band")
            XCTAssertFalse(window.contains("tint: .teal"), "raw hue left on a band")
        }
    }

    /// The launch argument that made the two multi-day states capturable is a
    /// screenshot aid, not shipped behaviour: it must stay inside DEBUG and
    /// must not pin the picker after the sheet opens.
    func testInitialRangeLaunchArgumentIsDebugOnly() throws {
        let source = try source
        let start = try XCTUnwrap(source.range(of: "static func debugRequestedInitialRange("))
        let before = String(source[..<start.lowerBound].suffix(400))
        XCTAssertTrue(before.contains("#if DEBUG"))
        XCTAssertTrue(source.contains("if let forced = Self.debugRequestedInitialRange() { resolvedInitialRange = forced }"))
        XCTAssertTrue(source.contains("_range = State(initialValue: resolvedInitialRange)"),
                      "it seeds the initial value only, so the segmented control still owns the range")
    }
}
