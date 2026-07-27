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

    func testNewerLiveTodayTotalWinsWithoutBeingCalledComplete() {
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
                                    missing: 0)],
            calendar: utcCalendar
        )

        XCTAssertEqual(value.count, 4_125)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.detailText, "Today so far · live")
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

        XCTAssertEqual(value.valueText, "≥3210")
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.detailText, "Partial archive · 50% covered")
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

    func testPreliminaryLiveStrapTotalIsPresentedAsEstimate() {
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
        XCTAssertEqual(value.valueText, "~4000")
        XCTAssertEqual(value.detailText, "Today so far · estimate")
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

        XCTAssertEqual(value.count, 4_000)
        XCTAssertEqual(value.source, .live)
        XCTAssertEqual(value.completeness, .partial)
        XCTAssertEqual(value.valueText, "~4000")
    }

    func testStaleStrapSubtotalIsUnavailableWithoutCanonicalCoverage() {
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
        XCTAssertEqual(value.detailText, "No verified step coverage")
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
        XCTAssertEqual(value.detailText, "No verified step coverage")
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
    }

    func testPhysiologicalMotionTickSubtotalOutranksFreshPreliminaryR10() {
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
        XCTAssertEqual(value.valueText, "≥1234")
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
        missing: Int
    ) -> AtriaHistoricalDailyConsumerProjection.StepDay {
        .init(localDay: "2033-07-02",
              dayStart: day,
              dayEnd: day.addingTimeInterval(86_400),
              state: state,
              stepCount: stepCount,
              knownStepDeltaSum: known,
              knownEpochCount: covered > 0 ? 1 : 0,
              rejectedOrUnknownEpochCount: 0,
              knownCoverageSeconds: covered,
              missingCoverageSeconds: missing)
    }
}
