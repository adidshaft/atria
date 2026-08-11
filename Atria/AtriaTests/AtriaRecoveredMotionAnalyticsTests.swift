import XCTest
@testable import Atria

final class AtriaRecoveredMotionAnalyticsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testOneStillFragmentCannotValidateWholeSleep() {
        let end = start.addingTimeInterval(30 * 60)
        let provenance = AtriaRecoveredMotionAnalytics.sleepProvenance(
            epochs: [epoch(index: 0, stillness: 1, intensity: 0)],
            start: start,
            end: end
        )

        XCTAssertTrue(provenance.hasRecoveredEpochs)
        XCTAssertFalse(provenance.measurementSufficient)
        XCTAssertFalse(provenance.lowMotionValidated)
        XCTAssertGreaterThan(provenance.maximumGapSeconds, 20 * 60)
    }

    func testValidationBitWithoutMeasuredMotionValuesIsInsufficient() {
        let end = start.addingTimeInterval(30 * 60)
        let epochs = (0..<60).map { index -> AtriaRecoveredMotionEpoch in
            let epochStart = start.addingTimeInterval(Double(index) * 30)
            return .init(start: epochStart,
                         end: epochStart.addingTimeInterval(30),
                         rows: 15,
                         validatedRows: 15,
                         stillnessRatio: nil,
                         movementIntensity: nil,
                         p95VectorDelta: nil,
                         maximumGapSeconds: 2,
                         measurementValidated: true,
                         lowMotionQualified: false,
                         reason: "missing-values")
        }

        let provenance = AtriaRecoveredMotionAnalytics.sleepProvenance(
            epochs: epochs,
            start: start,
            end: end
        )

        XCTAssertTrue(provenance.hasRecoveredEpochs)
        XCTAssertFalse(provenance.measurementSufficient)
        XCTAssertFalse(provenance.lowMotionValidated)
    }

    func testActiveRecoveredMotionSupportsReviewButNeverFabricatesActivityType() {
        let end = start.addingTimeInterval(20 * 60)
        let epochs = (0..<40).map { epoch(index: $0, stillness: 0.35, intensity: 0.25) }
        let heartRate = (0...40).map {
            AtriaRecoveredMotionAnalytics.TimedHeartRate(
                timestamp: start.addingTimeInterval(Double($0) * 30),
                bpm: 100
            )
        }

        let assessment = AtriaRecoveredMotionAnalytics.activityAssessment(
            heartRate: heartRate,
            epochs: epochs,
            start: start,
            end: end,
            restingHR: 60
        )

        XCTAssertTrue(assessment.evidenceSufficient)
        XCTAssertTrue(assessment.activitySupported)
        XCTAssertNil(assessment.suggestedActivityType,
                     "gravity plus HR cannot distinguish walking, running, or another activity")
    }

    func testStillRecoveredMotionSuppressesHistoricalActivitySupport() {
        let end = start.addingTimeInterval(20 * 60)
        let epochs = (0..<40).map { epoch(index: $0, stillness: 1, intensity: 0) }
        let heartRate = (0...40).map {
            AtriaRecoveredMotionAnalytics.TimedHeartRate(
                timestamp: start.addingTimeInterval(Double($0) * 30),
                bpm: 100
            )
        }

        let assessment = AtriaRecoveredMotionAnalytics.activityAssessment(
            heartRate: heartRate,
            epochs: epochs,
            start: start,
            end: end,
            restingHR: 60
        )

        XCTAssertTrue(assessment.evidenceSufficient)
        XCTAssertFalse(assessment.activitySupported)
        XCTAssertNil(assessment.suggestedActivityType)
    }

    func testSameAggregateMotionWithDifferentEpochTimingRegeneratesDifferentStages() {
        let end = start.addingTimeInterval(30 * 60)
        let heartRate = stride(from: 0, through: 30 * 60, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(Double($0)),
                bpm: 62
            )
        }
        var earlyMovement = (0..<60).map { epoch(index: $0, stillness: 1, intensity: 0) }
        var lateMovement = earlyMovement
        earlyMovement[10] = epoch(index: 10, stillness: 0.3, intensity: 0.5)
        lateMovement[40] = epoch(index: 40, stillness: 0.3, intensity: 0.5)

        let earlyStages = AtriaSleepWakeResearch.stageSegments(samples: heartRate,
                                                               start: start,
                                                               end: end,
                                                               restingHR: 60,
                                                               isNap: false,
                                                               motionValidated: false,
                                                               motionEpochs: earlyMovement)
        let lateStages = AtriaSleepWakeResearch.stageSegments(samples: heartRate,
                                                              start: start,
                                                              end: end,
                                                              restingHR: 60,
                                                              isNap: false,
                                                              motionValidated: false,
                                                              motionEpochs: lateMovement)

        XCTAssertEqual(stage(at: start.addingTimeInterval(10 * 30 + 1), in: earlyStages), .awake)
        XCTAssertNotEqual(stage(at: start.addingTimeInterval(10 * 30 + 1), in: lateStages), .awake)
        XCTAssertNotEqual(stage(at: start.addingTimeInterval(40 * 30 + 1), in: earlyStages), .awake)
        XCTAssertEqual(stage(at: start.addingTimeInterval(40 * 30 + 1), in: lateStages), .awake)
        XCTAssertNotEqual(earlyStages, lateStages,
                          "equal whole-window averages must not preserve stale per-epoch stages")
    }

    func testDuplicatedTwelveSecondTailCannotManufactureLocalStageCoverage() {
        let end = start.addingTimeInterval(30 * 60)
        let heartRate = stride(from: 0, through: 30 * 60, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(Double($0)),
                bpm: 62
            )
        }
        let unsupportedIndex = 20
        let unsupportedStart = start.addingTimeInterval(Double(unsupportedIndex) * 30)
        let duplicatedTail = AtriaRecoveredMotionEpoch(
            start: unsupportedStart,
            end: unsupportedStart.addingTimeInterval(12),
            rows: 6,
            validatedRows: 6,
            stillnessRatio: 1,
            movementIntensity: 0,
            p95VectorDelta: 0,
            maximumGapSeconds: 2,
            measurementValidated: true,
            lowMotionQualified: true,
            reason: "duplicated reconnect tail"
        )
        var motion = (0..<60)
            .filter { $0 != unsupportedIndex }
            .map { epoch(index: $0, stillness: 1, intensity: 0) }
        motion.append(duplicatedTail)
        motion.append(duplicatedTail)

        XCTAssertTrue(AtriaRecoveredMotionAnalytics.sleepProvenance(
            epochs: motion,
            start: start,
            end: end
        ).measurementSufficient,
        "whole-night union remains sufficient so the regression exercises local qualification")

        let stages = AtriaSleepWakeResearch.stageSegments(
            samples: heartRate,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: motion
        )

        XCTAssertFalse(stages.isEmpty)
        XCTAssertNil(stage(at: unsupportedStart.addingTimeInterval(20), in: stages),
                     "two copies of the same 12 seconds remain 40% unique support, not 80%")
    }

    func testExactDuplicateFullEpochCountsOnceWithoutWithholdingValidStage() {
        let end = start.addingTimeInterval(30 * 60)
        let heartRate = stride(from: 0, through: 30 * 60, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(Double($0)),
                bpm: 62
            )
        }
        let duplicatedIndex = 20
        let duplicatedStart = start.addingTimeInterval(Double(duplicatedIndex) * 30)
        var motion = (0..<60).map { epoch(index: $0, stillness: 1, intensity: 0) }
        motion.append(epoch(index: duplicatedIndex, stillness: 1, intensity: 0))

        let stages = AtriaSleepWakeResearch.stageSegments(
            samples: heartRate,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: motion
        )

        XCTAssertNotNil(stage(at: duplicatedStart.addingTimeInterval(15), in: stages),
                        "an identical replay is one full measured epoch, not a conflict")
    }

    func testConflictingOverlappingMotionMeasurementsFailEpochClosed() {
        let end = start.addingTimeInterval(30 * 60)
        let heartRate = stride(from: 0, through: 30 * 60, by: 5).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(Double($0)),
                bpm: 62
            )
        }
        let conflictIndex = 20
        let conflictStart = start.addingTimeInterval(Double(conflictIndex) * 30)
        var motion = (0..<60).map { epoch(index: $0, stillness: 1, intensity: 0) }
        motion.append(AtriaRecoveredMotionEpoch(
            start: conflictStart,
            end: conflictStart.addingTimeInterval(30),
            rows: 15,
            validatedRows: 15,
            stillnessRatio: 0.3,
            movementIntensity: 0.5,
            p95VectorDelta: 0.5,
            maximumGapSeconds: 2,
            measurementValidated: true,
            lowMotionQualified: false,
            reason: "conflicting reconnect projection"
        ))

        let stages = AtriaSleepWakeResearch.stageSegments(
            samples: heartRate,
            start: start,
            end: end,
            restingHR: 60,
            isNap: false,
            motionValidated: false,
            motionEpochs: motion
        )

        XCTAssertFalse(stages.isEmpty)
        XCTAssertNil(stage(at: conflictStart.addingTimeInterval(15), in: stages),
                     "overlapping measurements that disagree cannot be averaged into a stage")
    }

    private func epoch(index: Int,
                       stillness: Double,
                       intensity: Double) -> AtriaRecoveredMotionEpoch {
        let epochStart = start.addingTimeInterval(Double(index) * 30)
        return .init(start: epochStart,
                     end: epochStart.addingTimeInterval(30),
                     rows: 15,
                     validatedRows: 15,
                     stillnessRatio: stillness,
                     movementIntensity: intensity,
                     p95VectorDelta: intensity,
                     maximumGapSeconds: 2,
                     measurementValidated: true,
                     lowMotionQualified: stillness >= 0.72 && intensity <= 0.18,
                     reason: "test")
    }

    private func stage(at date: Date, in segments: [SleepStageSegment]) -> SleepStageKind? {
        segments.first { $0.start <= date && $0.end > date }?.stage
    }
}
