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
        }
    }
}
