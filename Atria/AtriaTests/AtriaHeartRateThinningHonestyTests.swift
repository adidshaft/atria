import XCTest
@testable import Atria

/// Thinning must never invent a gap.
///
/// Device report 2026-08-26, with screenshots: "the stress and hr charts seem
/// to miss a lot of detail in the middle … the one in activity center seems a
/// little different."
///
/// Both halves had one cause. `windowed` thinned the whole window with a single
/// index-uniform stride, which multiplies EVERY spacing by the same factor —
/// and the five-minute honesty threshold was applied downstream, to the
/// already-thinned array. A stretch recorded once a minute, thinned 10:1, came
/// out ten minutes apart and was drawn as a hole. Dense stretches kept their
/// detail because they held most of the rows; sparse-but-present stretches lost
/// the budget and vanished. Activity Monitor segments at full resolution first
/// and has always looked right.
///
/// The renderer showing MORE gaps than the data contains is the mirror of
/// bridging one: both make the chart disagree with the evidence.
final class AtriaHeartRateThinningHonestyTests: XCTestCase {

    private let threshold = AtriaChartVisualGrammar.traceDisplayContinuityGap
    private let base = Date(timeIntervalSince1970: 1_756_000_000)

    private func points(_ offsets: [TimeInterval], bpm: Int = 60)
        -> [AtriaHomeModel.HeartRateChartPoint] {
        offsets.map { AtriaHomeModel.HeartRateChartPoint(t: base.addingTimeInterval($0), bpm: bpm) }
    }

    /// Every gap in the output that exceeds the honesty threshold.
    private func breaks(_ result: [AtriaHomeModel.HeartRateChartPoint]) -> [TimeInterval] {
        zip(result, result.dropFirst())
            .map { $1.t.timeIntervalSince($0.t) }
            .filter { $0 > threshold }
    }

    // MARK: - The defect

    func testAContinuousStretchIsNeverBrokenByThinning() {
        // Six hours recorded every 60s = 361 points, thinned to a budget of
        // 200. The old index stride kept every other point (120s apart, still
        // fine) — but with 3,600 points at 6s spacing it kept every 18th, i.e.
        // 108s. Push the density up and the old code breaks: 21,600 points at
        // 1 Hz thinned to 200 is one kept point every 108s... still under.
        // The real failure needs UNEVEN density, which the next test covers.
        // This one pins the simple invariant.
        let continuous = points(stride(from: 0, through: 21_600, by: 60).map { $0 })
        let result = AtriaVitalsHeartRateTimeline.windowed(continuous,
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertTrue(breaks(result).isEmpty,
                      "continuous data must render continuous; found breaks "
                          + "\(breaks(result))")
    }

    func testASparseStretchBesideADenseOneKeepsItsLine() {
        // THE REPORTED CASE. Five hours of drained history at one row every
        // 60s, then one hour of live streaming at 1 Hz. The live hour holds
        // 3,600 of the 3,900 rows — 92% — so an index-uniform stride spends
        // 92% of its 200-point budget there and leaves the five-hour history
        // with ~15 points, i.e. one every ~20 minutes. Every one of those
        // spacings clears the five-minute threshold, so the whole morning
        // renders as holes despite being continuously recorded.
        var offsets: [TimeInterval] = []
        offsets += stride(from: 0, through: 18_000, by: 60).map { Double($0) }
        offsets += stride(from: 18_001, through: 21_600, by: 1).map { Double($0) }

        let result = AtriaVitalsHeartRateTimeline.windowed(points(offsets),
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertTrue(breaks(result).isEmpty,
                      "the sparse-but-continuous stretch must keep its line; "
                          + "found \(breaks(result).count) false breaks")
    }

    // MARK: - ...without hiding the real ones

    func testARealGapStillBreaks() {
        var offsets: [TimeInterval] = []
        offsets += stride(from: 0, through: 7_200, by: 60).map { Double($0) }
        // A 40-minute hole: nothing recorded.
        offsets += stride(from: 9_600, through: 21_600, by: 60).map { Double($0) }

        let result = AtriaVitalsHeartRateTimeline.windowed(points(offsets),
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertEqual(breaks(result).count, 1,
                       "the real 40-minute hole must survive thinning")
        XCTAssertGreaterThan(breaks(result).first ?? 0, 2_000,
                             "and must still read as roughly its true size")
    }

    func testASubThresholdHoleIsNotPromotedIntoABreak() {
        // Four minutes of silence is under the five-minute threshold, so the
        // line is meant to stay joined across it.
        var offsets: [TimeInterval] = []
        offsets += stride(from: 0, through: 10_800, by: 30).map { Double($0) }
        offsets += stride(from: 11_040, through: 21_600, by: 30).map { Double($0) }

        let result = AtriaVitalsHeartRateTimeline.windowed(points(offsets),
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertTrue(breaks(result).isEmpty,
                      "a 4-minute hole is below the threshold and must not "
                          + "become a visible break")
    }

    // MARK: - Bounds

    func testTheBudgetIsStillRoughlyRespected() {
        let continuous = points(stride(from: 0, through: 21_600, by: 2).map { Double($0) })
        let result = AtriaVitalsHeartRateTimeline.windowed(continuous,
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertLessThanOrEqual(result.count, 320,
                                 "honesty may cost some extra points, but not "
                                     + "an unbounded number")
        XCTAssertGreaterThan(result.count, 50)
    }

    func testEndpointsSurvive() {
        let continuous = points(stride(from: 0, through: 21_600, by: 5).map { Double($0) })
        let result = AtriaVitalsHeartRateTimeline.windowed(continuous,
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertEqual(result.first?.t, continuous.first?.t)
        XCTAssertEqual(result.last?.t, continuous.last?.t,
                       "the newest reading must always be on screen")
    }

    func testSmallInputsPassThroughUntouched() {
        let few = points([0, 60, 120])
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.windowed(few,
                                                             window: .hour6,
                                                             displayBudget: 200).count,
                       3)
        XCTAssertTrue(AtriaVitalsHeartRateTimeline.windowed([],
                                                             window: .hour6).isEmpty)
    }

    func testOutputStaysOrdered() {
        var offsets: [TimeInterval] = []
        offsets += stride(from: 0, through: 9_000, by: 45).map { Double($0) }
        offsets += stride(from: 12_000, through: 21_600, by: 3).map { Double($0) }
        let result = AtriaVitalsHeartRateTimeline.windowed(points(offsets),
                                                           window: .hour6,
                                                           displayBudget: 200)
        XCTAssertEqual(result.map(\.t), result.map(\.t).sorted())
    }
}
