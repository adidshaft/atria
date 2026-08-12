import XCTest
@testable import Atria

/// Regression coverage for the HR-only presentation boundary (updated
/// 2026-08-12, c7c15e1d labeled-estimate product). A confirmed HR-only night
/// with an integrity-valid timeline renders a display-only RECONCILED
/// hypnogram — but only under the mandatory `AtriaSleepStageEstimateLabel`,
/// with stored segments untouched and the displayed non-awake total never
/// exceeding the credited effective sleep. Motion-validated rendering stays
/// byte-identical; integrity failures, naps, unconfirmed candidates, and
/// manual windows stay hidden.
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

    // (a) An hrOnlyEstimate night with valid segments renders reconciled
    // display segments — and the estimate LABEL is mandatory with them.
    func testAwakeHeavyHROnlyNightRendersReconciledEstimateWithMandatoryLabel() {
        let raw = awakeHeavySegments
        let result = night(segments: raw,
                           motionValidated: false,
                           confidence: "user_confirmed_hr_only")

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertEqual(result.stageSegments, raw,
                       "captured stage-engine output must never be rewritten by presentation")
        XCTAssertFalse(result.displayStageSegments.isEmpty,
                       "a confirmed integrity-valid HR-only night now renders a labeled estimate")
        XCTAssertTrue(result.isEstimatedStageDisplay)
        XCTAssertEqual(result.stageDisplayLabel, AtriaSleepStageEstimateLabel.title)
        XCTAssertEqual(result.stageDisplayLabel, "Estimated stages · HR-only")
        XCTAssertEqual(AtriaSleepStageEstimateLabel.caption,
                       "Motion not available — stage boundaries are estimates from heart rate and breathing.")

        // The engine's 2h interior awake over-call is reconciled for display:
        // non-awake matches the credited 6h effective sleep exactly.
        let displayedNonAwake = result.displayStageSegments
            .filter { $0.stage != .awake }
            .reduce(0) { $0 + $1.duration }
        XCTAssertEqual(displayedNonAwake, result.duration, accuracy: 1)
        XCTAssertEqual(result.stageDuration(.awake), 0, accuracy: 1,
                       "the over-called interior awake folds into its neighbor for display")

        let card = AtriaSleepHypnogramCard(night: result)
        XCTAssertEqual(card.segments, result.displayStageSegments,
                       "the card feeds only reconciled display segments, never raw output")
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: card.segments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .estimatedTimeline)
        XCTAssertEqual(AtriaSleepHypnogramCard.measuredHeartRateText(card.measuredHeartRate),
                       "Measured resting HR · 55 bpm")
    }

    func testHROnlyStorageFeedStaysRawWhileDisplayIsReconciled() {
        let result = night(segments: awakeHeavySegments,
                           motionValidated: false,
                           confidence: "settled")

        XCTAssertFalse(result.stageSegmentsForStorage.isEmpty,
                       "the presentation product must not discard captured engine data")
        // Storage keeps the engine's 2h awake verbatim; only display reconciles.
        let storedAwake = result.stageSegmentsForStorage
            .filter { $0.stage == .awake }
            .reduce(0) { $0 + $1.duration }
        XCTAssertEqual(storedAwake, 2 * 3_600, accuracy: 1)
        XCTAssertFalse(result.displayStageSegments.isEmpty)
        XCTAssertNotEqual(result.displayStageSegments, result.stageSegmentsForStorage,
                          "display reconciliation must never leak back into the storage feed")
    }

    // (c) Integrity-failing timelines (impossible overlap) stay hidden — no
    // estimate presentation can be reconciled out of a broken timeline.
    func testIntegrityFailingHROnlySegmentsStayHidden() {
        let overlapping = [
            segment("light", .light, date(0), date(3)),
            segment("deep", .deep, date(2, 30), date(6))
        ]
        let result = night(segments: overlapping,
                           motionValidated: false,
                           confidence: "settled")

        XCTAssertTrue(result.displayStageSegments.isEmpty,
                      "an impossible timeline must never render, even as an estimate")
        XCTAssertFalse(result.isEstimatedStageDisplay)
        XCTAssertEqual(result.stageSegments, overlapping,
                       "hiding is presentation-only; stored segments stay untouched")
    }

    // (d) The reconciled display never exceeds the credited effective sleep:
    // a within-tolerance surplus is trimmed from the end of the timeline.
    func testReconciledDisplayNeverExceedsEffectiveSleepDuration() {
        let allDeep = [segment("deep", .deep, date(0), date(6))]      // 21,600s
        let credited: TimeInterval = 21_000                            // 5h50m
        let result = night(segments: allDeep,
                           motionValidated: false,
                           confidence: "user_confirmed_hr_only",
                           duration: credited)

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(result.isEstimatedStageDisplay)
        let displayedNonAwake = result.displayStageSegments
            .filter { $0.stage != .awake }
            .reduce(0) { $0 + $1.duration }
        XCTAssertEqual(displayedNonAwake, credited, accuracy: 1)
        XCTAssertLessThanOrEqual(displayedNonAwake, credited + 1,
                                 "estimated display must never claim more sleep than is credited")
        // Storage still carries the full engine segment.
        XCTAssertEqual(result.stageSegmentsForStorage.reduce(0) { $0 + $1.duration },
                       21_600,
                       accuracy: 1)
    }

    // Naps and unconfirmed candidates keep the all-hidden presentation.
    func testConfirmedNapAndUnconfirmedCandidateStayHidden() {
        let sleepShaped = [
            segment("light", .light, date(0), date(2)),
            segment("deep", .deep, date(2), date(4)),
            segment("rem", .rem, date(4), date(6))
        ]
        let nap = night(segments: sleepShaped,
                        motionValidated: false,
                        confidence: "settled",
                        source: "auto_nap")
        XCTAssertTrue(nap.displayStageSegments.isEmpty,
                      "naps must not gain an estimated hypnogram")

        let start = date(0)
        let end = date(6)
        let candidate = SleepHistorySnapshot.Night(id: "candidate",
                                                   day: calendar.startOfDay(for: end),
                                                   start: start,
                                                   end: end,
                                                   duration: end.timeIntervalSince(start),
                                                   restingHR: 55,
                                                   hrv: nil,
                                                   respiratoryRate: nil,
                                                   sleepEfficiency: nil,
                                                   confidence: "settled",
                                                   source: "sleep_candidate",
                                                   confirmed: false,
                                                   stageSegments: sleepShaped,
                                                   motionValidated: false)
        XCTAssertTrue(candidate.displayStageSegments.isEmpty,
                      "unconfirmed candidates must not gain an estimated hypnogram")
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
        // (b) Motion-backed rendering keeps its authority: never relabeled
        // as an HR-only estimate, and the display state stays `.timeline`.
        XCTAssertFalse(result.isEstimatedStageDisplay)
        XCTAssertEqual(result.stageDisplayLabel, "Estimated stages")
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: result.displayStageSegments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .timeline)
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
        XCTAssertEqual(legacyWithoutReceipt.stageEvidence, .hrOnlyEstimate,
                       "legacy or aggregate IDs cannot turn a scalar false into motion proof")
        // The legacy night still renders — but strictly as the labeled
        // estimate, never with the receipt-backed `.sensorResearch` authority.
        XCTAssertTrue(legacyWithoutReceipt.isEstimatedStageDisplay)
        XCTAssertEqual(legacyWithoutReceipt.stageDisplayLabel, AtriaSleepStageEstimateLabel.title)
        XCTAssertEqual(legacyWithoutReceipt.displayStageSegments.map(\.stage),
                       [.light, .deep, .awake, .rem, .light],
                       "already-reconciled HR-only timelines display verbatim (folded)")
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
