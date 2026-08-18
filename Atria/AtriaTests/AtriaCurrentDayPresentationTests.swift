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

    // MARK: - Cross-midnight hold (field report 2026-08-19, item 4)

    /// "As soon as 12am midnight passes, the rings vanish." Midnight is a
    /// calendar event, not a physiological one: at 00:30 the wearer is still in
    /// the same evening and simply has not slept yet, so the cycle they are
    /// living in is still the right primary.
    func testLiveCycleSurvivesCivilMidnight() throws {
        // 00:30 on the day after an 08:00 wake — 16.5 h awake.
        let earlyWake = day(0).addingTimeInterval(8 * 3_600)
        let justAfterMidnight = day(1).addingTimeInterval(30 * 60)
        let resolution = AtriaCurrentDayPresentation.resolve(
            now: justAfterMidnight,
            cycleStart: earlyWake,
            cycleEnd: earlyWake.addingTimeInterval(24 * 3_600 + 30 * 60),
            anchorSleepID: "sleep-aug12",
            cycleValueSourceDay: earlyWake,
            currentDayPartialRecovery: nil,
            currentDayPartialStrain: nil,
            priorCycle: priorCycle,
            calendar: calendar
        )

        XCTAssertEqual(resolution.identity.valueState, .currentCycleAcrossMidnight)
        XCTAssertNil(resolution.recoveryOverride,
                     "the cycle projection stays the primary recovery — no awaiting override")
        XCTAssertNil(resolution.strainOverride,
                     "strain must not be forced to 0 by the civil rollover")
        XCTAssertFalse(resolution.sleepIsAwaitingCurrentSleep,
                       "the sleep ring must not blank while the night has not happened yet")
        // Primary, but never silently wearing today's label: the identity keeps
        // the cycle's own source day, which is NOT the displayed civil day.
        XCTAssertEqual(resolution.identity.sourceCivilDay, earlyWake,
                       "the values must stay dated to the cycle that produced them")
        XCTAssertFalse(
            calendar.isDate(try XCTUnwrap(resolution.identity.sourceCivilDay),
                            inSameDayAs: resolution.identity.displayCivilDay),
            "a held cycle must never claim the displayed civil day as its source"
        )
        XCTAssertEqual(resolution.identity.sourceSleepID, "sleep-aug12")
        XCTAssertNotNil(resolution.priorCycle,
                        "the disclosure stays available so the surface can date what it shows")
    }

    /// The guard that keeps the cross-midnight hold from becoming the incident.
    /// The naive version of this fix — "primary while `now < cycleEnd`" — passes
    /// at 14:43 the next day, because that IS inside wake + 24 h + 30 min. What
    /// separates the two cases is elapsed waking time.
    func testCrossMidnightHoldExpiresBeforeTheAugustIncidentWindow() throws {
        // The incident itself: 23 h 16 min after a 15:27 wake, still pre-rollover.
        let resolution = resolve(partial: partial54, partialStrain: 1.026)
        XCTAssertNotEqual(resolution.identity.valueState, .currentCycleAcrossMidnight,
                          "23 h awake is not 'the night has not happened yet'")
        XCTAssertEqual(resolution.identity.valueState, .currentPartial)
        XCTAssertEqual(try XCTUnwrap(resolution.recoveryOverride).percent, 54)

        // The boundary itself, exercised from both sides.
        let hold = AtriaCurrentDayPresentation.maximumWakingDayHeldAcrossMidnight
        func stateAt(_ elapsed: TimeInterval) -> AtriaMetricPresentationValueState {
            AtriaCurrentDayPresentation.resolve(
                now: wake.addingTimeInterval(elapsed),
                cycleStart: wake,
                cycleEnd: wake.addingTimeInterval(24 * 3_600 + 30 * 60),
                anchorSleepID: "sleep-aug12",
                cycleValueSourceDay: wake,
                currentDayPartialRecovery: nil,
                currentDayPartialStrain: nil,
                priorCycle: priorCycle,
                calendar: calendar
            ).identity.valueState
        }
        XCTAssertEqual(stateAt(hold - 60), .currentCycleAcrossMidnight)
        XCTAssertEqual(stateAt(hold + 60), .awaitingCurrentSleep,
                       "past a plausible waking day the night HAS been missed; stop showing it")
    }

    /// A cycle with no anchoring sleep has nothing to hold, and a backwards
    /// clock must not manufacture one.
    func testCrossMidnightHoldRequiresARealAnchorAndAForwardClock() {
        func state(anchor: String?, elapsed: TimeInterval) -> AtriaMetricPresentationValueState {
            AtriaCurrentDayPresentation.resolve(
                now: wake.addingTimeInterval(elapsed),
                cycleStart: wake,
                cycleEnd: wake.addingTimeInterval(24 * 3_600 + 30 * 60),
                anchorSleepID: anchor,
                cycleValueSourceDay: wake,
                currentDayPartialRecovery: nil,
                currentDayPartialStrain: nil,
                priorCycle: priorCycle,
                calendar: calendar
            ).identity.valueState
        }
        XCTAssertEqual(state(anchor: nil, elapsed: 10 * 3_600), .awaitingCurrentSleep,
                       "no anchoring sleep means there is no cycle to hold")
        // A backwards clock that stays inside the wake's own civil day is still
        // legitimately `.current` — `sourceIsToday` wins and the hold never runs.
        XCTAssertEqual(state(anchor: "sleep-aug12", elapsed: -3_600), .current)
        // Landing on an EARLIER civil day is the case the forward-clock guard
        // exists for: a negative waking age must not be read as "under 18 h".
        XCTAssertEqual(state(anchor: "sleep-aug12", elapsed: -20 * 3_600),
                       .awaitingCurrentSleep,
                       "a backwards clock must not manufacture a cross-midnight hold")
    }

    /// The sleep ring must hold on exactly the same terms, or recovery and
    /// strain would show the cycle while hours went blank beside them.
    func testSleepRingHoldsAcrossMidnightOnTheSameTerms() {
        let earlyWake = day(0).addingTimeInterval(8 * 3_600)
        let sleepEnd = earlyWake            // woke from the anchoring night
        let cycleEnd = earlyWake.addingTimeInterval(24 * 3_600 + 30 * 60)
        let justAfterMidnight = day(1).addingTimeInterval(30 * 60)

        XCTAssertTrue(AtriaCurrentDayPresentation.sleepIsCurrentDayPrimary(
            sleepEnd: sleepEnd, now: justAfterMidnight,
            cycleStart: earlyWake, cycleEnd: cycleEnd, calendar: calendar
        ))
        // Past the hold it reverts, matching `resolve`.
        XCTAssertFalse(AtriaCurrentDayPresentation.sleepIsCurrentDayPrimary(
            sleepEnd: sleepEnd,
            now: earlyWake.addingTimeInterval(
                AtriaCurrentDayPresentation.maximumWakingDayHeldAcrossMidnight + 60
            ),
            cycleStart: earlyWake, cycleEnd: cycleEnd, calendar: calendar
        ))
        // Without cycle context the original same-civil-day rule is unchanged.
        XCTAssertFalse(AtriaCurrentDayPresentation.sleepIsCurrentDayPrimary(
            sleepEnd: sleepEnd, now: justAfterMidnight, calendar: calendar
        ))
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
        let dayKey = WidgetSnapshotPublisher.civilDayKey(for: now, calendar: calendar)
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: now, displayCivilDayKey: dayKey,
            recoveryExpiresAt: now.addingTimeInterval(-60), now: now
        ), "An expired display-day snapshot may not answer for today")
        XCTAssertTrue(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: now, displayCivilDayKey: dayKey,
            recoveryExpiresAt: now.addingTimeInterval(3_600), now: now
        ))
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: now, displayCivilDayKey: dayKey,
            recoveryExpiresAt: now.addingTimeInterval(3_600),
            biomarkerExpiresAt: now.addingTimeInterval(-1),
            now: now
        ), "Siri may not revive an expired current-cycle RHR/HRV")
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: now, displayCivilDayKey: dayKey,
            recoveryExpiresAt: now.addingTimeInterval(3_600),
            biomarkerExpiresAt: now.addingTimeInterval(3_600),
            strainExpiresAt: now.addingTimeInterval(-1),
            now: now
        ), "Siri may not describe an expired cumulative-strain cycle as current")
        // Same-day legacy payloads remain usable; an older one decodes but may
        // not answer indefinitely after the local day changes.
        XCTAssertTrue(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: now.addingTimeInterval(-60), displayCivilDayKey: nil,
            recoveryExpiresAt: nil, now: now
        ))
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: day(0), displayCivilDayKey: nil,
            recoveryExpiresAt: nil, now: now
        ))
    }

    func testIntentSnapshotRejectsAKeyFromAnotherLocalDayAfterTravel() {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var california = Calendar(identifier: .gregorian)
        california.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let instant = Date(timeIntervalSince1970: 1_786_386_600)
        let indiaKey = WidgetSnapshotPublisher.civilDayKey(for: instant, calendar: india)
        let californiaKey = WidgetSnapshotPublisher.civilDayKey(for: instant, calendar: california)
        guard indiaKey != californiaKey else { return XCTFail("fixture must cross a civil day") }
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: instant,
            displayCivilDayKey: indiaKey,
            recoveryExpiresAt: instant.addingTimeInterval(86_400),
            now: instant,
            calendar: california
        ))
    }

    func testIntentAndWidgetIdentityRejectAnOldZoneEvenWhenDateKeyMatches() {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var california = Calendar(identifier: .gregorian)
        california.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let instant = ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!
        let indiaKey = WidgetSnapshotPublisher.civilDayKey(for: instant, calendar: india)
        let californiaKey = WidgetSnapshotPublisher.civilDayKey(for: instant, calendar: california)
        XCTAssertEqual(indiaKey, californiaKey,
                       "The fixture must isolate timezone identity from date identity")
        XCTAssertFalse(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: instant,
            displayCivilDayKey: indiaKey,
            displayTimeZoneIdentifier: india.timeZone.identifier,
            recoveryExpiresAt: instant.addingTimeInterval(86_400),
            now: instant,
            calendar: california
        ))
        XCTAssertTrue(AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay(
            createdAt: instant,
            displayCivilDayKey: californiaKey,
            displayTimeZoneIdentifier: california.timeZone.identifier,
            recoveryExpiresAt: instant.addingTimeInterval(86_400),
            now: instant,
            calendar: california
        ))
    }

    func testSleepRingFillUsesTheSameRoundedNeedAndGoalFallbackAsToday() {
        let qualified = AtriaCurrentCycleSleepFillProjection.resolve(
            sleptHours: 6.73,
            nightlyNeedHours: 8.21,
            configuredGoalHours: 8
        )
        let expectedPercent = AtriaSleepBudget.performancePercent(
            slept: 6.73, needed: 8.21
        )
        XCTAssertEqual(qualified.authority, .nightlyNeed)
        XCTAssertEqual(qualified.fraction, Double(expectedPercent) / 100)

        let reviewOnly = AtriaCurrentCycleSleepFillProjection.resolve(
            sleptHours: 3.5,
            nightlyNeedHours: nil,
            configuredGoalHours: 7
        )
        XCTAssertEqual(reviewOnly.authority, .configuredGoal)
        XCTAssertEqual(try? XCTUnwrap(reviewOnly.fraction), 0.5)
        XCTAssertNil(AtriaCurrentCycleSleepFillProjection.resolve(
            sleptHours: nil,
            nightlyNeedHours: 8,
            configuredGoalHours: 8
        ).fraction)
    }
}
