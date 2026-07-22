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
        let heartRate = (0...60).map {
            AtriaSleepWakeResearch.HeartSample(
                t: start.addingTimeInterval(Double($0) * 30),
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
                                                               motionValidated: true,
                                                               motionEpochs: earlyMovement)
        let lateStages = AtriaSleepWakeResearch.stageSegments(samples: heartRate,
                                                              start: start,
                                                              end: end,
                                                              restingHR: 60,
                                                              isNap: false,
                                                              motionValidated: true,
                                                              motionEpochs: lateMovement)

        XCTAssertEqual(stage(at: start.addingTimeInterval(10 * 30 + 1), in: earlyStages), .awake)
        XCTAssertNotEqual(stage(at: start.addingTimeInterval(10 * 30 + 1), in: lateStages), .awake)
        XCTAssertNotEqual(stage(at: start.addingTimeInterval(40 * 30 + 1), in: earlyStages), .awake)
        XCTAssertEqual(stage(at: start.addingTimeInterval(40 * 30 + 1), in: lateStages), .awake)
        XCTAssertNotEqual(earlyStages, lateStages,
                          "equal whole-window averages must not preserve stale per-epoch stages")
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
