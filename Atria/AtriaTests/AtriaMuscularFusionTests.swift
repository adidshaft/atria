import XCTest
@testable import Atria

/// WP-8 / GAP-09 — muscular ⊕ cardiovascular fusion: deterministic, monotone,
/// bounded, zero-neutral for cardio-only days, and identical across surfaces.
final class AtriaMuscularFusionTests: XCTestCase {
    func testMuscularEquivalentIsZeroNeutralMonotoneAndBounded() {
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: nil), 0,
                       "no logged effort-complete receipt → exactly zero")
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 0), 0)
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: -5), 0)

        var previous = 0.0
        for score in stride(from: 5.0, through: 100, by: 5) {
            let equivalent = AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: score)
            XCTAssertGreaterThan(equivalent, previous,
                                 "the fusion input must rise strictly with the muscular score")
            previous = equivalent
        }
        XCTAssertEqual(previous, AtriaStrainLoadModel.muscularEquivalentCeiling, accuracy: 0.001,
                       "score 100 lands exactly on the documented ceiling")
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 500),
                       AtriaStrainLoadModel.muscularEquivalentCeiling,
                       "the equivalent never exceeds the ceiling")
    }

    func testDayTotalOnlyCountsEffortCompleteReceipts() {
        func workout(id: String, receipt: AtriaStrengthLog.MuscularLoadReceipt?) -> UserConfirmedWorkout {
            var value = UserConfirmedWorkout(id: id,
                                             createdAt: Date(timeIntervalSince1970: 1_783_900_000),
                                             start: Date(timeIntervalSince1970: 1_783_900_000),
                                             end: Date(timeIntervalSince1970: 1_783_903_600),
                                             label: "Strength",
                                             source: "live_workout_window",
                                             confidence: "live_window_user_confirmed",
                                             sessions: 1,
                                             samples: 600,
                                             avgHR: 110,
                                             peakHR: 150,
                                             p95HR: 140,
                                             p99HR: 148,
                                             thresholdHR: 140,
                                             streamCoveragePercent: 90,
                                             observedDuration: 3_600,
                                             reason: "test",
                                             eventTimeZoneIdentifier: "Asia/Kolkata")
            value.muscularLoadReceipt = receipt
            return value
        }
        func receipt(score: Double?) -> AtriaStrengthLog.MuscularLoadReceipt {
            AtriaStrengthLog.MuscularLoadReceipt(calculationVersion: 1,
                                                 setCount: 5,
                                                 loadQualifiedSetCount: 5,
                                                 effortQualifiedSetCount: score == nil ? 3 : 5,
                                                 externalVolumeKg: 2_000,
                                                 effectiveVolumeKg: 2_000,
                                                 densityBonusFraction: 0,
                                                 muscularInputScore: score,
                                                 movementClasses: [.externalLoad])
        }

        let total = SessionStore.muscularTRIMPEquivalentTotal([
            workout(id: "scored", receipt: receipt(score: 60)),
            workout(id: "incomplete-rpe", receipt: receipt(score: nil)),
            workout(id: "unlogged", receipt: nil),
        ])
        XCTAssertEqual(total,
                       AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 60),
                       accuracy: 0.001,
                       "unlogged and RPE-incomplete sessions must contribute exactly zero")

        XCTAssertEqual(SessionStore.muscularTRIMPEquivalentTotal([workout(id: "none", receipt: nil)]), 0)
    }

    func testFusedDayStrainElevatesStrengthDaysAndLeavesCardioOnlyDaysUntouched() {
        let cardioTRIMP = 40.0
        let cardioOnly = Metrics.strain(fromTRIMP: cardioTRIMP + AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: nil))
        XCTAssertEqual(cardioOnly, Metrics.strain(fromTRIMP: cardioTRIMP),
                       "a cardio-only day's Strain is bit-identical after fusion")

        let fused = Metrics.strain(fromTRIMP: cardioTRIMP + AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 70))
        XCTAssertGreaterThan(fused, cardioOnly,
                             "a logged strength day must elevate the day total")
        XCTAssertLessThanOrEqual(fused, 21, "the display scale stays bounded")

        // Explainability: the delta is reproducible from the documented formula.
        let expectedEquivalent = AtriaStrainLoadModel.muscularEquivalentCeiling * pow(0.7, AtriaStrainLoadModel.muscularEquivalentExponent)
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 70),
                       expectedEquivalent, accuracy: 0.0001)
    }
}
