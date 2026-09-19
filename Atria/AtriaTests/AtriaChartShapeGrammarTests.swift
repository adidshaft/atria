import XCTest
@testable import Atria

/// One shape per metric, decided by how it is sampled, identical on every
/// surface. The corner sparkline, the metric detail chart and the full-screen
/// chart must never disagree about whether a metric is bars or a line.
final class AtriaChartShapeGrammarTests: XCTestCase {

    func testTheDailyBarSetIsExactlyTheOnceADayMetrics() {
        let bars = AtriaMetricDetailKind.allCases.filter(\.rendersAsDailyBar)
        XCTAssertEqual(Set(bars),
                       [.recovery, .sleep, .strain, .sleepPerformance,
                        .hrv, .restingHeartRate, .respiratoryRate,
                        .sleepEfficiency],
                       "a change to this set is a product decision, not a "
                           + "side effect — HRV/RHR/respiration drew bars on "
                           + "their tiles and lines when opened until 2026-08-27")
    }

    func testStressStaysALineBecauseItMovesThroughTheDay() {
        XCTAssertFalse(AtriaMetricDetailKind.stress.rendersAsDailyBar)
    }

    func testSignedAndScaleHostileMetricsStayOffBars() {
        // Skin temperature is a signed deviation — the bar domain anchors at
        // zero and would clip a negative night. Fitness age is an age in
        // years — a bar from zero hides a one-year change entirely.
        XCTAssertFalse(AtriaMetricDetailKind.skinTemperature.rendersAsDailyBar)
        XCTAssertFalse(AtriaMetricDetailKind.fitnessAge.rendersAsDailyBar)
    }

    func testTheExpandedChartOpensInTheShapeThatWasTapped() throws {
        // Both expanded-chart call sites derive their default from the same
        // property, so the full-screen shape cannot drift from the tile's.
        for name in ["AtriaOverviewSections.swift", "AtriaTrendChart.swift"] {
            let text = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Atria/\(name)"),
                encoding: .utf8
            )
            XCTAssertTrue(
                text.contains("defaultChartType: metric.rendersAsDailyBar ? .bars : .line"),
                "\(name) must derive the expanded default from the one rule")
            XCTAssertTrue(
                text.contains("anchorsAtZero: metric.chartAnchorsAtZero"),
                "\(name) must pass the zero-floor rule into the expanded chart")
        }
    }

    func testMagnitudeBarsGrowFromZeroAndLevelBarsKeepTheirRange() {
        for kind in [AtriaMetricDetailKind.recovery, .sleep, .strain,
                     .sleepPerformance, .sleepEfficiency] {
            XCTAssertTrue(kind.chartAnchorsAtZero, "\(kind.rawValue) is a magnitude")
        }
        for kind in [AtriaMetricDetailKind.hrv, .restingHeartRate, .respiratoryRate] {
            XCTAssertTrue(kind.rendersAsDailyBar, "\(kind.rawValue) is once a day")
            XCTAssertFalse(kind.chartAnchorsAtZero,
                           "\(kind.rawValue) would hide its signal on a 0-based axis")
        }
    }

    func testVitalsTrendUsesTheSameBarGrammar() {
        XCTAssertTrue(AtriaTrendMetric.hrv.rendersAsDailyBar)
        XCTAssertTrue(AtriaTrendMetric.restingHR.rendersAsDailyBar)
        XCTAssertTrue(AtriaTrendMetric.strain.rendersAsDailyBar)
        XCTAssertFalse(AtriaTrendMetric.hrv.chartAnchorsAtZero)
        XCTAssertFalse(AtriaTrendMetric.restingHR.chartAnchorsAtZero)
        XCTAssertTrue(AtriaTrendMetric.strain.chartAnchorsAtZero)
    }

    func testDailyAndTracePlotsShareOneWell() throws {
        XCTAssertEqual(AtriaChartVisualGrammar.plotCornerRadius, 7)
        XCTAssertEqual(AtriaChartVisualGrammar.plotFillOpacity, 0.035, accuracy: 0.0001)
        for name in [
            "AtriaGraphGrammar.swift",
            "AtriaVitalsCollectionSections.swift",
            "AtriaStressDetailView.swift",
        ] {
            let text = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Atria/\(name)"),
                encoding: .utf8
            )
            if name == "AtriaGraphGrammar.swift" {
                XCTAssertTrue(text.contains("plotCornerRadius"))
                XCTAssertTrue(text.contains("plotFillOpacity"))
            } else {
                XCTAssertTrue(
                    text.contains(".atriaGraphPlotSurface()"),
                    "\(name) must use the shared plot well"
                )
                XCTAssertFalse(
                    text.contains("cornerRadius: 10, style: .continuous"),
                    "\(name) must not keep a private 10pt plot well"
                )
                XCTAssertFalse(
                    text.contains(".background(.secondary.opacity(0.035))"),
                    "\(name) must not keep a secondary-fill plot well"
                )
            }
        }
    }
}
