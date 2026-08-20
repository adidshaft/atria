import XCTest
@testable import Atria

/// P8 legibility pins (2026-08-20 sleep-stage design, Track 2 §2.1 + phased
/// order P8): the sub-0.60 coarse fallback and the "why tonight is an
/// estimate" line. New file — never edits the pre-existing pinned strings
/// (`AtriaSleepStageEstimateLabel.caption`, tier captions,
/// `unavailableStagesDetail`); fixtures use a post-2026-08-06 time base.
final class AtriaSleepCoarseFallbackTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026,
                                           month: 8,
                                           day: 14,
                                           hour: hour,
                                           minute: minute))!
    }

    private func segment(_ id: String,
                         _ stage: SleepStageKind,
                         _ start: Date,
                         _ end: Date) -> SleepStageSegment {
        SleepStageSegment(id: id, start: start, end: end, stage: stage)
    }

    /// Structurally valid (full coverage, ordered, no gaps) but its awake is
    /// all BOUNDARY awake, which presentation reconciliation deliberately
    /// leaves alone — so the strict reconcile fails, display segments stay
    /// empty, and the card lands in the generic `.estimate` capsule state.
    private var boundaryAwakeHeavySegments: [SleepStageSegment] {
        [
            segment("awake-lead", .awake, date(0), date(2)),
            segment("light", .light, date(2), date(4)),
            segment("awake-tail", .awake, date(4), date(6))
        ]
    }

    private func night(confirmed: Bool,
                       duration: TimeInterval,
                       segments: [SleepStageSegment]) -> SleepHistorySnapshot.Night {
        let start = date(0)
        let end = date(6)
        return SleepHistorySnapshot.Night(id: "coarse-night",
                                          day: calendar.startOfDay(for: end),
                                          start: start,
                                          end: end,
                                          duration: duration,
                                          restingHR: 52,
                                          hrv: 44,
                                          respiratoryRate: 12,
                                          sleepEfficiency: 0.9,
                                          confidence: "settled",
                                          source: "aggregate_sleep",
                                          confirmed: confirmed,
                                          stageSegments: segments,
                                          motionValidated: false)
    }

    // MARK: - "Why tonight is an estimate" copy pins (new strings, new pins)

    func testWhyEstimateLineNamesTheActualCausePerTransport() {
        XCTAssertEqual(
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .catchingUp),
            "Strap was in HR-only mode — motion data pending; a catch-up sync can still upgrade this night."
        )
        XCTAssertEqual(
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .unavailableInCurrentTransport),
            "Strap was in HR-only mode — this link cannot sync motion right now, so this night stays an estimate."
        )
        // Unknown transport evidence never asserts a strap mode as fact.
        let generic = "Motion evidence for this night hasn't synced, so Atria estimated from heart rate alone."
        XCTAssertEqual(AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: nil), generic)
        XCTAssertEqual(AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .unknown), generic)
        XCTAssertEqual(AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .stale), generic)
    }

    func testTimelineWhyLineOnlyAddsTransportTruthTheTierCaptionsLack() {
        // Where the mandatory estimate label + caption already render, the
        // why line appears only for transport states that add real outlook —
        // never a restatement of the P2 tier captions.
        XCTAssertEqual(
            AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: .catchingUp),
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .catchingUp)
        )
        XCTAssertEqual(
            AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: .unavailableInCurrentTransport),
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .unavailableInCurrentTransport)
        )
        XCTAssertNil(AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: nil))
        XCTAssertNil(AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: .unknown))
        XCTAssertNil(AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: .live))
        XCTAssertNil(AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: .qualifying))
        XCTAssertNil(AtriaSleepHypnogramCard.timelineWhyEstimateLine(motionAvailability: .stale))

        // The new lines are their own copy — none of the pinned estimate
        // captions is duplicated or edited.
        for line in [
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .catchingUp),
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: .unavailableInCurrentTransport),
            AtriaSleepHypnogramCard.whyEstimateLine(motionAvailability: nil)
        ] {
            XCTAssertNotEqual(line, AtriaSleepStageEstimateLabel.caption)
            XCTAssertNotEqual(line, AtriaSleepStageEstimateLabel.strongRRCaption)
            XCTAssertNotEqual(line, AtriaSleepStageEstimateLabel.standardCaption)
        }
    }

    // MARK: - Coarse totals math (pure, no fabricated stages)

    func testCoarseNightTotalsSplitTheSavedWindowHonestly() throws {
        // 6h window, 4.5h saved sleep total → 270m asleep, 90m remainder.
        let totals = try XCTUnwrap(
            AtriaSleepHypnogramCard.coarseNightTotals(windowStart: date(0),
                                                      windowEnd: date(6),
                                                      sleepDuration: 4.5 * 3_600)
        )
        XCTAssertEqual(totals.asleepMinutes, 270)
        XCTAssertEqual(totals.awakeOrUnmeasuredMinutes, 90)

        // Saved total covering the whole window: remainder is an honest 0.
        let full = try XCTUnwrap(
            AtriaSleepHypnogramCard.coarseNightTotals(windowStart: date(0),
                                                      windowEnd: date(6),
                                                      sleepDuration: 6 * 3_600)
        )
        XCTAssertEqual(full.asleepMinutes, 360)
        XCTAssertEqual(full.awakeOrUnmeasuredMinutes, 0)

        // Contradictory data (saved total exceeds the window) fails toward
        // the saved number — never negative wake time.
        let contradictory = try XCTUnwrap(
            AtriaSleepHypnogramCard.coarseNightTotals(windowStart: date(0),
                                                      windowEnd: date(6),
                                                      sleepDuration: 7 * 3_600)
        )
        XCTAssertEqual(contradictory.asleepMinutes, 420)
        XCTAssertEqual(contradictory.awakeOrUnmeasuredMinutes, 0)

        // No saved total / no real window → no totals, never a guess.
        XCTAssertNil(AtriaSleepHypnogramCard.coarseNightTotals(windowStart: date(0),
                                                               windowEnd: date(6),
                                                               sleepDuration: nil))
        XCTAssertNil(AtriaSleepHypnogramCard.coarseNightTotals(windowStart: date(0),
                                                               windowEnd: date(6),
                                                               sleepDuration: 0))
        XCTAssertNil(AtriaSleepHypnogramCard.coarseNightTotals(windowStart: date(6),
                                                               windowEnd: date(0),
                                                               sleepDuration: 3_600))
    }

    func testCoarseCopyPins() {
        XCTAssertEqual(AtriaSleepHypnogramCard.coarseAsleepTotalLabel, "Asleep")
        XCTAssertEqual(AtriaSleepHypnogramCard.coarseAwakeTotalLabel, "Awake or unmeasured")
        // An honest zero reads "0m", never the unknown "--".
        XCTAssertEqual(AtriaSleepHypnogramCard.coarseTotalText(minutes: 0), "0m")
        XCTAssertEqual(AtriaSleepHypnogramCard.coarseTotalText(minutes: 90), "1h 30m")
        XCTAssertEqual(AtriaSleepHypnogramCard.coarseTotalText(minutes: 45), "45m")
    }

    // MARK: - The no-stages confirmed-night totals path

    func testConfirmedHROnlyNightWithoutReconcilableStagesRendersCoarseTotals() throws {
        let result = night(confirmed: true,
                           duration: 4.5 * 3_600,
                           segments: boundaryAwakeHeavySegments)

        // The fail-closed pipeline is untouched: boundary-awake-heavy output
        // cannot reconcile, so NO stage bars render — evidence stays the
        // labeled HR-only estimate with an empty display timeline.
        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(result.displayStageSegments.isEmpty,
                      "boundary awake is credible evidence; reconciliation must fail closed")
        XCTAssertFalse(result.isEstimatedStageDisplay)

        let card = AtriaSleepHypnogramCard(night: result)
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: card.segments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .estimate)

        // The canonical night init threads the saved duration authority and
        // the confirmation state — the totals are the record's own numbers.
        XCTAssertEqual(card.sleepTotalSeconds, result.duration)
        XCTAssertTrue(card.isConfirmedNight)
        let totals = try XCTUnwrap(card.coarseTotals,
                                   "a confirmed no-stages HR-only night renders coarse sleep/wake totals")
        XCTAssertEqual(totals.asleepMinutes, 270)
        XCTAssertEqual(totals.awakeOrUnmeasuredMinutes, 90)
    }

    func testUnconfirmedNightKeepsTheGenericCapsuleWithoutTotals() {
        let result = night(confirmed: false,
                           duration: 4.5 * 3_600,
                           segments: boundaryAwakeHeavySegments)

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(result.displayStageSegments.isEmpty)

        let card = AtriaSleepHypnogramCard(night: result)
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: card.segments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .estimate)
        XCTAssertFalse(card.isConfirmedNight)
        XCTAssertNil(card.coarseTotals,
                     "an unconfirmed candidate must never gain totals-style authority")
    }

    func testLabeledEstimateTimelineNeverShowsCoarseTotals() {
        // Interior over-called awake reconciles for display → the labeled
        // estimate timeline renders, whose legend already carries real stage
        // minutes; the coarse totals belong to the no-stages state only.
        let reconcilable = [
            segment("light-1", .light, date(0), date(0, 30)),
            segment("deep", .deep, date(0, 30), date(2)),
            segment("awake", .awake, date(2), date(4)),
            segment("rem", .rem, date(4), date(5)),
            segment("light-2", .light, date(5), date(6))
        ]
        let result = night(confirmed: true,
                           duration: 6 * 3_600,
                           segments: reconcilable)

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(result.isEstimatedStageDisplay)

        let card = AtriaSleepHypnogramCard(night: result)
        XCTAssertEqual(AtriaSleepHypnogramCard.displayState(segments: card.segments,
                                                            stageEvidence: result.stageEvidence,
                                                            start: result.start,
                                                            end: result.end),
                       .estimatedTimeline)
        XCTAssertNil(card.coarseTotals,
                     "totals never render beside a real stage timeline")
    }
}
