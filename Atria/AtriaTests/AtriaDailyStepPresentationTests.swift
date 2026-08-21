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

    func testPreliminaryLiveStrapTotalFailsClosedUntilValidated() {
        // With NO drained coverage there is no verified floor to sanity-check an
        // unvalidated live count against, so it still fails closed (the 2026-08-22
        // live estimate only fills gaps against a real drained partial).
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

        XCTAssertNil(value.count)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.completeness, .unavailable)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.valueText, "--")
        XCTAssertEqual(value.detailText, "Strap motion is still validating")
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

        XCTAssertNil(value.count)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.completeness, .unavailable)
        XCTAssertEqual(value.detailText, "Strap motion is still validating")
    }

    func testStaleStrapSubtotalIsUnavailableWithoutCanonicalCoverage() {
        // No drained coverage → no verified floor → an unvalidated stale count
        // still fails closed rather than masquerading as today's total.
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

        XCTAssertNil(value.count)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(
            value.detailText,
            "Last strap movement is no longer live"
        )
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

        XCTAssertNil(value.count)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.completeness, .unavailable)
        XCTAssertEqual(
            value.detailText,
            "Last strap movement is no longer live"
        )
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

        XCTAssertEqual(value.valueText, "--")
        XCTAssertEqual(
            value.detailText,
            "Last strap movement is no longer live"
        )
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

        // Option 1 (2026-08-22): over only 21% drained coverage the in-cycle
        // live estimate (4257) is the more up-to-date total and is now shown as
        // an estimate, rather than pinning the 176-step drained floor. This is
        // the "stuck at 176 all morning" case the user asked to fix.
        XCTAssertEqual(value.count, 4_257)
        XCTAssertEqual(value.source, .live)
        XCTAssertFalse(value.isValidated)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.detailText, "Today so far · estimate")
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

        XCTAssertNil(value.count)
        XCTAssertEqual(value.unavailabilityReason, .staleLiveReceipt)
        XCTAssertNil(value.priorCycleReceipt)
        XCTAssertEqual(value.detailText,
                       "Last strap movement is no longer live")
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
