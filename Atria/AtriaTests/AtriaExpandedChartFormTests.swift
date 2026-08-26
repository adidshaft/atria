import XCTest
@testable import Atria

/// Expanding a chart must show the SAME shape that was tapped.
///
/// Once-a-day metrics are drawn as bars — a bar states "this much, measured
/// from zero", which is what a daily score is, and a padded min…max line domain
/// renders them as truncated stubs that exaggerate small day-to-day
/// differences. The full-screen chart, however, opened every metric as a line,
/// so tapping a bar chart produced a line chart of the same numbers.
final class AtriaExpandedChartFormTests: XCTestCase {

    // MARK: - The daily-bar set

    func testOnlyOncePerDayMetricsRenderAsBars() {
        for kind in [AtriaMetricDetailKind.recovery, .sleep, .strain, .sleepPerformance] {
            XCTAssertTrue(kind.rendersAsDailyBar,
                          "\(kind.rawValue) resolves to one value per day")
        }
    }

    func testContinuousAndIntraDayMetricsStayLines() {
        for kind in [AtriaMetricDetailKind.hrv, .restingHeartRate, .respiratoryRate,
                     .stress, .vo2max, .sleepEfficiency, .skinTemperature,
                     .fitnessAge, .hrZones, .bloodOxygen] {
            XCTAssertFalse(kind.rendersAsDailyBar,
                           "\(kind.rawValue) is not a once-a-day score")
        }
    }

    func testEveryKindIsClassifiedExactlyOnceAndTheSetIsTheExpectedSize() {
        // Guards a new case silently defaulting into "line" without anyone
        // deciding. If this fails, classify the new metric deliberately.
        let bars = [AtriaMetricDetailKind.recovery, .hrv, .restingHeartRate,
                    .respiratoryRate, .sleep, .strain, .stress, .vo2max,
                    .sleepPerformance, .sleepEfficiency, .skinTemperature,
                    .fitnessAge, .hrZones, .bloodOxygen]
            .filter(\.rendersAsDailyBar)
        XCTAssertEqual(bars.count, 4)
    }

    // MARK: - Wiring

    func testTheDailyBarClassifierDrivesTheChartsThatDrawBars() throws {
        // The four `metricChart(rendersAsDailyBar: true)` call sites and the
        // classifier must not drift apart — they describe the same fact.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(
            source.components(separatedBy: "rendersAsDailyBar: true").count - 1, 4,
            "exactly four charts draw daily bars"
        )
        for title in ["Recovery", "Sleep duration", "Strain", "Sleep sufficiency"] {
            XCTAssertTrue(source.contains("metricChart(title: \"\(title)\""),
                          "\(title) must still be a metricChart")
        }
    }

    func testBothExpandedChartCallSitesOpenInTheTappedForm() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        var wired = 0
        for name in ["AtriaOverviewSections.swift", "AtriaTrendChart.swift"] {
            let source = try String(
                contentsOf: root.appendingPathComponent(name), encoding: .utf8
            )
            guard source.contains("AtriaExpandedChartView(") else { continue }
            XCTAssertTrue(
                source.contains("defaultChartType: metric.rendersAsDailyBar ? .bars : .line"),
                "\(name) must open the expanded chart in the tapped form"
            )
            wired += 1
        }
        XCTAssertEqual(wired, 2, "both presenters must be wired")
    }

    func testBarsInTheExpandedChartAreAnchoredAtZeroLikeEverywhereElse() throws {
        // Opening in bar form is only honest if the domain is anchored at zero.
        // `prepared.yDomain` pads 12% around min…max — correct for a line, but a
        // bar draws from the zero baseline, so a floor above zero clips it and
        // makes rendered height proportional to `value − domainLower`. A sleep
        // week of 5.5…8.0h pads to 5.2…8.3, drawing a 1.45x difference as ~9x.
        //
        // This test pins the DOMAIN. An earlier version of this file pinned
        // only the `defaultChartType:` wiring, which is exactly why the
        // truncated-bar regression shipped green.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaExpandedChart.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains(".chartYScale(domain: prepared.yDomain)"),
            "the padded line domain must not be applied unconditionally"
        )
        XCTAssertTrue(source.contains("0...max(prepared.yDomain.upperBound, 1)"),
                      "bars must be anchored at zero")
        XCTAssertTrue(source.contains("guard effectiveChartType == .bars"),
                      "and lines must keep the padded domain")
    }

    func testAllThreeBarSurfacesAnchorAtZero() throws {
        // The rule now lives in three places; none may drift.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        for name in ["AtriaOverviewSections.swift",
                     "AtriaTrendChart.swift",
                     "AtriaExpandedChart.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name),
                                  encoding: .utf8)
            XCTAssertTrue(text.contains("0...max("),
                          "\(name) must anchor its bars at zero")
        }
    }

    func testTheExpandedChartStillDefaultsToLineForCallersThatSayNothing() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaExpandedChart.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("var defaultChartType: AtriaGraphChartType = .line"),
                      "the parameter must be additive, defaulting to today's behaviour")
        XCTAssertTrue(source.contains("_chartType = State(initialValue: defaultChartType)"),
                      "and it must seed the state rather than override the user's choice")
    }
}
