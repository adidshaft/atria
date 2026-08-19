import XCTest
@testable import Atria

final class AtriaPhysiologicalStressModelTests: XCTestCase {
    /// Field report 2026-08-19, item 8: "the stress calculations may be a little
    /// bit off, lesser than it is generally shown."
    ///
    /// Measured over the field device's own 130,480 quiet-awake samples
    /// (resting 56, age-estimated max 187, so a 131 bpm reserve): the wearer's
    /// entire observed awake range 65-97 bpm mapped to 0.60-1.87, and High
    /// (>= 2.0) required >= 100.1 bpm — ABOVE their observed maximum. High was
    /// unreachable from awake HR by construction.
    func testHighIsUnreachableOnTheReserveCoordinateAndReachableOnTheReference() {
        let rest = 56.0, maximum = 187.0
        func reserveScore(_ bpm: Double) -> Double {
            3 * AtriaPhysiologicalStressModel.hrStressCoordinate(
                meanHR: bpm, restingHeartRate: rest,
                maximumHeartRate: maximum, awakeReference: nil
            )
        }
        // The wearer's observed awake maximum still cannot reach High.
        XCTAssertLessThan(reserveScore(97), 2.0)
        XCTAssertEqual(reserveScore(97), 1.87, accuracy: 0.02)
        // Their median day sits below even the Calm/Moderate edge.
        XCTAssertLessThan(reserveScore(75), 1.0)

        // With the wearer's own percentile edges the same wearer gets a usable
        // scale. p70 = 80 and p96 = 92 on the field device's 132,880-sample,
        // 12-day pooled histogram -> midpoint 86, halfWidth 6.
        let reference = AtriaPhysiologicalStressModel.AwakeReference(calmEdge: 80, highEdge: 92)
        func referenceScore(_ bpm: Double) -> Double {
            3 * AtriaPhysiologicalStressModel.hrStressCoordinate(
                meanHR: bpm, restingHeartRate: rest,
                maximumHeartRate: maximum, awakeReference: reference
            )
        }
        // The zone boundaries land exactly on the wearer's percentiles, because
        // 3*sigmoid(-ln2) = 1 and 3*sigmoid(+ln2) = 2.
        XCTAssertEqual(reference.zoneMidpoint, 86.0, accuracy: 0.001)
        XCTAssertEqual(reference.zoneHalfWidth, 6.0, accuracy: 0.001)
        XCTAssertEqual(referenceScore(80), 1.0, accuracy: 0.001, "p70 IS the calm edge")
        XCTAssertEqual(referenceScore(92), 2.0, accuracy: 0.001, "p96 IS the high edge")
        // A typical day is still calm-dominant...
        XCTAssertLessThan(referenceScore(75), 1.0)
        // ...and a genuine excursion can finally reach High.
        XCTAssertGreaterThanOrEqual(referenceScore(92), 2.0)
    }

    /// A degenerate distribution must not collapse the scale into a step
    /// function at a single bpm.
    func testAwakeReferenceHalfWidthIsFloored() {
        func halfWidth(calm: Double, high: Double) -> Double {
            AtriaPhysiologicalStressModel.AwakeReference(calmEdge: calm, highEdge: high).zoneHalfWidth
        }
        XCTAssertEqual(halfWidth(calm: 80, high: 92), 6.0, accuracy: 0.001)
        XCTAssertEqual(halfWidth(calm: 80, high: 81), 4.0, accuracy: 0.001, "floored")
        XCTAssertEqual(halfWidth(calm: 70, high: 100), 15.0, accuracy: 0.001,
                       "a genuinely wide distribution is not capped — it is the wearer's own")
    }

