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
        // UPDATED 2026-08-27, with the rule rather than against it. This test
        // used to pin HRV, resting HR, respiratory rate and sleep efficiency
        // as lines — contradicting the owner's chart grammar ("HRV etc are
        // once a day right, then why isnt it bar charts") and making those
        // tiles draw bars on the card and lines when opened. The line set is
        // now exactly the metrics that are NOT one value per day.
        for kind in [AtriaMetricDetailKind.stress, .vo2max, .skinTemperature,
                     .fitnessAge, .hrZones, .bloodOxygen] {
            XCTAssertFalse(kind.rendersAsDailyBar,
                           "\(kind.rawValue) stays a line: intra-day, signed, "
                               + "scale-hostile, or has no stored per-day series")
        }
    }

    func testEveryKindIsClassifiedExactlyOnceAndTheSetIsTheExpectedSize() {
        // Guards a new case silently defaulting into "line" without anyone
        // deciding. If this fails, classify the new metric deliberately.
        XCTAssertEqual(
            AtriaMetricDetailKind.allCases.filter(\.rendersAsDailyBar).count,
            8
        )
    }

    // MARK: - Wiring

    func testTheDailyBarClassifierDrivesTheChartsThatDrawBars() throws {
        // Inline charts must take the one classifier, not a leftover per-metric
        // `rendersAsDailyBar: true` literal — HRV/RHR/respiration used to
        // default to lines while Recovery was hardcoded as bars.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("rendersAsDailyBar: metric.rendersAsDailyBar"),
            "inline charts must take the one classifier"
        )
        XCTAssertTrue(
            source.contains("anchorsAtZero: metric.chartAnchorsAtZero"),
            "level bars keep a padded domain; magnitudes still grow from zero"
        )
        XCTAssertFalse(
            source.contains("rendersAsDailyBar: true"),
            "no leftover per-metric bar literals"
        )
        for title in ["Recovery", "Sleep duration", "Strain", "Sleep sufficiency",
                      "HRV", "Resting HR", "Respiratory rate"] {
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
            XCTAssertTrue(
                source.contains("anchorsAtZero: metric.chartAnchorsAtZero"),
                "\(name) must pass the zero-floor rule"
            )
            wired += 1
        }
        XCTAssertEqual(wired, 2, "both presenters must be wired")
    }

    func testBarsInTheExpandedChartAreAnchoredAtZeroLikeEverywhereElse() throws {
        // Opening in bar form is only honest if magnitude bars grow from zero
        // and level bars keep the padded domain. All three surfaces now share
        // `plottedYDomain`.
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
        XCTAssertTrue(source.contains("plottedYDomain("),
                      "bars share the one y-domain helper")
        XCTAssertTrue(source.contains("drawsBars: effectiveChartType == .bars"),
                      "and lines must keep the padded domain")
        XCTAssertTrue(source.contains("anchorsAtZero: anchorsAtZero"))
    }

    func testAllThreeBarSurfacesAnchorAtZero() throws {
        // The rule now lives in one helper; every surface must call it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        for name in ["AtriaOverviewSections.swift",
                     "AtriaTrendChart.swift",
                     "AtriaExpandedChart.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name),
                                  encoding: .utf8)
            XCTAssertTrue(text.contains("plottedYDomain("),
                          "\(name) must use the shared y-domain helper")
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
