import XCTest
@testable import Atria

final class AtriaDailyStepPresentationTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 2_004_048_000)

    func testVerifiedCompleteCanonicalDayIsShownExactly() {
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 86_400),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .available,
                                    stepCount: 8_412,
                                    known: 8_412,
                                    covered: 86_400,
                                    missing: 0)],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 8_412)
        XCTAssertEqual(value.completeness, .complete)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertEqual(value.valueText, "8412")
        XCTAssertEqual(value.detailText, "Verified complete day")
    }

    func testExactCanonicalTotalRemainsAuthoritativeOverFreshValidatedLive() {
        let capturedAt = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: capturedAt.addingTimeInterval(10),
            liveCount: 4_125,
            liveValidationState: "validated",
            liveCapturedAt: capturedAt,
            canonicalDays: [stepDay(state: .available,
                                    stepCount: 8_412,
                                    known: 8_412,
                                    covered: 86_400,
                                    missing: 0,
                                    end: capturedAt)],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 8_412)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertEqual(value.completeness, .complete)
        XCTAssertEqual(value.detailText, "Today so far · verified")
    }

    func testAgedExactOpenCycleReceiptKeepsCountAndNamesCaptureTime() {
        let now = day.addingTimeInterval(14 * 3_600)
        let capturedAt = now.addingTimeInterval(-2 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .available,
                                    stepCount: 4_321,
                                    known: 4_321,
                                    covered: 12 * 3_600,
                                    missing: 0,
                                    end: capturedAt)],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.valueText, "4321")
        XCTAssertEqual(value.completeness, .complete)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertEqual(value.capturedAt, capturedAt)
        XCTAssertFalse(value.openCycleReceiptIsCurrent)
        XCTAssertTrue(value.detailText.hasPrefix("Verified through "))
        XCTAssertFalse(value.detailText.contains("Today so far"))
        XCTAssertTrue(value.accessibilityText.contains("steps. Verified through "))
    }

    func testNewerValidatedLiveAdvancesExactOpenCycleSubtotalWithoutSumming() {
        let now = day.addingTimeInterval(14 * 3_600)
        let receiptEnd = now.addingTimeInterval(-2 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day, now: now, liveCount: 4_257,
            liveValidationState: "validated", liveCapturedAt: now,
            canonicalDays: [stepDay(state: .available, stepCount: 176,
                                    known: 176, covered: 12 * 3_600,
                                    missing: 0, end: receiptEnd)],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 4_257)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.capturedAt, now)
        XCTAssertEqual(value.detailText, "Today so far · live")
    }

    func testExactSubtotalRejectsLiveWithoutNewerQualifiedCurrentEvidence() {
        let now = day.addingTimeInterval(14 * 3_600)
        let receiptEnd = now.addingTimeInterval(-2 * 3_600)
        for (captured, state, qualified) in [
            (now.addingTimeInterval(-60), "validated", true),
            (receiptEnd, "validated", true),
            (now, "research_unvalidated", true),
            (now, "validated", false)
        ] {
            let value = AtriaDailyStepPresentation.resolve(
                day: day, now: now, liveCount: 4_257,
                liveValidationState: state, liveCapturedAt: captured,
                canonicalDays: [stepDay(state: .available, stepCount: 176,
                                        known: 176, covered: 12 * 3_600,
                                        missing: 0, end: receiptEnd)],
                liveAuthorityQualified: qualified,
                calendar: utcCalendar
            )
            XCTAssertEqual(value.count, 176)
            XCTAssertEqual(value.source, .verifiedCanonical)
        }
    }

    func testFreshValidatedLiveCannotEraseLargerDrainedPartial() {
        let now = day.addingTimeInterval(14 * 3_600)
        for liveCount in [0, 100] {
            let value = AtriaDailyStepPresentation.resolve(
                day: day, now: now, liveCount: liveCount,
                liveValidationState: "validated", liveCapturedAt: now,
                canonicalDays: [stepDay(state: .missing, stepCount: nil,
                                        known: 1_234, covered: 3_600,
                                        missing: 13 * 3_600, end: now)],
                calendar: utcCalendar
            )
            XCTAssertEqual(value.count, 1_234)
            XCTAssertEqual(value.source, .verifiedCanonical)
        }
    }

    func testPartialCanonicalCoverageUsesLowerBoundLabel() {
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 86_400),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .missing,
                                    stepCount: nil,
                                    known: 3_210,
                                    covered: 43_200,
                                    missing: 43_200)],
            calendar: utcCalendar
        )

        // 2026-08-22 user directive: no "≥" prefix — the partial nature stays in
        // the detail/accessibility lines, the hero number is just the number.
        XCTAssertEqual(value.valueText, "3210")
        XCTAssertEqual(value.completeness, .partial)
        // 2026-08-12: the glance line leads with the capture frontier, never a
        // coverage percent — "50% tracked" read as "the strap detects steps
        // wrong". The percent (motion-data coverage, not a transport-sync
        // grade and not an activity level) stays explained in accessibility.
        // The copy must still say neither "synced" (reads as "barely
        // uploaded") nor "moving" (reads as "only N% active").
        XCTAssertTrue(value.detailText.hasPrefix("Counted through "))
        XCTAssertFalse(value.detailText.contains("%"))
        XCTAssertFalse(value.detailText.contains("Today so far"))
        XCTAssertFalse(value.detailText.lowercased().contains("synced"))
        XCTAssertFalse(value.detailText.lowercased().contains("moving"))
        XCTAssertTrue(value.accessibilityText.contains("motion tracked for 50 percent of your day"))
        XCTAssertFalse(value.accessibilityText.lowercased().contains("synced"))
        XCTAssertTrue(value.accessibilityText.contains("through "))
    }

    private func partialVerified176() -> AtriaDailyStepPresentation {
        AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 86_400),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .missing,
                                    stepCount: nil,
                                    known: 176,
                                    covered: 11_598,
                                    missing: 43_626)],
            calendar: utcCalendar
        )
    }

    /// Baseline migrated 2026-08-19 (field report item 7). A verified-but-
    /// partial count is a lower bound, and the app now says so in the value
    /// line — matching the widget fed by the same snapshot, which never stopped
    /// rendering "≥N". The bare "176" this test used to pin is what made the
    /// user conclude steps were broken.
    func testTerminalPureHRMotionRetainsLowerBoundAndShowsBlocker() {
        var value = partialVerified176()
        // 2026-08-22 user directive: no "≥" prefix. Terminal pure-HR still
        // retains the verified count and shows the motion blocker footnote.
        XCTAssertEqual(value.valueText, "176")
        XCTAssertEqual(value.completeness, .partial)
        let coverageDetail = value.detailText

        value.motionAvailability = .unavailableInCurrentTransport
        // The verified count and coverage are untouched by the classification.
        XCTAssertEqual(value.valueText, "176")
        XCTAssertEqual(value.detailText, coverageDetail)
        // The forward-looking promise becomes the terminal blocker.
        XCTAssertEqual(value.motionAvailabilityFootnote,
                       "Strap motion is unavailable in the current connection mode. "
                        + "Live heart rate is still connected.")
    }

    func testCatchingUpQualifyingLiveStaleMotionKeepProgressCopy() {
        var value = partialVerified176()
        for state: AtriaStrapMotionAvailability in [.catchingUp, .qualifying, .live, .stale] {
            value.motionAvailability = state
            XCTAssertNil(value.motionAvailabilityFootnote,
                         "\(state) must keep the existing progress copy, not a blocker")
        }
        // Unclassified (nil) also keeps the existing copy.
        value.motionAvailability = nil
        XCTAssertNil(value.motionAvailabilityFootnote)
    }

    func testUnknownMotionUsesConservativeNonTerminalCopy() {
        var value = partialVerified176()
        value.motionAvailability = .unknown
        XCTAssertEqual(value.motionAvailabilityFootnote,
                       "Counted so far — updates when strap motion syncs.")
        // Never asserts the terminal "unavailable in the current connection mode".
        XCTAssertFalse(value.motionAvailabilityFootnote?
            .contains("unavailable in the current connection mode") ?? false)
    }

    func testConflictingExactCanonicalTotalsFailClosed() {
        let first = stepDay(state: .available, stepCount: 8_000,
                            known: 8_000, covered: 86_400, missing: 0)
        let second = stepDay(state: .available, stepCount: 9_000,
                             known: 9_000, covered: 86_400, missing: 0)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 86_400),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [first, second],
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.completeness, .unavailable)
    }

    func testFreshPreliminaryLiveShowsClampedEstimateWithoutDrainedFloor() {
        // 2026-08-22 (owner-approved, REC-1): reverses the prior fail-closed guard.
        // With NO drained coverage, a FRESH in-cycle qualified live count is now
        // surfaced AS AN ESTIMATE rather than withheld — the strap's oldest-first
        // drain can leave today with zero drained rows for hours while real steps
        // accrue. Honesty-first is preserved: source stays .live + !isValidated, so
        // the copy reads "estimate"/"Approximately", never an exact count.
        let capturedAt = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: capturedAt,
            liveCount: 4_000,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: capturedAt,
            canonicalDays: [],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 4_000)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.valueText, "4000")
        XCTAssertEqual(value.detailText, "Today so far · estimate")
        XCTAssertEqual(
            value.accessibilityText,
            "Approximately 4000 steps today so far."
        )
    }

    func testStandaloneLiveEstimateIsClampedToPhysiologicalCadence() {
        // The former fail-closed concern (an unvalidated count could be arbitrarily
        // wrong) is now bounded by a physiological cadence ceiling: a blown-up model
        // value cannot exceed what is humanly possible in the elapsed active window.
        // Here only 100s have elapsed → ceiling = 100 * 3.5 = 350 steps.
        let dayStart = day
        let now = dayStart.addingTimeInterval(100)
        let value = AtriaDailyStepPresentation.resolve(
            day: dayStart,
            now: now,
            liveCount: 999_999,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now,
            canonicalDays: [],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.source, .live)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.count, 350)
    }

    func testStandaloneLiveEstimateNeverFiresWithoutQualifiedModel() {
        // HR-only radio mode has liveCount==0 (no IMU frames) and an unqualified
        // model must still fail closed — the estimate branch never fires there.
        let capturedAt = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: capturedAt,
            liveCount: 4_000,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: capturedAt,
            canonicalDays: [],
            liveAuthorityQualified: false,
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.unavailabilityReason, .stepModelNotQualified)
    }

    func testDisprovenLiveModelFailsClosedEvenWhenStateSaysValidated() {
        let capturedAt = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: capturedAt,
            liveCount: 4_257,
            liveValidationState: "validated",
            liveCapturedAt: capturedAt,
            canonicalDays: [],
            liveAuthorityQualified: false,
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.valueText, "--")
        XCTAssertEqual(value.unavailabilityReason, .stepModelNotQualified)
        XCTAssertEqual(
            value.detailText,
            "Strap step model is still validating"
        )
    }

    func testPostMidnightLiveStrapTotalStaysVisibleUntilCompletedSleep() {
        let priorWakeDay = day
        let postMidnight = day.addingTimeInterval(86_400 + 2 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: postMidnight,
            now: postMidnight,
            liveCount: 4_000,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: postMidnight,
            canonicalDays: [],
            physiologicalDayStart: priorWakeDay.addingTimeInterval(7 * 3_600),
            calendar: utcCalendar
        )

        // 2026-08-22 (REC-1): the fresh post-midnight sample is attributed to the
        // open physiological cycle and, absent any drained coverage, is now shown as
        // a labeled estimate (previously withheld as "still validating").
        XCTAssertEqual(value.count, 4_000)
        XCTAssertEqual(value.source, .live)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.detailText, "Today so far · estimate")
    }

    func testUnresolvedCompactMotionDoesNotPublishLiveEstimate() {
        let capturedAt = day.addingTimeInterval(600)
        let unresolved = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2033-07-02",
            dayStart: day,
            dayEnd: capturedAt,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: 0,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 0,
            missingCoverageSeconds: 600
        )
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: capturedAt,
            liveCount: 4_257,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: capturedAt,
            canonicalDays: [unresolved],
            calendar: utcCalendar
        )
        XCTAssertNil(value.count)
        XCTAssertEqual(
            value.unavailabilityReason,
            .motionObservedCountUnresolved
        )
        XCTAssertEqual(
            value.detailText,
            "Strap motion found · count still resolving"
        )
        XCTAssertFalse(value.detailText.contains("Today so far · estimate"))
    }

    func testStaleStrapSubtotalIsHeldWhileMotionSyncs() {
        // Device 2026-09-14: IMU silence made the widget "-- / Waiting for strap"
        // even though an in-cycle count existed. Hold the last counted floor and
        // say it is syncing — never claim it is live.
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 4_000,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(
                -AtriaDailyStepPresentation.liveEvidenceMaximumAge - 0.001
            ),
            canonicalDays: [],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 4_000)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertTrue(value.detailText.hasPrefix("Last count · syncing"))
        XCTAssertEqual(value.valueText, "4000")
        XCTAssertFalse(value.detailText.contains("Today so far · live"))
    }

    func testStaleStrapSubtotalIsNotPresentedAsLiveTodayCount() {
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 612,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(
                -AtriaDailyStepPresentation.liveEvidenceMaximumAge - 0.001
            ),
            canonicalDays: [],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 612)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertTrue(value.detailText.hasPrefix("Last count · syncing"))
        XCTAssertFalse(value.detailText.contains("Today so far"))
    }

    func testClosedDayWithoutCanonicalStrapCoverageIsUnavailable() {
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 86_400),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.completeness, .unavailable)
        XCTAssertEqual(value.detailText, "No verified receipt for this cycle")
    }

    func testStaleLiveReceiptHasSpecificUnavailableReason() {
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 400,
            liveValidationState: "validated",
            liveCapturedAt: now.addingTimeInterval(-60),
            canonicalDays: [],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.valueText, "400")
        XCTAssertEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertTrue(value.detailText.hasPrefix("Last count · syncing"))
    }

    func testHighCoverageVerifiedFloorIsNotOverriddenByInflatedPreliminaryLive() {
        // Reliability guard (2026-08-22): over 94% verified coverage the drained
        // count (1234) is the trustworthy total, so an inflated preliminary live
        // count (9999 — physically impossible over that window) must NOT override
        // it. The live estimate only fills genuinely-undrained gaps (low coverage).
        let wake = day.addingTimeInterval(7 * 3_600)
        let now = wake.addingTimeInterval(5 * 3_600)
        let motionTicks = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2033-07-02",
            dayStart: wake,
            dayEnd: now,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: 1_234,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 17_000,
            missingCoverageSeconds: 1_000
        )

        let value = AtriaDailyStepPresentation.resolve(
            day: now,
            now: now,
            liveCount: 9_999,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now,
            canonicalDays: [motionTicks],
            physiologicalDayStart: wake,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 1_234)
        XCTAssertTrue(value.isValidated)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.valueText, "1234")
    }

    func testPhysicalAug11VerifiedCoverageStaysSeparateFromPreliminaryLedger()
        throws {
        let wake = day.addingTimeInterval(7 * 3_600)
        let capturedThrough = wake.addingTimeInterval(7 * 3_600)
        let verified = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2033-07-02",
            dayStart: wake,
            dayEnd: capturedThrough,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: 176,
            knownEpochCount: 176,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 11_598,
            missingCoverageSeconds: 43_626
        )

        let value = AtriaDailyStepPresentation.resolve(
            day: capturedThrough,
            now: capturedThrough,
            liveCount: 4_257,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: capturedThrough,
            canonicalDays: [verified],
            physiologicalDayStart: wake,
            calendar: utcCalendar
        )

        // Device 2026-09-11: a preliminary live estimate must not replace a
        // real drained floor. The 176-step receipt stays until validated live
        // or more coverage drains; swinging 176↔4257 was the field failure.
        XCTAssertEqual(value.count, 176)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertTrue(value.isValidated)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertFalse(value.detailText.contains("Today so far · estimate"))
    }

    func testFreshValidatedLiveOutranksPartialDurableReceiptWithoutSumming() {
        let wake = day.addingTimeInterval(7 * 3_600)
        let now = wake.addingTimeInterval(5 * 3_600)
        let receipt = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2033-07-02",
            dayStart: wake,
            dayEnd: now,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: 1_234,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 17_000,
            missingCoverageSeconds: 1_000
        )

        let value = AtriaDailyStepPresentation.resolve(
            day: now,
            now: now,
            liveCount: 1_301,
            liveValidationState: "validated",
            liveCapturedAt: now,
            canonicalDays: [receipt],
            physiologicalDayStart: wake,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 1_301)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertTrue(value.isValidated)
        XCTAssertEqual(value.valueText, "1301")
    }

    func testStaleValidatedInCycleLiveRaisesTotalAbovePartialReceipt() {
        // Option 1: a same-cycle validated cumulative count (4000) above the
        // drained floor (3210) is shown as the running total, plain number.
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 4_000,
            liveValidationState: "validated",
            liveCapturedAt: now.addingTimeInterval(
                -AtriaDailyStepPresentation.liveEvidenceMaximumAge - 0.001
            ),
            canonicalDays: [stepDay(state: .missing,
                                    stepCount: nil,
                                    known: 3_210,
                                    covered: 43_200,
                                    missing: 43_200)],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 4_000)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.valueText, "4000")
    }

    // 2026-07-31: after a no-sleep rollover the fresh cycle has no receipt
    // and no live sample. The prior cycle's verified subtotal is disclosed in
    // copy only; the count stays nil so rings, zones, and widget step values
    // never attribute prior-cycle steps to today.
    func testPriorCycleReceiptOnlyDisclosesWithoutCountingToday() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let endedAt = cycleStart.addingTimeInterval(-41 * 60)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 1_435, endedAt: endedAt),
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.valueText, "--")
        XCTAssertEqual(value.completeness, .unavailable)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertEqual(value.priorCycleReceipt,
                       .init(steps: 1_435, endedAt: endedAt))
        XCTAssertTrue(value.detailText.hasPrefix("Prior cycle: 1435 · ended "),
                      value.detailText)
        XCTAssertTrue(value.accessibilityText.contains("Prior cycle: 1435"),
                      value.accessibilityText)
    }

    func testStaleLiveFromBeforeWakeBoundaryDisclosesPriorCycle() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let endedAt = cycleStart.addingTimeInterval(-41 * 60)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 1_435,
            liveValidationState: "validated",
            // Captured before the rolled wake boundary: this sample belongs
            // to the prior cycle, not a stale edge of the current one.
            liveCapturedAt: cycleStart.addingTimeInterval(-3_600),
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 1_435, endedAt: endedAt),
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertTrue(value.detailText.hasPrefix("Prior cycle: 1435 · ended "))
    }

    func testStaleLiveWithinCurrentCycleKeepsStaleReason() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 12,
            liveValidationState: "validated",
            liveCapturedAt: cycleStart.addingTimeInterval(60),
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(
                steps: 1_435,
                endedAt: cycleStart.addingTimeInterval(-41 * 60)
            ),
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 12)
        XCTAssertEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertNil(value.priorCycleReceipt)
        XCTAssertTrue(value.detailText.hasPrefix("Last count · syncing"))
    }

    func testHeldFloorSurvivesZeroLiveMergeInsideCurrentCycle() {
        let now = day.addingTimeInterval(14 * 3_600)
        let heldAt = now.addingTimeInterval(-120)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 0,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: nil,
            canonicalDays: [],
            heldCount: 11_854,
            heldCapturedAt: heldAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 11_854)
        XCTAssertEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertEqual(value.capturedAt, heldAt)
        XCTAssertTrue(value.detailText.hasPrefix("Last count · syncing"))
    }

    func testFreshCumulativeLiveIMUTicksRaiseTheHeldFloor() {
        let now = day.addingTimeInterval(14 * 3_600)
        let heldAt = now.addingTimeInterval(-120)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 7_857,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(-1),
            canonicalDays: [],
            heldCount: 7_845,
            heldCapturedAt: heldAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 7_857)
        XCTAssertNotEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertEqual(value.capturedAt, now.addingTimeInterval(-1))
    }

    func testLiveGyroWinsOverAContaminatedHeldFloorAfterRestart() {
        let now = day.addingTimeInterval(14 * 3_600)
        let heldAt = now.addingTimeInterval(-120)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 10,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(-1),
            canonicalDays: [],
            heldCount: 7_845,
            heldCapturedAt: heldAt,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 10)
        XCTAssertEqual(value.source, .live)
        XCTAssertNotEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
        XCTAssertEqual(value.capturedAt, now.addingTimeInterval(-1))
    }

    func testHeldFloorDoesNotCrossANewCycle() {
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            heldCount: 11_854,
            heldCapturedAt: day.addingTimeInterval(-3_600),
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertNotEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
    }

    func testHeldDailyStepFloorLoadRejectsADifferentCycle() {
        let suiteName = "AtriaHeldDailyStepFloorTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let cycle = day
        AtriaHeldDailyStepFloor.persist(
            count: 400,
            cycleStart: cycle,
            capturedAt: cycle.addingTimeInterval(8 * 3_600),
            defaults: suite
        )
        XCTAssertEqual(AtriaHeldDailyStepFloor.load(cycleStart: cycle, defaults: suite)?.count, 400)
        XCTAssertNil(AtriaHeldDailyStepFloor.load(
            cycleStart: cycle.addingTimeInterval(86_400),
            defaults: suite
        ))
    }

    func testHeldFloorPersistLiveCoordinateRequiresMatchingCycleKey() {
        let suiteName = "AtriaHeldDailyStepFloorLiveCoordinate.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let cycle = day
        let captured = cycle.addingTimeInterval(8 * 3_600)
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 7_845,
            capturedAt: captured,
            defaults: suite
        )
        XCTAssertNil(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle,
                now: captured.addingTimeInterval(120),
                defaults: suite
            )?.count,
            "an unkeyed live coordinate must not attach to a new wake"
        )
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 7_845,
            capturedAt: captured,
            cycleStart: cycle,
            defaults: suite
        )
        XCTAssertEqual(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle,
                now: captured.addingTimeInterval(120),
                defaults: suite
            )?.count,
            7_845
        )
        XCTAssertNil(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle.addingTimeInterval(86_400),
                now: captured.addingTimeInterval(86_400 + 120),
                defaults: suite
            )?.count,
            "confirming last night's sleep must not keep yesterday's floor"
        )
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 10,
            capturedAt: captured.addingTimeInterval(60),
            cycleStart: cycle,
            defaults: suite
        )
        XCTAssertEqual(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle,
                now: captured.addingTimeInterval(120),
                defaults: suite
            )?.count,
            10,
            "cycle-scoped gyro must replace a leftover thousands-high floor"
        )
    }

    func testGyroOnlySessionStepsDropsAccelerometerPeakContamination() {
        XCTAssertEqual(AtriaBLEManager.gyroOnlySessionSteps(current: 0, incomingGyro: 4), 4)
        XCTAssertEqual(AtriaBLEManager.gyroOnlySessionSteps(current: 4, incomingGyro: 12), 12)
        XCTAssertEqual(AtriaBLEManager.gyroOnlySessionSteps(current: 6_420, incomingGyro: 0), 0)
        XCTAssertEqual(AtriaBLEManager.gyroOnlySessionSteps(current: 6_420, incomingGyro: 12), 12)
        XCTAssertEqual(AtriaBLEManager.gyroOnlySessionSteps(current: 48, incomingGyro: 50), 50)
        XCTAssertEqual(AtriaBLEManager.gyroOnlySessionSteps(current: 50, incomingGyro: 48), 50)
    }

    func testHeldFloorRejectsImplausibleAccelerometerJumpAndReplacesIt() {
        let suiteName = "AtriaHeldDailyStepFloorContamination.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let cycle = day
        let captured = cycle.addingTimeInterval(8 * 3_600)
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 7_849,
            capturedAt: captured,
            cycleStart: cycle,
            trustedPrefix: 7_849,
            defaults: suite
        )
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 14_269,
            capturedAt: captured.addingTimeInterval(40),
            cycleStart: cycle,
            trustedPrefix: 7_849,
            defaults: suite
        )
        XCTAssertEqual(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle,
                now: captured.addingTimeInterval(120),
                defaults: suite
            )?.count,
            7_849,
            "6k sitting accel peaks in 40s must not raise Today"
        )
    }

    func testHeldFloorReplacesAlreadyPersistedAccelerometerContamination() {
        let suiteName = "AtriaHeldDailyStepFloorReplaceContamination.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let cycle = day
        let captured = cycle.addingTimeInterval(8 * 3_600)
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 14_269,
            capturedAt: captured,
            cycleStart: cycle,
            defaults: suite
        )
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 7_849,
            capturedAt: captured.addingTimeInterval(2),
            cycleStart: cycle,
            trustedPrefix: 7_849,
            defaults: suite
        )
        XCTAssertEqual(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle,
                now: captured.addingTimeInterval(120),
                defaults: suite
            )?.count,
            7_849
        )
    }

    func testPresentationDropsHugeHeldFloorWhenLiveGyroIsTiny() {
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 18,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(-1),
            canonicalDays: [],
            heldCount: 9_482,
            heldCapturedAt: now.addingTimeInterval(-40),
            calendar: utcCalendar
        )
        XCTAssertEqual(value.count, 18)
        XCTAssertEqual(value.source, .live)
    }

    func testHeldFloorReplacesCycleScopedGyroContaminationWithoutTrustedPrefix() {
        let suiteName = "AtriaHeldDailyStepFloorTinyGyro.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let cycle = day
        let captured = cycle.addingTimeInterval(8 * 3_600)
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 9_482,
            capturedAt: captured,
            cycleStart: cycle,
            defaults: suite
        )
        AtriaHeldDailyStepFloor.persistLiveCoordinate(
            count: 18,
            capturedAt: captured.addingTimeInterval(2),
            cycleStart: cycle,
            defaults: suite
        )
        XCTAssertEqual(
            AtriaHeldDailyStepFloor.load(
                cycleStart: cycle,
                now: captured.addingTimeInterval(120),
                defaults: suite
            )?.count,
            18
        )
    }

    func testNewCycleClearsTheHeldFloor() {
        let suiteName = "AtriaHeldDailyStepFloorNewCycle.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let cycle = day
        AtriaHeldDailyStepFloor.persist(
            count: 9_482,
            cycleStart: cycle,
            capturedAt: cycle.addingTimeInterval(3_600),
            defaults: suite
        )
        let next = cycle.addingTimeInterval(24 * 3_600)
        AtriaHeldDailyStepFloor.resetForNewCycle(cycleStart: next, defaults: suite)
        XCTAssertNil(AtriaHeldDailyStepFloor.load(cycleStart: cycle, defaults: suite))
        XCTAssertNil(AtriaHeldDailyStepFloor.load(cycleStart: next, defaults: suite))
    }

    func testPresentationDropsImplausibleHeldFloorWhenLiveGyroIsNearby() {
        let now = day.addingTimeInterval(14 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: 7_849,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(-1),
            canonicalDays: [],
            heldCount: 14_269,
            heldCapturedAt: now.addingTimeInterval(-40),
            calendar: utcCalendar
        )
        XCTAssertEqual(value.count, 7_849)
        XCTAssertNotEqual(value.unavailabilityReason, .heldWhileMotionSyncing)
    }

    // 2026-08-01: a prior cycle that ended overnight (before 6 AM today) or
    // on the previous civil day is "yesterday's total" to a human. Say
    // "Yesterday: ≥N" instead of the technical "Prior cycle: ≥N · ended
    // 1:44 AM". The count stays nil — prior steps are never today's value.
    func testPriorCycleEndedOvernightBeforeSixAMReadsAsYesterday() {
        // detailText classifies civil days with Calendar.current, so build
        // the fixture in the same calendar to stay timezone-independent.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let endedAt = today.addingTimeInterval(1 * 3_600 + 44 * 60) // 1:44 AM today
        let value = AtriaDailyStepPresentation.resolve(
            day: today,
            now: today.addingTimeInterval(8 * 3_600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: today.addingTimeInterval(7 * 3_600),
            priorCycleReceipt: .init(steps: 5_251, endedAt: endedAt),
            calendar: calendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertEqual(value.detailText, "Yesterday: 5251")
    }

    func testPriorCycleEndedPreviousEveningReadsAsYesterday() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let endedAt = today.addingTimeInterval(-2 * 3_600) // yesterday 10 PM
        let value = AtriaDailyStepPresentation.resolve(
            day: today,
            now: today.addingTimeInterval(9 * 3_600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: today.addingTimeInterval(7 * 3_600),
            priorCycleReceipt: .init(steps: 5_251, endedAt: endedAt),
            calendar: calendar
        )

        XCTAssertEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertEqual(value.detailText, "Yesterday: 5251")
    }

    func testPriorCycleEndedTodayAfternoonKeepsPreciseForm() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let endedAt = today.addingTimeInterval(14 * 3_600) // 2 PM today: not "yesterday"
        let value = AtriaDailyStepPresentation.resolve(
            day: today,
            now: today.addingTimeInterval(16 * 3_600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: today.addingTimeInterval(15 * 3_600),
            priorCycleReceipt: .init(steps: 5_251, endedAt: endedAt),
            calendar: calendar
        )

        XCTAssertEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertTrue(value.detailText.hasPrefix("Prior cycle: 5251 · ended "),
                      value.detailText)
    }

    func testPriorCycleYesterdayBoundaryIsExactlySixAM() {
        let today = utcCalendar.startOfDay(for: day)
        let presentation = AtriaDailyStepPresentation(
            day: today,
            count: nil,
            completeness: .unavailable,
            source: .none,
            isValidated: false,
            capturedAt: nil,
            coverageFraction: nil
        )
        XCTAssertTrue(presentation.priorCycleReadsAsYesterday(
            .init(steps: 10, endedAt: today.addingTimeInterval(6 * 3_600 - 1)),
            calendar: utcCalendar
        ))
        XCTAssertFalse(presentation.priorCycleReadsAsYesterday(
            .init(steps: 10, endedAt: today.addingTimeInterval(6 * 3_600)),
            calendar: utcCalendar
        ))
        // Two civil days ago is not "yesterday" — keep the precise form.
        XCTAssertFalse(presentation.priorCycleReadsAsYesterday(
            .init(steps: 10, endedAt: today.addingTimeInterval(-30 * 3_600)),
            calendar: utcCalendar
        ))
    }

    func testNoPriorReceiptKeepsExistingEmptyReason() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.unavailabilityReason, .noCurrentCycleReceipt)
        XCTAssertEqual(value.detailText, "No verified receipt for this cycle")
    }

    // 2026-08-22: a shifted sleeper whose real sleep was NOT detected gets a
    // synthetic no-sleep-fallback wake boundary that cuts ONE continuous active
    // period in two. The steps already counted this wake must not be stranded
    // in "Yesterday" while today shows "--". Across an UNCONFIRMED fallback the
    // prior receipt is carried forward as the open cycle's verified-partial
    // floor; across a CONFIRMED sleep boundary the strict split still holds.
    func testUnconfirmedFallbackCarriesPriorReceiptForwardInsteadOfDoubleDash() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let endedAt = cycleStart.addingTimeInterval(-41 * 60)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 1_118, endedAt: endedAt),
            boundaryIsUnconfirmedFallback: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 1_118)
        XCTAssertEqual(value.valueText, "1118")
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertTrue(value.carriedFromUnconfirmedPriorCycle)
        XCTAssertEqual(value.capturedAt, endedAt)
        XCTAssertNotEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertTrue(value.detailText.hasPrefix("Counted through "),
                      value.detailText)
        // Never leaks the technical "prior cycle" / "yesterday" framing.
        XCTAssertFalse(value.detailText.contains("Yesterday"))
        XCTAssertFalse(value.detailText.contains("Prior cycle"))
        XCTAssertTrue(value.accessibilityText.contains("1118 steps so far"),
                      value.accessibilityText)
    }

    // Regression guard: a CONFIRMED main-sleep boundary is a real new day. The
    // default (false) must keep the strict "prior steps are never today's"
    // behavior so a real morning does not inherit yesterday's step total.
    func testConfirmedSleepBoundaryKeepsStrictPriorCycleSplit() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let endedAt = cycleStart.addingTimeInterval(-41 * 60)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 1_118, endedAt: endedAt),
            boundaryIsUnconfirmedFallback: false,
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.valueText, "--")
        XCTAssertFalse(value.carriedFromUnconfirmedPriorCycle)
        XCTAssertEqual(value.unavailabilityReason, .priorCycleReceiptOnly)
        XCTAssertEqual(value.priorCycleReceipt,
                       .init(steps: 1_118, endedAt: endedAt))
    }

    // 2026-09-07 device bug: the strap's motion transport sat in pure-HR
    // fallback for days, so the newest drained receipt (135 steps) was frozen
    // three days before this cycle's wake boundary — yet it was promoted to
    // today's hero count and the widget value. A prior receipt stranded more
    // than one physiological cycle back is NOT the same continuous wear period
    // (a whole cycle drained nothing in between), so it must neither be carried
    // forward as today nor disclosed as an abutting "prior cycle".
    func testMultiDayStalePriorReceiptIsNeverCarriedOrDisclosedAsToday() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let staleEndedAt = cycleStart.addingTimeInterval(-72 * 3_600) // 3 days back
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 135, endedAt: staleEndedAt),
            boundaryIsUnconfirmedFallback: true,
            calendar: utcCalendar
        )

        XCTAssertNil(value.count)
        XCTAssertEqual(value.valueText, "--")
        XCTAssertFalse(value.carriedFromUnconfirmedPriorCycle)
        // Not even disclosed as "prior cycle": a dateless "ended 9:44 AM" would
        // read as recent. Fall through to the plain honest empty state instead.
        XCTAssertEqual(value.unavailabilityReason, .noCurrentCycleReceipt)
        XCTAssertNil(value.priorCycleReceipt)
        XCTAssertEqual(value.detailText, "No verified receipt for this cycle")
        XCTAssertFalse(value.detailText.contains("135"))
    }

    /// Device 2026-09-08: accepting the Friday 9:44 IST fill freeze must not
    /// withhold a later open-cycle live total for the current wake window.
    func testOpenCycleLiveAfterFridayFillFreezeIsNotWithheld() {
        let friday944 = Date(timeIntervalSince1970: 1_788_495_274)
        let wake = Date(timeIntervalSince1970: 1_788_847_800) // 2026-09-08 00:15Z
        let now = wake.addingTimeInterval(8 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: wake,
            now: now,
            liveCount: 842,
            liveValidationState: "validated",
            liveCapturedAt: now,
            canonicalDays: [],
            physiologicalDayStart: wake,
            priorCycleReceipt: .init(steps: 135, endedAt: friday944),
            calendar: utcCalendar
        )
        XCTAssertEqual(value.count, 842)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertNil(value.priorCycleReceipt)
        XCTAssertFalse(value.detailText.contains("135"))
    }

    // The stale receipt must not sneak in as the partial-branch FLOOR either:
    // a small fresh drained slice is the honest lower bound for the open cycle,
    // never a 3-day-old total.
    func testMultiDayStalePriorReceiptDoesNotFloorAFreshPartial() {
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 3_600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .missing,
                                    stepCount: nil,
                                    known: 120,
                                    covered: 1_800,
                                    missing: 40_000,
                                    end: day.addingTimeInterval(1_800))],
            physiologicalDayStart: day,
            priorCycleReceipt: .init(steps: 135,
                                     endedAt: day.addingTimeInterval(-72 * 3_600)),
            boundaryIsUnconfirmedFallback: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 120)
        XCTAssertFalse(value.carriedFromUnconfirmedPriorCycle)
    }

    // The abutment boundary is one physiological cycle (28 h). A receipt just
    // inside it is the immediately-preceding cycle and still carries; just
    // outside it is stale history and does not.
    func testPriorReceiptCarriedOnlyWithinOnePhysiologicalCycle() {
        let cycleStart = day.addingTimeInterval(30 * 3_600)
        func resolveWithGap(_ gap: TimeInterval) -> AtriaDailyStepPresentation {
            AtriaDailyStepPresentation.resolve(
                day: day,
                now: cycleStart.addingTimeInterval(600),
                liveCount: 0,
                liveValidationState: "unavailable",
                liveCapturedAt: nil,
                canonicalDays: [],
                physiologicalDayStart: cycleStart,
                priorCycleReceipt: .init(steps: 900,
                                         endedAt: cycleStart.addingTimeInterval(-gap)),
                boundaryIsUnconfirmedFallback: true,
                calendar: utcCalendar
            )
        }

        let justInside = resolveWithGap(27 * 3_600)
        XCTAssertEqual(justInside.count, 900)
        XCTAssertTrue(justInside.carriedFromUnconfirmedPriorCycle)

        let justOutside = resolveWithGap(29 * 3_600)
        XCTAssertNil(justOutside.count)
        XCTAssertFalse(justOutside.carriedFromUnconfirmedPriorCycle)
        XCTAssertEqual(justOutside.unavailabilityReason, .noCurrentCycleReceipt)
    }

    // The exact 2026-09-07 device shape: a CONFIRMED main-sleep boundary opens
    // this cycle (wake 09-07 00:20Z) while the newest drained receipt is frozen
    // ~68 h back (09-04, R10 in pure-HR fallback). It must be neither carried
    // (mainSleep boundary already forbids that) NOR disclosed as an abutting
    // "prior cycle" — the hero is "--" and there is no dateless "Prior cycle:
    // 135" line to misread as recent.
    func testStaleReceiptUnderConfirmedSleepBoundaryIsNotDisclosed() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let staleEndedAt = cycleStart.addingTimeInterval(-68 * 3_600)
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 135, endedAt: staleEndedAt),
            boundaryIsUnconfirmedFallback: false, // .mainSleep boundary
            calendar: utcCalendar
        )
        XCTAssertNil(value.count)
        XCTAssertFalse(value.carriedFromUnconfirmedPriorCycle)
        XCTAssertNil(value.priorCycleReceipt)
        XCTAssertEqual(value.unavailabilityReason, .noCurrentCycleReceipt)
    }

    // Once this freshly-rolled cycle drains its own small early slice, the shown
    // number must not REGRESS below what the same active period already counted.
    // The carried prior receipt is a non-regressing floor (max, never a sum).
    func testUnconfirmedFallbackFloorPreventsFreshPartialRegression() {
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(2 * 3_600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .missing,
                                    stepCount: nil,
                                    known: 120,
                                    covered: 1_800,
                                    missing: 40_000,
                                    end: day.addingTimeInterval(1_800))],
            physiologicalDayStart: day,
            priorCycleReceipt: .init(
                steps: 1_118,
                endedAt: day.addingTimeInterval(-30 * 60)
            ),
            boundaryIsUnconfirmedFallback: true,
            calendar: utcCalendar
        )

        // max(banked 120, carried 1118) = 1118, never the smaller fresh slice.
        XCTAssertEqual(value.count, 1_118)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertTrue(value.carriedFromUnconfirmedPriorCycle)
        // The carried total must NOT be paired with the fresh cycle's tiny
        // coverage: VoiceOver must never say "motion tracked for N percent"
        // beside a near-complete carried count (it would imply the real total
        // is ~25x higher). Mirror the no-partial carry: nil coverage.
        XCTAssertNil(value.coverageFraction)
        XCTAssertFalse(value.accessibilityText.contains("percent of your day"),
                       value.accessibilityText)
        XCTAssertTrue(value.accessibilityText.contains("1118 steps so far"),
                      value.accessibilityText)
        // Frontier is the carried receipt's own end, never the fresh slice's
        // later dayEnd (which would overstate how far 1118 was counted).
        XCTAssertEqual(value.capturedAt, day.addingTimeInterval(-30 * 60))
    }

    // When the freshly-rolled cycle's OWN drained slice exceeds the carried
    // floor it takes over cleanly — the carry is only ever a floor, never a cap.
    func testUnconfirmedFallbackFloorYieldsToLargerFreshPartial() {
        let value = AtriaDailyStepPresentation.resolve(
            day: day,
            now: day.addingTimeInterval(6 * 3_600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [stepDay(state: .missing,
                                    stepCount: nil,
                                    known: 2_500,
                                    covered: 18_000,
                                    missing: 20_000,
                                    end: day.addingTimeInterval(18_000))],
            physiologicalDayStart: day,
            priorCycleReceipt: .init(
                steps: 1_118,
                endedAt: day.addingTimeInterval(-30 * 60)
            ),
            boundaryIsUnconfirmedFallback: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 2_500)
        XCTAssertFalse(value.carriedFromUnconfirmedPriorCycle)
    }

    // The widget wrapper must forward the boundary flag so app and widget agree.
    func testWidgetResolverForwardsUnconfirmedFallbackCarry() {
        let cycleStart = day.addingTimeInterval(15 * 3_600)
        let endedAt = cycleStart.addingTimeInterval(-41 * 60)
        let value = WidgetSnapshotPublisher.resolvedDailySteps(
            day: day,
            now: cycleStart.addingTimeInterval(600),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [],
            physiologicalDayStart: cycleStart,
            priorCycleReceipt: .init(steps: 1_118, endedAt: endedAt),
            boundaryIsUnconfirmedFallback: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 1_118)
        XCTAssertTrue(value.carriedFromUnconfirmedPriorCycle)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func stepDay(
        state: AtriaHistoricalDailyConsumerProjection.EvidenceState,
        stepCount: Int?,
        known: Int,
        covered: Int,
        missing: Int,
        end: Date? = nil
    ) -> AtriaHistoricalDailyConsumerProjection.StepDay {
        .init(localDay: "2033-07-02",
              dayStart: day,
              dayEnd: end ?? day.addingTimeInterval(86_400),
              state: state,
              stepCount: stepCount,
              knownStepDeltaSum: known,
              knownEpochCount: covered > 0 ? 1 : 0,
              rejectedOrUnknownEpochCount: 0,
              knownCoverageSeconds: covered,
              missingCoverageSeconds: missing)
    }
}

final class AtriaStrapMotionAvailabilityTests: XCTestCase {
    private func input(
        owner: AtriaBLEManager.ProtectedR10CleanOwner,
        state: AtriaBLEManager.ProtectedR10CleanOwnerState,
        suppressed: Bool = false,
        freshAge: TimeInterval? = nil,
        ticket: Bool = false,
        prior: Bool = false
    ) -> AtriaStrapMotionAvailability.Input {
        .init(cleanOwner: owner,
              cleanOwnerState: state,
              streamSuppressed: suppressed,
              freshMotionAge: freshAge,
              hasActiveMotionBankOffload: ticket,
              hasPriorVerifiedMotion: prior)
    }

    func testProtectedV9QualifiedWithMinimalHRIsNotUnavailable() {
        let result = AtriaStrapMotionAvailability.resolve(
            input(owner: .protectedV9, state: .qualified, prior: true))
        XCTAssertNotEqual(result, .unavailableInCurrentTransport)
        XCTAssertEqual(result, .stale)
    }

    func testProtectedProvingAndLaunchPendingAreQualifying() {
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .protectedV9, state: .proving)), .qualifying)
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .protectedV9, state: .protectedLaunchPending)), .qualifying)
    }

    func testPureHRFallbackSuppressedNoMotionIsUnavailable() {
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV10, state: .fallbackActive, suppressed: true, prior: true)),
            .unavailableInCurrentTransport)
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV8, state: .fallbackPending, suppressed: true)),
            .unavailableInCurrentTransport)
    }

    func testPureHRFallbackWithActiveOffloadIsCatchingUpNotUnavailable() {
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV10, state: .fallbackActive,
                  suppressed: true, ticket: true, prior: true)),
            .catchingUp)
    }

    func testFreshMotionIsLiveRegardlessOfFallbackMarker() {
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV10, state: .fallbackActive,
                  suppressed: true, freshAge: 5, prior: true)),
            .live)
    }

    func testStaleAmbiguousOwnerIsNotTerminal() {
        // Pure-HR owner + terminal state but NOT stream-suppressed: not the exact
        // terminal conjunction, so it stays stale, never unavailable.
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV10, state: .fallbackActive, suppressed: false, prior: true)),
            .stale)
    }

    func testTransitionFromUnavailableToLiveWhenMotionReturns() {
        let before = AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV10, state: .fallbackActive, suppressed: true, prior: true))
        XCTAssertEqual(before, .unavailableInCurrentTransport)
        let after = AtriaStrapMotionAvailability.resolve(
            input(owner: .pureHRV10, state: .fallbackActive,
                  suppressed: true, freshAge: 3, prior: true))
        XCTAssertEqual(after, .live)
    }

    func testRelaunchWithoutFreshMotionFailsClosed() {
        XCTAssertEqual(AtriaStrapMotionAvailability.resolve(
            input(owner: .legacy, state: .none)), .unknown)
    }
}