    /// No reference means no change: a wearer who has not accumulated one is
    /// scored exactly as before.
    func testMissingOrInvalidReferenceFallsBackToTheReserveCoordinate() {
        let rest = 56.0, maximum = 187.0
        for reference in [nil,
                          // calm edge below resting: not a personal scale
                          AtriaPhysiologicalStressModel.AwakeReference(calmEdge: 50, highEdge: 60),
                          // inverted edges
                          AtriaPhysiologicalStressModel.AwakeReference(calmEdge: 92, highEdge: 80),
                          AtriaPhysiologicalStressModel.AwakeReference(calmEdge: .nan, highEdge: 92)] {
            XCTAssertEqual(
                AtriaPhysiologicalStressModel.hrStressCoordinate(
                    meanHR: 80, restingHeartRate: rest,
                    maximumHeartRate: maximum, awakeReference: reference),
                AtriaPhysiologicalStressModel.hrStressCoordinate(
                    meanHR: 80, restingHeartRate: rest,
                    maximumHeartRate: maximum, awakeReference: nil),
                accuracy: 0.0001,
                "a missing, sub-resting or non-finite reference must not change scoring"
            )
        }
    }

    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    func testRestingAndElevatedHeartRateFollowTransparentReserveEquation() throws {
        let resting = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 60, rrDelta: nil)
        ))
        let elevated = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 150, rrDelta: nil)
        ))

        XCTAssertEqual(resting.hrStress,
                       1 / (1 + exp(2)),
                       accuracy: 1e-12)
        XCTAssertEqual(elevated.hrStress,
                       1 / (1 + exp(-4)),
                       accuracy: 1e-12)
        XCTAssertGreaterThan(elevated.score, resting.score)
        XCTAssertEqual(resting.heartRateWeight, 1, accuracy: 1e-12)
        XCTAssertEqual(elevated.heartRateWeight, 0.5, accuracy: 1e-12)
    }

    func testSuppressedHRVRaisesStressAndHighHRVLowersIt() throws {
        let suppressed = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 95, rrDelta: 20)
        ))
        let high = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 95, rrDelta: 120)
        ))

        XCTAssertNotNil(suppressed.rmssd)
        XCTAssertNotNil(high.rmssd)
        XCTAssertGreaterThan(try XCTUnwrap(suppressed.hrvStress),
                             try XCTUnwrap(high.hrvStress))
        XCTAssertGreaterThan(suppressed.score, high.score)
    }

    func testQualifiedMotionAttenuatesButNeverErasesExerciseElevation() throws {
        let unadjusted = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 155, rrDelta: 40, motion: .unavailable)
        ))
        let exercise = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 155,
                  rrDelta: 40,
                  motion: .qualifiedActivity(intensity: 1))
        ))

        XCTAssertEqual(exercise.motionContext.multiplier, 0.65, accuracy: 1e-12)
        XCTAssertEqual(exercise.unsmoothedScore,
                       unadjusted.unsmoothedScore * 0.65,
                       accuracy: 1e-9)
        XCTAssertGreaterThan(exercise.score, 0)
    }

    func testMissingAndUnqualifiedMotionCannotInventCalm() throws {
        let missing = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 140, rrDelta: 40, motion: .unavailable)
        ))
        let unqualified = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 140,
                  rrDelta: 40,
                  motion: .init(kind: .activity, intensity: 1, qualified: false))
        ))
        XCTAssertEqual(missing.score, unqualified.score, accuracy: 1e-12)
        XCTAssertEqual(unqualified.motionContext.multiplier, 1)
    }

    func testMissingOrUnqualifiedRRFallsBackToHonestHROnlyLowConfidence() throws {
        let missing = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 110, rrDelta: nil)
        ))
        let unqualified = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 110, rrDelta: 40, qualifyRR: false)
        ))

        for fact in [missing, unqualified] {
            XCTAssertTrue(fact.isHROnly)
            XCTAssertNil(fact.rmssd)
            XCTAssertNil(fact.hrvStress)
            XCTAssertEqual(fact.confidence, .low)
            XCTAssertEqual(fact.unsmoothedScore, 3 * fact.hrStress, accuracy: 1e-12)
        }
    }

    func testQualifiedCurrentRRWithoutHistoricalHRVBaselineRemainsInternallyCompleteHROnly() throws {
        let qualifiedRRInput = input(meanHeartRate: 92, rrDelta: 35)
        let noHRVBaseline = AtriaPhysiologicalStressModel.WindowInput(
            end: qualifiedRRInput.end,
            heartRates: qualifiedRRInput.heartRates,
            rrIntervals: qualifiedRRInput.rrIntervals,
            personalization: .init(restingHeartRate: 60,
                                   maximumHeartRate: 180,
                                   restingBaselineDayCount: 20,
                                   hrvBaseline: nil)
        )
        let fact = try XCTUnwrap(
            AtriaPhysiologicalStressModel.evaluate(noHRVBaseline)
        )

        XCTAssertTrue(fact.isHROnly)
        XCTAssertNil(fact.rmssd,
                     "RMSSD cannot persist as a used term without its comparison baseline")
        XCTAssertNil(fact.hrvStress)
        XCTAssertEqual(fact.confidence, .low)
        XCTAssertTrue(fact.isStructurallyValid)
    }

    func testBaselineLearningUsesConservativePersonalizedFallbackAndDisclosesConfidence() throws {
        let learning = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 90, rrDelta: 50, baselineDays: 4)
        ))
        let mature = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(meanHeartRate: 90, rrDelta: 50, baselineDays: 20)
        ))

        XCTAssertTrue(learning.baselineLearning)
        XCTAssertEqual(learning.confidence, .medium)
        XCTAssertFalse(mature.baselineLearning)
        XCTAssertEqual(mature.confidence, .medium,
                       "missing qualified motion holds confidence below high")
        XCTAssertEqual(learning.score, mature.score, accuracy: 1e-12,
                       "learning changes confidence, not the transparent equation")
    }

    func testScoreFactsClampExactlyToZeroAndThree() {
        let base = AtriaPhysiologicalStressModel.MinuteFact(
            date: end,
            score: -1,
            unsmoothedScore: 4,
            meanHeartRate: 80,
            rmssd: nil,
            hrStress: 0.5,
            hrvStress: nil,
            heartRateWeight: 1,
            motionContext: .unavailable,
            sleepContext: .unavailable,
            confidence: .low,
            baselineLearning: true
        )
        XCTAssertEqual(base.score, 0)
        XCTAssertEqual(base.unsmoothedScore, 3)
    }

    func testEMAUsesThreeMinuteHalfLifeAndDoesNotBridgeTelemetryGap() throws {
        let first = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            input(end: end, meanHeartRate: 60, rrDelta: nil)
        ))
        let continuousInput = input(end: end.addingTimeInterval(60),
                                    meanHeartRate: 160,
                                    rrDelta: nil)
        let continuous = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            continuousInput,
            previous: first
        ))
        let alpha = 1 - exp(-log(2.0) / 3.0)
        XCTAssertEqual(continuous.score,
                       first.score + alpha * (continuous.unsmoothedScore - first.score),
                       accuracy: 1e-12)

        let gappedInput = input(end: end.addingTimeInterval(120),
                                meanHeartRate: 160,
                                rrDelta: nil)
        let gapped = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
            gappedInput,
            previous: first
        ))
        XCTAssertEqual(gapped.score, gapped.unsmoothedScore, accuracy: 1e-12)
    }

    func testMissingHRProducesGraphGapAndResetsBatchSmoothing() throws {
        let firstInput = input(end: end, meanHeartRate: 60, rrDelta: nil)
        let missing = AtriaPhysiologicalStressModel.WindowInput(
            end: end.addingTimeInterval(60),
            heartRates: [],
            rrIntervals: [],
            personalization: personalization(days: 20)
        )
        let finalInput = input(end: end.addingTimeInterval(120),
                               meanHeartRate: 160,
                               rrDelta: nil)
        let facts = AtriaPhysiologicalStressModel.evaluate([firstInput, missing, finalInput])
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[1].score, facts[1].unsmoothedScore, accuracy: 1e-12)
    }

    func testLiveAndBatchPathsUseExactlyTheSameKernel() throws {
        let inputs = [
            input(end: end, meanHeartRate: 72, rrDelta: 70),
            input(end: end.addingTimeInterval(60), meanHeartRate: 95, rrDelta: 55),
            input(end: end.addingTimeInterval(120), meanHeartRate: 120, rrDelta: nil),
        ]
        let batch = AtriaPhysiologicalStressModel.evaluate(inputs)

        var live: [AtriaPhysiologicalStressModel.MinuteFact] = []
        var previous: AtriaPhysiologicalStressModel.MinuteFact?
        for input in inputs {
            let fact = try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(
                input,
                previous: previous
            ))
            live.append(fact)
            previous = fact
        }
        XCTAssertEqual(live, batch)
        XCTAssertTrue(batch.allSatisfy {
            $0.scoringVersion == AtriaPhysiologicalStressModel.scoringVersion
        })
    }

    func testOutOfOrderInputsFailClosedWithoutSilentReordering() {
        let late = input(end: end.addingTimeInterval(60),
                         meanHeartRate: 90,
                         rrDelta: 50)
        let early = input(end: end, meanHeartRate: 90, rrDelta: 50)
        XCTAssertTrue(AtriaPhysiologicalStressModel.evaluate([late, early]).isEmpty)

        var reversedHeartRates = early.heartRates
        reversedHeartRates.swapAt(0, 1)
        let malformedHR = AtriaPhysiologicalStressModel.WindowInput(
            end: early.end,
            heartRates: reversedHeartRates,
            rrIntervals: early.rrIntervals,
            personalization: early.personalization
        )
        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(malformedHR))

        var reversedRR = early.rrIntervals
        reversedRR.swapAt(0, 1)
        let malformedRR = AtriaPhysiologicalStressModel.WindowInput(
            end: early.end,
            heartRates: early.heartRates,
            rrIntervals: reversedRR,
            personalization: early.personalization
        )
        let fact = AtriaPhysiologicalStressModel.evaluate(malformedRR)
        XCTAssertNotNil(fact)
        XCTAssertTrue(fact?.isHROnly == true,
                      "malformed RR fails closed to the honest HR-only kernel")
    }

    func testSparseHeartRateIsGapOrExplicitLowConfidence() throws {
        let single = AtriaPhysiologicalStressModel.WindowInput(
            end: end,
            heartRates: [.init(date: end, bpm: 90)],
            rrIntervals: [],
            personalization: personalization(days: 20)
        )
        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(single))

        let sparse = AtriaPhysiologicalStressModel.WindowInput(
            end: end,
            heartRates: [
                .init(date: end.addingTimeInterval(-300), bpm: 90),
                .init(date: end.addingTimeInterval(-240), bpm: 90),
                .init(date: end.addingTimeInterval(-180), bpm: 90),
                .init(date: end.addingTimeInterval(-120), bpm: 90),
                .init(date: end.addingTimeInterval(-60), bpm: 90),
                .init(date: end, bpm: 90),
            ],
            rrIntervals: input(meanHeartRate: 90, rrDelta: 50).rrIntervals,
            personalization: personalization(days: 20),
            motionContext: .qualifiedStill
        )
        XCTAssertEqual(try XCTUnwrap(AtriaPhysiologicalStressModel.evaluate(sparse)).confidence,
                       .low)
    }

    func testInternalHeartRateGapFailsClosedAtContinuityBoundary() throws {
        func window(offsets: [TimeInterval]) -> AtriaPhysiologicalStressModel.WindowInput {
            .init(end: end,
                  heartRates: offsets.map {
                      .init(date: end.addingTimeInterval($0), bpm: 90)
                  },
                  rrIntervals: [],
                  personalization: personalization(days: 20))
        }
        let allowed = window(offsets: [-300, -240, -180, -120, -60, 0])
        XCTAssertNotNil(AtriaPhysiologicalStressModel.evaluate(allowed),
                        "an exact one-minute source cadence is continuous")

        let justBeyondCadence = window(
            offsets: [-300, -240, -180, -120, -59.999, 0]
        )
        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(justBeyondCadence),
                     "minute scheduling jitter cannot bridge a raw telemetry gap")

        let internalHole = window(offsets: [-300, -299, -298, -297, 0])
        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(internalHole),
                     "a multi-minute telemetry hole cannot mint a five-minute fact")
    }

    func testRawHeartRateGapCreatesGraphGapAndResetsBatchEMA() throws {
        func window(end windowEnd: Date,
                    meanHeartRate: Int,
                    offsets: [TimeInterval])
            -> AtriaPhysiologicalStressModel.WindowInput {
            .init(
                end: windowEnd,
                heartRates: offsets.map {
                    .init(date: windowEnd.addingTimeInterval($0),
                          bpm: meanHeartRate)
                },
                rrIntervals: [],
                personalization: personalization(days: 20)
            )
        }

        let cadenceOffsets: [TimeInterval] = [-300, -240, -180, -120, -60, 0]
        let first = window(end: end,
                           meanHeartRate: 60,
                           offsets: cadenceOffsets)
        let missingMinute = window(
            end: end.addingTimeInterval(60),
            meanHeartRate: 110,
            offsets: [-300, -240, -180, -119, -59, 0]
        )
        let resumed = window(end: end.addingTimeInterval(120),
                             meanHeartRate: 160,
                             offsets: cadenceOffsets)

        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(missingMinute),
                     "a 61-second raw outage is a graph gap")
        let facts = AtriaPhysiologicalStressModel.evaluate(
            [first, missingMinute, resumed]
        )
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[1].score,
                       facts[1].unsmoothedScore,
                       accuracy: 1e-12,
                       "the first fact after a raw gap must not reuse the old EMA")
    }

    func testRRIsNotDifferencedAcrossRejectedSampleOrTelemetryGap() throws {
        let rr = [
            AtriaPhysiologicalStressModel.RRSample(
                date: end.addingTimeInterval(-120), milliseconds: 800
            ),
            .init(date: end.addingTimeInterval(-119), milliseconds: 900),
            .init(date: end.addingTimeInterval(-60), milliseconds: 700, qualified: false),
            .init(date: end.addingTimeInterval(-1), milliseconds: 1_000),
            .init(date: end, milliseconds: 1_100),
        ]
        let rmssd = try XCTUnwrap(AtriaPhysiologicalStressModel.qualifiedRMSSD(
            rr,
            start: end.addingTimeInterval(-300),
            end: end
        ))
        XCTAssertEqual(rmssd, 100, accuracy: 1e-12)
    }

    func testRobustBaselineUsesOnlyBoundedRollingSuffix() throws {
        let stale = Array(repeating: log(5.0), count: 20)
        let recent = Array(repeating: log(80.0),
                           count: AtriaPhysiologicalStressModel.maximumBaselineObservations)
        let baseline = try XCTUnwrap(AtriaPhysiologicalStressModel.robustHRVBaseline(
            lnRMSSDValues: stale + recent,
            qualifiedDayCount: recent.count
        ))
        XCTAssertEqual(baseline.medianLnRMSSD, log(80), accuracy: 1e-12)
    }

    func testRobustBaselineMedianAndMADResistSingleOutlier() throws {
        let values = [log(78.0), log(80.0), log(82.0), log(1_000.0)]
        let baseline = try XCTUnwrap(AtriaPhysiologicalStressModel.robustHRVBaseline(
            lnRMSSDValues: values,
            qualifiedDayCount: 4
        ))
        XCTAssertEqual(baseline.medianLnRMSSD,
                       (log(80.0) + log(82.0)) / 2,
                       accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(baseline.robustScale, 0.15)
    }

    private func input(end: Date? = nil,
                       meanHeartRate: Int,
                       rrDelta: Double?,
                       motion: AtriaPhysiologicalStressModel.MotionContext = .unavailable,
                       qualifyRR: Bool = true,
                       baselineDays: Int = 20) -> AtriaPhysiologicalStressModel.WindowInput {
        let end = end ?? self.end
        let heartRates = stride(from: 300, through: 0, by: -30).map {
            AtriaPhysiologicalStressModel.HeartRateSample(
                date: end.addingTimeInterval(-Double($0)),
                bpm: meanHeartRate
            )
        }
        let rr: [AtriaPhysiologicalStressModel.RRSample]
        if let rrDelta {
            rr = stride(from: 180, through: 0, by: -1).enumerated().map { index, offset in
                .init(date: end.addingTimeInterval(-Double(offset)),
                      milliseconds: 800 + (index.isMultiple(of: 2) ? 0 : rrDelta),
                      qualified: qualifyRR)
            }
        } else {
            rr = []
        }
        return .init(end: end,
                     heartRates: heartRates,
                     rrIntervals: rr,
                     personalization: personalization(days: baselineDays),
                     motionContext: motion)
    }

    private func personalization(days: Int) -> AtriaPhysiologicalStressModel.Personalization {
        .init(restingHeartRate: 60,
              maximumHeartRate: 180,
              restingBaselineDayCount: days,
              hrvBaseline: .init(medianLnRMSSD: log(80),
                                 robustScale: 0.2,
                                 qualifiedDayCount: days))
    }
}
