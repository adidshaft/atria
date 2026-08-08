import XCTest
@testable import Atria

/// The display-only HR sleep-stage estimate (2026-08-08). Without validated
/// motion the stage engine over-calls `.awake`, so a confirmed HR-only night's
/// non-awake time falls short of the credited sleep duration and the strict
/// presentation reconcile hides the hypnogram behind "unavailable". These tests
/// lock the rebalance (`reconciledEstimateSegments`) and the evidence rescue so
/// a clearly-labeled estimate shows AND never contradicts the hero hours — while
/// nothing is persisted and no numeric surface moves.
final class AtriaSleepEstimateReconcileTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "GMT")!; return c
    }
    private func d(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: h, minute: m))!
    }
    private func seg(_ id: String, _ stage: SleepStageKind, _ from: Date, _ to: Date) -> SleepStageSegment {
        SleepStageSegment(id: id, start: from, end: to, stage: stage)
    }
    private func reconcile(_ segs: [SleepStageSegment], _ start: Date, _ end: Date, _ dur: TimeInterval) -> [SleepStageSegment] {
        SleepHistorySnapshot.Night.reconciledEstimateSegments(
            from: segs, start: start, end: end, effectiveSleepDuration: dur)
    }
    private func nonAwake(_ segs: [SleepStageSegment]) -> TimeInterval {
        segs.reduce(0) { $0 + ($1.stage == .awake ? 0 : $1.duration) }
    }

    // MARK: - reconciledEstimateSegments

    func testOverAwakeInteriorReconcilesToCreditedDuration() {
        let start = d(0), end = d(6), dur: TimeInterval = 6 * 3600
        let segs = [
            seg("a", .light, d(0), d(0, 30)),
            seg("b", .deep, d(0, 30), d(2)),
            seg("c", .awake, d(2), d(4)),        // 2h interior over-call
            seg("d", .rem, d(4), d(5)),
            seg("e", .light, d(5), d(6)),
        ]
        XCTAssertFalse(AtriaSleepStageIntegrity.reconcilesForPresentation(segs, effectiveSleepDuration: dur),
                       "raw over-awake input must NOT reconcile (that's the bug)")
        let out = reconcile(segs, start, end, dur)
        XCTAssertTrue(AtriaSleepStageIntegrity.reconcilesForPresentation(out, effectiveSleepDuration: dur),
                      "reconciled estimate must agree with the credited hours")
        XCTAssertEqual(nonAwake(out), dur, accuracy: 5 * 60)
    }

    func testLeadingAndTrailingAwakeArePreserved() {
        let start = d(0), end = d(8), dur: TimeInterval = 7 * 3600  // 30m onset + 30m final awake
        let segs = [
            seg("wake_in", .awake, d(0), d(0, 30)),   // onset latency — keep
            seg("light1", .light, d(0, 30), d(2)),
            seg("awake_mid", .awake, d(2), d(3)),     // interior over-call — convert
            seg("deep1", .deep, d(3), d(6)),
            seg("rem1", .rem, d(6), d(7, 30)),
            seg("wake_out", .awake, d(7, 30), d(8)),  // final waking — keep
        ]
        let out = reconcile(segs, start, end, dur)
        XCTAssertEqual(out.first?.stage, .awake, "sleep-onset latency must stay awake")
        XCTAssertEqual(out.last?.stage, .awake, "final waking must stay awake")
        XCTAssertTrue(AtriaSleepStageIntegrity.reconcilesForPresentation(out, effectiveSleepDuration: dur))
    }

    func testAlreadyReconcilingInputIsUnchanged() {
        let start = d(0), end = d(6), dur: TimeInterval = 6 * 3600
        let segs = [
            seg("a", .light, d(0), d(2)),
            seg("b", .deep, d(2), d(4)),
            seg("c", .rem, d(4), d(6)),
        ]
        let out = reconcile(segs, start, end, dur)
        XCTAssertEqual(out.map(\.stage), [.light, .deep, .rem], "no fabrication when it already reconciles")
        XCTAssertEqual(nonAwake(out), dur, accuracy: 1)
    }

    func testSurplusNonAwakeIsTrimmedNeverOverclaims() {
        let start = d(0), end = d(8), dur: TimeInterval = 6 * 3600  // only 6h credited
        let segs = [
            seg("a", .deep, d(0), d(4)),
            seg("b", .light, d(4), d(8)),            // 8h non-awake, must not claim all
        ]
        let out = reconcile(segs, start, end, dur)
        XCTAssertLessThanOrEqual(nonAwake(out), dur + 5 * 60,
                                 "estimate must never claim MORE sleep than the credited hours")
        XCTAssertTrue(AtriaSleepStageIntegrity.reconcilesForPresentation(out, effectiveSleepDuration: dur))
    }

    func testAllAwakeReturnsHonestFallbackNoCrash() {
        let start = d(0), end = d(6), dur: TimeInterval = 6 * 3600
        // No sleep epoch at all -> nothing to build a hypnogram from.
        let segs = [seg("a", .awake, d(0), d(6))]
        let out = reconcile(segs, start, end, dur)
        XCTAssertFalse(out.isEmpty)  // returns folded; card then falls back to an honest state
        XCTAssertFalse(AtriaSleepStageIntegrity.reconcilesForPresentation(out, effectiveSleepDuration: dur),
                       "an all-awake window cannot honestly reconcile into a hypnogram")
    }

    /// Mirrors the real device night (Sat 03:23-09:54, user_adjusted_sleep, 131
    /// segments): the credited hours fill the whole span, the engine over-called
    /// ~3h of awake scattered across the night, and the estimate must still
    /// reconcile by absorbing that awake into light (there is no awake budget).
    func testFullWindowCreditedNightAbsorbsScatteredAwake() {
        let start = d(0), end = d(6, 30), dur: TimeInterval = 6.5 * 3600  // span == credited
        let segs = [
            seg("w0", .awake, d(0), d(0, 40)),       // edge over-call
            seg("deep1", .deep, d(0, 40), d(2, 40)),
            seg("w1", .awake, d(2, 40), d(3, 40)),   // interior over-call
            seg("rem1", .rem, d(3, 40), d(4, 40)),
            seg("w2", .awake, d(4, 40), d(5, 40)),   // interior over-call
            seg("light1", .light, d(5, 40), d(6, 10)),
            seg("w3", .awake, d(6, 10), d(6, 30)),   // edge over-call
        ]
        XCTAssertFalse(AtriaSleepStageIntegrity.reconcilesForPresentation(segs, effectiveSleepDuration: dur))
        let out = reconcile(segs, start, end, dur)
        XCTAssertTrue(AtriaSleepStageIntegrity.reconcilesForPresentation(out, effectiveSleepDuration: dur),
                      "a full-window confirmed night must reconcile by absorbing over-called awake")
        // Real stage structure is preserved (deep + rem survive; not a flat smear).
        let stages = Set(out.map(\.stage))
        XCTAssertTrue(stages.contains(.deep) && stages.contains(.rem),
                      "deep/REM structure must survive the rebalance")
    }

    // MARK: - Night rescue (evidence + display feed + numeric isolation)

    private func hrOnlyNight(segments: [SleepStageSegment], start: Date, end: Date) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: "n1",
                                   day: cal.startOfDay(for: end),
                                   start: start,
                                   end: end,
                                   duration: end.timeIntervalSince(start),
                                   restingHR: 55,
                                   hrv: 40,
                                   respiratoryRate: 11.0,
                                   sleepEfficiency: 0.9,
                                   confidence: "user_confirmed_hr_only",
                                   source: "aggregate_sleep",
                                   confirmed: true,
                                   stageSegments: segments,
                                   motionValidated: false)
    }

    func testOverAwakeHrOnlyNightIsRescuedToLabeledReconciledEstimate() {
        let start = d(0), end = d(6)
        let over = [
            seg("a", .light, d(0), d(0, 30)),
            seg("b", .deep, d(0, 30), d(2)),
            seg("c", .awake, d(2), d(4)),   // over-called; would fail strict reconcile
            seg("d", .rem, d(4), d(5)),
            seg("e", .light, d(5), d(6)),
        ]
        let night = hrOnlyNight(segments: over, start: start, end: end)
        // Rescued into a labeled estimate rather than collapsing to .none/"building".
        XCTAssertEqual(night.stageEvidence, .hrOnlyEstimate)
        // Numeric/persistence gate stays honest: NO display segments feed metrics.
        XCTAssertTrue(night.displayStageSegments.isEmpty)
        // The estimate feed exists, reconciles with the credited hours, and drives .estimate.
        XCTAssertFalse(night.estimatedDisplayStageSegments.isEmpty)
        XCTAssertTrue(AtriaSleepStageIntegrity.reconcilesForPresentation(
            night.estimatedDisplayStageSegments, effectiveSleepDuration: night.duration))
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: night.estimatedDisplayStageSegments,
                                                            stageEvidence: night.stageEvidence,
                                                            start: night.start,
                                                            end: night.end),
                       .estimate)
    }

    func testValidatedMotionNightIsNeverDowngradedToEstimate() {
        let start = d(0), end = d(6)
        let over = [
            seg("a", .light, d(0), d(0, 30)),
            seg("b", .deep, d(0, 30), d(2)),
            seg("c", .awake, d(2), d(4)),
            seg("d", .rem, d(4), d(5)),
            seg("e", .light, d(5), d(6)),
        ]
        // Same non-reconciling segments, but motion is validated: must NOT become an estimate.
        let night = SleepHistorySnapshot.Night(id: "n2",
                                               day: cal.startOfDay(for: end),
                                               start: start,
                                               end: end,
                                               duration: end.timeIntervalSince(start),
                                               restingHR: 55,
                                               hrv: 40,
                                               respiratoryRate: 11.0,
                                               sleepEfficiency: 0.9,
                                               confidence: "user_confirmed_motion_validated",
                                               source: "aggregate_sleep",
                                               confirmed: true,
                                               stageSegments: over,
                                               motionValidated: true)
        XCTAssertNotEqual(night.stageEvidence, .hrOnlyEstimate,
                          "a validated-motion night is never downgraded to an HR estimate")
        XCTAssertTrue(night.estimatedDisplayStageSegments.isEmpty)
    }
}
