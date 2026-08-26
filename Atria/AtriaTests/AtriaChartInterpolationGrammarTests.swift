import XCTest
@testable import Atria

/// Interpolation is chosen by sample density, not by taste.
///
/// * **Dense intra-day series** (heart rate, stress) → `.monotone`. Readings sit
///   seconds or minutes apart, so smoothing does not invent anything, and the
///   series are already split at gaps so a curve cannot bridge one.
/// * **Sparse once-a-day trends** → `.linear`. A smooth curve through daily
///   points bows ABOVE the highest measured day, implying values the evidence
///   never recorded — the reason `AtriaTrendChart` states for its own choice.
/// * **Series whose point-to-point variability IS the measurement** → `.linear`,
///   density notwithstanding. The RR tachogram is dense, but smoothing it would
///   hide the beat-to-beat scatter that HRV is defined as.
///
/// The app was mixing these arbitrarily: heart rate rendered monotone in Vitals
/// and linear on the Health screen, and the trend chart drew its current series
/// linear while its prior-period ghost — the same daily data — drew monotone,
/// so one period looked steadier than the other purely from interpolation.
final class AtriaChartInterpolationGrammarTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    // MARK: - Dense series smooth

    func testDenseIntraDaySurfacesUseMonotone() throws {
        for name in ["AtriaHealthScreen.swift",
                     "AtriaStressDetailView.swift",
                     "AtriaVitalsCollectionSections.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains(".interpolationMethod(.monotone)"),
                          "\(name) draws dense series and must smooth them")
        }
    }

    func testTheHealthScreenNoLongerDrawsDenseSeriesAngular() throws {
        // All four of its interpolations were `.linear` on Time x Segment
        // series — the same heart-rate and stress data Vitals draws smooth.
        let text = try source("AtriaHealthScreen.swift")
        XCTAssertFalse(text.contains(".interpolationMethod(.linear)"),
                       "the Health screen has no sparse daily series")
    }

    // MARK: - The exception: when the variability IS the measurement

    func testTheRRTachogramStaysLinearBecauseSmoothingWouldHideTheSignal() throws {
        // `TachogramChart` plots beat-to-beat RR intervals. It is dense, so the
        // density rule above would smooth it — and that would be wrong: the
        // beat-to-beat scatter is not noise around a trend, it IS the quantity
        // HRV measures. A monotone curve through it visually suppresses the
        // variability the chart exists to show.
        let text = try source("HRV.swift")
        guard text.contains("struct TachogramChart") else {
            return XCTFail("TachogramChart moved; re-check this exception")
        }
        XCTAssertTrue(text.contains(".interpolationMethod(.linear)"),
                      "the tachogram must not be smoothed")
    }

    // MARK: - Sparse daily series stay angular

    func testTheDailyTrendChartStaysLinearOnBothItsSeries() throws {
        let text = try source("AtriaTrendChart.swift")
        XCTAssertFalse(
            text.contains(".interpolationMethod(.monotone)"),
            "daily samples must not be smoothed — monotone bows past the "
                + "measured days, including on the prior-period ghost"
        )
        XCTAssertTrue(text.contains(".interpolationMethod(.linear)"))
    }

    func testTheOvershootReasoningStaysRecordedNextToTheChoice() throws {
        // If someone later "tidies" these to match, the reason must be in
        // front of them rather than in a commit message.
        let text = try source("AtriaTrendChart.swift")
        XCTAssertTrue(text.contains("overshoot"),
                      "the daily-series choice must keep its stated reason")
    }
}
