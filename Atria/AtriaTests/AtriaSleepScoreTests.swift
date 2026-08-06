import XCTest
@testable import Atria

/// GAP-06 — the provisional composite Atria Sleep Score. These tests lock in the
/// handoff's qualification behavior: present-only contribution, missing stays
/// missing (never a constant), an explicit minimum before any composite shows,
/// the overnight-load gate, and reproducibility from frozen inputs.
final class AtriaSleepScoreTests: XCTestCase {

    func testThreePresentComponentsRenormalizeOverPresentWeights() {
        // suff 80 (w .50) + cons 60 (w .25) + eff 90 (w .15); overnight missing.
        // weighted = 40 + 15 + 13.5 = 68.5 over total weight 0.90 -> 76.
        let score = AtriaSleepScore.make(sufficiencyPercent: 80,
                                         consistencyPercent: 60,
                                         efficiencyPercent: 90,
                                         validatedOvernightLoadPercent: nil)
        XCTAssertEqual(score.score, 76)
        XCTAssertTrue(score.isProvisional)
        XCTAssertEqual(Set(score.presentComponents), [.sufficiency, .consistency, .efficiency])
        XCTAssertEqual(score.missingComponents, [.overnightLoad])
    }

    func testTwoComponentsAreEnoughAndRenormalize() {
        // suff 80 (.50) + cons 60 (.25) -> weighted 55 over 0.75 -> 73.
        let score = AtriaSleepScore.make(sufficiencyPercent: 80,
                                         consistencyPercent: 60,
                                         efficiencyPercent: nil,
                                         validatedOvernightLoadPercent: nil)
        XCTAssertEqual(score.score, 73)
        XCTAssertEqual(Set(score.presentComponents), [.sufficiency, .consistency])
        XCTAssertEqual(Set(score.missingComponents), [.efficiency, .overnightLoad])
    }

    func testSingleComponentProducesNoComposite() {
        // Only Sufficiency present: below the minimum, so no composite is shown
        // and the caller keeps showing Sleep Sufficiency on its own.
        let score = AtriaSleepScore.make(sufficiencyPercent: 80,
                                         consistencyPercent: nil,
                                         efficiencyPercent: nil,
                                         validatedOvernightLoadPercent: nil)
        XCTAssertNil(score.score)
        XCTAssertEqual(score.presentComponents, [.sufficiency])
    }

    func testMissingComponentIsNeverSubstitutedWithAConstant() {
        // Efficiency missing must not drag the score toward any constant: the
        // two-present result equals the two-component score exactly.
        let missingEff = AtriaSleepScore.make(sufficiencyPercent: 80,
                                              consistencyPercent: 60,
                                              efficiencyPercent: nil,
                                              validatedOvernightLoadPercent: nil)
        let twoOnly = AtriaSleepScore.make(sufficiencyPercent: 80,
                                           consistencyPercent: 60,
                                           efficiencyPercent: nil,
                                           validatedOvernightLoadPercent: nil)
        XCTAssertEqual(missingEff.score, twoOnly.score)
        XCTAssertEqual(missingEff.score, 73)
    }

    func testUnvalidatedOvernightLoadNeverEntersScore() {
        // The HR-only overnight projection is passed as nil until GAP-10 is
        // validated; the score renormalizes over the other three and marks
        // overnight-load missing.
        let score = AtriaSleepScore.make(sufficiencyPercent: 90,
                                         consistencyPercent: 90,
                                         efficiencyPercent: 90,
                                         validatedOvernightLoadPercent: nil)
        XCTAssertEqual(score.score, 90)
        XCTAssertTrue(score.missingComponents.contains(.overnightLoad))
    }

    func testValidatedOvernightLoadContributesWhenProvided() {
        // The future path: a validated overnight-load percent takes its weight.
        // suff 80(.5)+cons 60(.25)+eff 90(.15)+load 50(.10) = 73.5 over 1.0 -> 74.
        let score = AtriaSleepScore.make(sufficiencyPercent: 80,
                                         consistencyPercent: 60,
                                         efficiencyPercent: 90,
                                         validatedOvernightLoadPercent: 50)
        XCTAssertEqual(score.score, 74)
        XCTAssertTrue(score.missingComponents.isEmpty)
        // It is still provisional until the weights themselves are validated.
        XCTAssertTrue(score.isProvisional)
    }

    func testOutOfRangePercentsAreClamped() {
        let high = AtriaSleepScore.make(sufficiencyPercent: 130,
                                        consistencyPercent: 100,
                                        efficiencyPercent: nil,
                                        validatedOvernightLoadPercent: nil)
        // 100(.5)+100(.25) over 0.75 -> 100, never above.
        XCTAssertEqual(high.score, 100)

        let low = AtriaSleepScore.make(sufficiencyPercent: -20,
                                       consistencyPercent: 0,
                                       efficiencyPercent: nil,
                                       validatedOvernightLoadPercent: nil)
        XCTAssertEqual(low.score, 0)
    }

    func testReproducibleFromSameInputs() {
        let a = AtriaSleepScore.make(sufficiencyPercent: 77,
                                     consistencyPercent: 64,
                                     efficiencyPercent: 88,
                                     validatedOvernightLoadPercent: nil)
        let b = AtriaSleepScore.make(sufficiencyPercent: 77,
                                     consistencyPercent: 64,
                                     efficiencyPercent: 88,
                                     validatedOvernightLoadPercent: nil)
        XCTAssertEqual(a, b)
    }

    // MARK: - GAP-07 typical overnight resting band

    func testTypicalBandIsNilBelowTheDocumentedMinimum() {
        let thirteen = Array(repeating: 50, count: 13)
        XCTAssertNil(AtriaOvernightTypical.restingBand(restingHRs: thirteen))
    }

    func testTypicalBandIsMeanPlusMinusOneSD() throws {
        // 14 values, mean 50, variance 2 -> sd ~1.4142; band 48.586...51.414.
        let values = [48, 50, 52, 49, 51, 50, 48, 52, 50, 49, 51, 50, 48, 52]
        let band = try XCTUnwrap(AtriaOvernightTypical.restingBand(restingHRs: values))
        XCTAssertEqual(band.lowerBound, 48.586, accuracy: 0.01)
        XCTAssertEqual(band.upperBound, 51.414, accuracy: 0.01)
    }

    func testTypicalBandDropsImplausibleValuesBeforeCounting() {
        // 13 plausible + 2 implausible: after filtering only 13 remain -> nil.
        let values = Array(repeating: 50, count: 13) + [0, 240]
        XCTAssertNil(AtriaOvernightTypical.restingBand(restingHRs: values))
    }

    func testNoComponentsProducesNoScoreButStillProvisional() {
        let score = AtriaSleepScore.make(sufficiencyPercent: nil,
                                         consistencyPercent: nil,
                                         efficiencyPercent: nil,
                                         validatedOvernightLoadPercent: nil)
        XCTAssertNil(score.score)
        XCTAssertTrue(score.presentComponents.isEmpty)
        XCTAssertTrue(score.isProvisional)
    }
}
