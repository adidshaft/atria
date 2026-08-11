import XCTest
@testable import Atria

/// Regression coverage for the HR-only presentation boundary. Raw stage-engine
/// output may remain available to storage/research, but without validated motion
/// it must never be rewritten into or rendered as Awake/REM/Light/Deep precision.
final class AtriaSleepEstimateReconcileTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026,
                                           month: 8,
                                           day: 8,
                                           hour: hour,
                                           minute: minute))!
    }

    private func segment(_ id: String,
                         _ stage: SleepStageKind,
                         _ start: Date,
                         _ end: Date) -> SleepStageSegment {
        SleepStageSegment(id: id, start: start, end: end, stage: stage)
    }

    private func night(segments: [SleepStageSegment],
                       motionValidated: Bool,
                       confidence: String,
                       source: String = "aggregate_sleep",
                       duration: TimeInterval? = nil,
                       observedDuration: TimeInterval? = nil) -> SleepHistorySnapshot.Night {
        let start = date(0)
        let end = date(6)
        return SleepHistorySnapshot.Night(id: "night",
                                          day: calendar.startOfDay(for: end),
                                          start: start,
                                          end: end,
                                          duration: duration ?? end.timeIntervalSince(start),
                                          observedDuration: observedDuration,
                                          restingHR: 55,
                                          hrv: 40,
                                          respiratoryRate: 11,
                                          sleepEfficiency: 0.9,
                                          confidence: confidence,
                                          source: source,
                                          confirmed: true,
                                          stageSegments: segments,
                                          motionValidated: motionValidated)
    }

    private var awakeHeavySegments: [SleepStageSegment] {
        [
            segment("light-1", .light, date(0), date(0, 30)),
            segment("deep", .deep, date(0, 30), date(2)),
            segment("awake", .awake, date(2), date(4)),
            segment("rem", .rem, date(4), date(5)),
            segment("light-2", .light, date(5), date(6))
        ]
    }

    func testAwakeHeavyHROnlyOutputIsKeptRawButNeverExposedAsStagePrecision() {
        let raw = awakeHeavySegments
        let result = night(segments: raw,
                           motionValidated: false,
                           confidence: "user_confirmed_hr_only")

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertEqual(result.stageSegments, raw,
                       "captured stage-engine output must not be rewritten to fabricate sleep")
        XCTAssertTrue(result.displayStageSegments.isEmpty,
                      "HR-only output must not feed any stage-rendering surface")
        for stage in SleepStageKind.allCases {
            XCTAssertEqual(result.stageDuration(stage), 0,
                           "HR-only stage durations must remain withheld")
        }

        let card = AtriaSleepHypnogramCard(night: result)
        XCTAssertTrue(card.segments.isEmpty)
        XCTAssertTrue(AtriaSleepHypnogramPresentation.legend(for: card.segments).isEmpty,
                      "with no card segments, no stage percentage can be derived")
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: card.segments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .estimate)
        XCTAssertEqual(AtriaSleepHypnogramCard.measuredHeartRateText(card.measuredHeartRate),
                       "Measured resting HR · 55 bpm")
    }

    func testHROnlyStorageFeedRemainsAvailableWithoutBecomingADisplayFeed() {
        let result = night(segments: awakeHeavySegments,
                           motionValidated: false,
                           confidence: "settled")

        XCTAssertFalse(result.stageSegmentsForStorage.isEmpty,
                       "the truthfulness fix must not discard captured engine data")
        XCTAssertTrue(result.displayStageSegments.isEmpty)
        XCTAssertTrue(AtriaSleepHypnogramCard(night: result).segments.isEmpty)
    }

    func testMotionBackedResearchStagesKeepTheirExistingTimelineAndDurations() {
        let segments = [
            segment("light", .light, date(0), date(2)),
            segment("deep", .deep, date(2), date(4)),
            segment("rem", .rem, date(4), date(6))
        ]
        let result = night(segments: segments,
                           motionValidated: true,
                           confidence: "ready")

        XCTAssertEqual(result.stageEvidence, .sensorResearch)
        XCTAssertEqual(result.displayStageSegments.map(\.stage), [.light, .deep, .rem])
        XCTAssertEqual(result.stageDuration(.light), 2 * 3_600, accuracy: 0.01)
        XCTAssertEqual(result.stageDuration(.deep), 2 * 3_600, accuracy: 0.01)
        XCTAssertEqual(result.stageDuration(.rem), 2 * 3_600, accuracy: 0.01)
        XCTAssertEqual(AtriaSleepHypnogramCard(night: result).segments,
                       result.displayStageSegments)
    }

    func testV2TimeAlignedStageReceiptRendersEvenWhenWholeNightLowMotionIsFalse() throws {
        let legacy = awakeHeavySegments
        let v2 = legacy.enumerated().map { index, segment in
            SleepStageSegment(id: "research-motion-v2-\(index)-\(segment.stage.rawValue)",
                              start: segment.start,
                              end: segment.end,
                              stage: segment.stage)
        }
        let physiologicalTST: TimeInterval = 4 * 60 * 60
        let observed: TimeInterval = 6 * 60 * 60
        let motionBacked = night(segments: v2,
                                 motionValidated: false,
                                 confidence: "user_adjusted_hr_only",
                                 duration: physiologicalTST,
                                 observedDuration: observed)
        let legacyWithoutReceipt = night(segments: legacy,
                                         motionValidated: false,
                                         confidence: "user_adjusted_hr_only",
                                         duration: physiologicalTST,
                                         observedDuration: observed)

        XCTAssertTrue(motionBacked.hasValidatedMotionEvidence,
                      "v2 IDs are emitted only after dense local HR and measured motion pass")
        XCTAssertEqual(motionBacked.stageEvidence, .sensorResearch)
        XCTAssertEqual(motionBacked.displayStageSegments.map(\.stage),
                       [.light, .deep, .awake, .rem, .light])
        XCTAssertEqual(try XCTUnwrap(motionBacked.displaySleepEfficiency), 0.9)

        XCTAssertFalse(legacyWithoutReceipt.hasValidatedMotionEvidence)
        XCTAssertEqual(legacyWithoutReceipt.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(legacyWithoutReceipt.displayStageSegments.isEmpty,
                      "legacy or aggregate IDs cannot turn a scalar false into motion proof")
        XCTAssertNil(legacyWithoutReceipt.displaySleepEfficiency)
    }

    func testValidatedStagesKeepTheirExistingTimelineEvenWithoutExplicitMotionFlag() {
        let segments = [
            segment("light", .light, date(0), date(2)),
            segment("deep", .deep, date(2), date(4)),
            segment("rem", .rem, date(4), date(6))
        ]
        let result = night(segments: segments,
                           motionValidated: false,
                           confidence: "ready",
                           source: "validated_sleep_stages")

        XCTAssertEqual(result.stageEvidence, .validated)
        XCTAssertEqual(result.displayStageSegments, segments)
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: result.displayStageSegments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .timeline)
    }
}
