import XCTest
@testable import Atria

/// Handoff-10 CP1: the exact Aug-12/Aug-13 incident fixture. A Today-labelled
/// surface may never silently wear the prior cycle's 92 / 9h12 / 3.3; today's
/// own partial (54 / RHR-only) or a terminal awaiting state is the only
/// permitted primary, and the prior cycle survives as a dated disclosure.
final class AtriaCurrentDayPresentationTests: XCTestCase {
    private let calendar = Calendar.current
    // Aug 12 15:27 IST wake anchoring the incident cycle.
    private var wake: Date { day(0).addingTimeInterval(15 * 3_600 + 27 * 60) }
    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_386_600)
            .addingTimeInterval(Double(offset) * 86_400))
    }
    // 14:43 the next civil day — pre-rollover (wake + 24h + 30m has not fired).
    private var incidentNow: Date { day(1).addingTimeInterval(14 * 3_600 + 43 * 60) }

    private var partial54: Metrics.RecoveryEstimate {
        .init(percent: 54,
              confidence: .unverified,
              usesHRV: false,
              detail: "Limited confidence · sleep and HRV unavailable · from resting HR only — confirm a sleep to add HRV",
              contributors: [])
    }

    private var priorCycle: AtriaPriorCycleDisclosure {
        .init(civilDay: day(0), recoveryPercent: 92,
              sleepSeconds: 9 * 3_600 + 12 * 60, strain: 3.296)
    }

    private func resolve(
        now: Date? = nil,
        partial: Metrics.RecoveryEstimate?,
        partialStrain: Double?
    ) -> AtriaCurrentDayPresentation.Resolution {
        AtriaCurrentDayPresentation.resolve(
            now: now ?? incidentNow,
            cycleStart: wake,
            cycleEnd: wake.addingTimeInterval(24 * 3_600 + 30 * 60),
            anchorSleepID: "sleep-aug12",
            cycleValueSourceDay: wake,
            currentDayPartialRecovery: partial,
            currentDayPartialStrain: partialStrain,
            priorCycle: priorCycle,
            calendar: calendar
        )
    }

    // MARK: - The incident fixture

    func testTodayNeverWearsThePriorCycleAsPrimary() throws {
        let resolution = resolve(partial: partial54, partialStrain: 1.026)
        XCTAssertEqual(resolution.identity.valueState, .currentPartial)
        let recovery = try XCTUnwrap(resolution.recoveryOverride)
        XCTAssertEqual(recovery.percent, 54, "Never 92 as today's recovery")
        XCTAssertEqual(recovery.confidence, .unverified)
        XCTAssertFalse(recovery.usesHRV)
        XCTAssertTrue(recovery.detail.contains("resting HR only"),
                      "The real RHR-only limited detail must be preserved")
        XCTAssertEqual(try XCTUnwrap(resolution.strainOverride), 1.026,
                       accuracy: 0.001, "Never yesterday's ~3.3 as today's strain")
        XCTAssertTrue(resolution.sleepIsAwaitingCurrentSleep,
                      "Today's sleep ring must await current evidence")
        let disclosure = try XCTUnwrap(resolution.priorCycle)
        XCTAssertEqual(disclosure.recoveryPercent, 92)
        XCTAssertEqual(disclosure.civilDay, day(0),
                       "The prior cycle survives only with its own date")
        XCTAssertEqual(resolution.identity.sourceCivilDay, day(1))
        XCTAssertNil(resolution.identity.sourceSleepID,
                     "A partial current day is not sourced from the prior sleep")
    }

    func testNoCurrentDayRowYieldsTerminalAwaitingStates() throws {
        let resolution = resolve(partial: nil, partialStrain: nil)
        XCTAssertEqual(resolution.identity.valueState, .awaitingCurrentSleep)
        let recovery = try XCTUnwrap(resolution.recoveryOverride)
        XCTAssertNil(recovery.percent, "No borrowed value — a terminal awaiting state")
        XCTAssertEqual(recovery.detail,
                       AtriaCurrentDayPresentation.awaitingCurrentSleepDetail)
        XCTAssertEqual(resolution.strainOverride, 0)
        XCTAssertTrue(resolution.sleepIsAwaitingCurrentSleep)
        XCTAssertNil(resolution.identity.sourceCivilDay)
    }

    func testWakeDayItselfKeepsTheCycleValuesAsCurrent() {
        // At 20:00 on the wake's own civil day the 92 IS today's value.
        let sameDayNow = day(0).addingTimeInterval(20 * 3_600)
        let resolution = resolve(now: sameDayNow, partial: nil, partialStrain: nil)
        XCTAssertEqual(resolution.identity.valueState, .current)
        XCTAssertNil(resolution.recoveryOverride,
                     "The cycle projection stays the primary on its own day")
        XCTAssertNil(resolution.strainOverride)
        XCTAssertFalse(resolution.sleepIsAwaitingCurrentSleep)
        XCTAssertNil(resolution.priorCycle)
        XCTAssertEqual(resolution.identity.sourceSleepID, "sleep-aug12")
    }

    // MARK: - Partial admission honesty

    func testPartialAdmissionRejectsHRVBackedOrVerifiedRows() {
        let hrvBacked = FrozenRecoverySummary(
            score: 80, confidence: "personal baseline", source: "recovery_v2",
            scoredDay: day(1), usesHRV: true, detail: "detail", contributors: []
        )
        XCTAssertNil(AtriaCurrentDayPresentation.currentDayPartialRecovery(
            fromRollupSummary: hrvBacked, rollupDay: day(1), now: incidentNow,
            calendar: calendar
        ), "An HRV-backed row is not a limited partial")
        let wrongDay = FrozenRecoverySummary(
            score: 54, confidence: "unverified", source: "recovery_v2",
            scoredDay: day(0), usesHRV: false, detail: "detail", contributors: []
        )
        XCTAssertNil(AtriaCurrentDayPresentation.currentDayPartialRecovery(
            fromRollupSummary: wrongDay, rollupDay: day(0), now: incidentNow,
            calendar: calendar
        ), "Yesterday's row can never be today's partial")
    }

    // MARK: - Sleep primary gate

    func testSleepPrimaryRequiresWakeOnDisplayedDay() {
        XCTAssertFalse(AtriaCurrentDayPresentation.sleepIsCurrentDayPrimary(
            sleepEnd: wake, now: incidentNow, calendar: calendar
        ), "An Aug-12 wake may not fill an Aug-13 ring")
        XCTAssertTrue(AtriaCurrentDayPresentation.sleepIsCurrentDayPrimary(
            sleepEnd: day(1).addingTimeInterval(14 * 3_600), now: incidentNow,
            calendar: calendar
        ))
        XCTAssertFalse(AtriaCurrentDayPresentation.sleepIsCurrentDayPrimary(
            sleepEnd: nil, now: incidentNow, calendar: calendar
        ))
    }

    // MARK: - Day navigation identity

    func testYesterdayAndTodayResolveDistinctIdentities() {
        let today = resolve(partial: partial54, partialStrain: 1.026)
        let yesterdayNow = day(0).addingTimeInterval(20 * 3_600)
        let yesterday = resolve(now: yesterdayNow, partial: nil, partialStrain: nil)
        XCTAssertNotEqual(today.identity, yesterday.identity)
        XCTAssertNotEqual(today.identity.displayCivilDay,
                          yesterday.identity.displayCivilDay)
        XCTAssertNotEqual(today.identity.valueState, yesterday.identity.valueState)
    }

    // MARK: - Widget/App Intent identity fence

    /// The App Intent reads the persisted widget snapshot. Past the display
    /// day's identity expiry it must fail closed to the learning dialog
    /// instead of re-wearing a prior day's values after relaunch. The widget
    /// extension enforces the same expiry via its own decode-time sanitizer.
    func testIntentSnapshotFailsClosedPastDisplayDayExpiry() {
        let now = incidentNow
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            recoveryExpiresAt: now.addingTimeInterval(-60), now: now
        ), "An expired display-day snapshot may not answer for today")
        XCTAssertTrue(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            recoveryExpiresAt: now.addingTimeInterval(3_600), now: now
        ))
        // Legacy payloads without identity keys keep their existing behavior.
        XCTAssertTrue(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            recoveryExpiresAt: nil, now: now
        ))
    }
}
