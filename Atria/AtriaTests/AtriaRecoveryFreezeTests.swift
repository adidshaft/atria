import XCTest
@testable import Atria

/// Recovery-freeze staleness (2026-07-08 Scope 1): the frozen daily recovery is
/// preserved all day, but must RE-MINT when the scored night's inputs change
/// (sleep confirm / EXTEND / adjust) — otherwise the persisted recovery + trend
/// point outlive the night they describe. Locks the pure change-detector so a
/// night edit re-freezes while intra-day strain accrual never does.
final class AtriaRecoveryFreezeTests: XCTestCase {
    private func at(_ h: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + h * 3600) }

    private func metric(sleepEnd: Date? = nil,
                        sleepDuration: TimeInterval? = 7 * 3600,
                        sleepSpan: TimeInterval? = 7.5 * 3600,
                        hrv: Int? = 45,
                        restingHR: Int? = 52,
                        respiratoryRate: Double? = 14,
                        recoveryPercent: Int? = 70,
                        strain: Double? = 5) -> SavedDailyMetric {
        SavedDailyMetric(day: at(0), recoveryPercent: recoveryPercent, recoveryConfidence: "local",
                         hrv: hrv, restingHR: restingHR, respiratoryRate: respiratoryRate,
                         sleepDuration: sleepDuration, sleepSpan: sleepSpan,
                         sleepStart: nil, sleepEnd: sleepEnd, sleepSource: "auto_sleep",
                         sleepStageSegments: [], sleepConsistencyPercent: nil, strain: strain)
    }

    func testUnchangedNightIsNotAChange() {
        let a = metric(sleepEnd: at(6))
        XCTAssertFalse(SessionStore.dailyRecoveryInputsChanged(frozen: a, fresh: a))
    }

    func testExtendedNightEndTriggersRemint() {
        // Wake-then-sleep-again grew the night 0h→6h into 0h→8h.
        let frozen = metric(sleepEnd: at(6), sleepDuration: 6 * 3600)
        let extended = metric(sleepEnd: at(8), sleepDuration: 8 * 3600)
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: extended))
    }

    func testCrossMidnightConfirmedSleepRemintsWithoutComputedToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 16)))
        let sleepStart = day.addingTimeInterval(-8 * 3_600)
        let sleepEnd = day.addingTimeInterval(7 * 3_600)
        let now = day.addingTimeInterval(10 * 3_600)
        let confirmed = UserConfirmedSleep(id: "cross-midnight-confirmed",
                                           createdAt: sleepEnd,
                                           start: sleepStart,
                                           end: sleepEnd,
                                           source: "manual_sleep",
                                           confidence: "manual_user_entered",
                                           sessions: 1,
                                           samples: 1_000,
                                           avgHR: 52,
                                           peakHR: 66,
                                           restingHR: 48,
                                           hrv: 64,
                                           hrvWindowCount: 4,
                                           duration: 8 * 3_600,
                                           span: 15 * 3_600,
                                           reason: "test",
                                           motionSource: "manual",
                                           motionValidated: false,
                                           stageSegments: nil)
        let sleep = SleepHistorySnapshot(rollups: [],
                                         confirmedSleeps: [confirmed],
                                         calendar: calendar)
        let frozen = SavedDailyMetric(day: day,
                                      recoveryPercent: 1,
                                      recoveryConfidence: "initial",
                                      hrv: 40,
                                      restingHR: 58,
                                      respiratoryRate: nil,
                                      sleepDuration: 6 * 3_600,
                                      sleepSpan: 6 * 3_600,
                                      sleepStart: day.addingTimeInterval(-6 * 3_600),
                                      sleepEnd: day,
                                      sleepSource: "auto_sleep",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: nil,
                                      strain: 3)

        let expected = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(for: day,
                                                                                computed: [],
                                                                                sessions: [],
                                                                                sleep: sleep,
                                                                                baseline: PersonalBaseline(),
                                                                                maxHR: 190,
                                                                                now: now,
                                                                                calendar: calendar))
        let confirmedNight = try XCTUnwrap(sleep.latest)
        XCTAssertFalse(SessionStore.frozenRecoveryMatchesConfirmedNight(frozen: frozen,
                                                                         night: confirmedNight))
        XCTAssertTrue(SessionStore.frozenRecoveryMatchesConfirmedNight(frozen: expected,
                                                                        night: confirmedNight))
        let merged = SessionStore.mergeDailyMetricHistory(existing: [frozen],
                                                          computed: [],
                                                          sessions: [],
                                                          sleep: sleep,
                                                          baseline: PersonalBaseline(),
                                                          maxHR: 190,
                                                          now: now,
                                                          calendar: calendar)
        let reminted = try XCTUnwrap(merged.first { calendar.isDate($0.day, inSameDayAs: day) })

        XCTAssertEqual(reminted.recoveryPercent, expected.recoveryPercent)
        XCTAssertEqual(reminted.recoveryConfidence, expected.recoveryConfidence)
        XCTAssertEqual(reminted.hrv, 64)
        XCTAssertEqual(reminted.restingHR, 48)
        XCTAssertEqual(reminted.sleepEnd, sleepEnd)
        XCTAssertEqual(reminted.sleepDuration, 8 * 3_600)
        XCTAssertNotEqual(reminted.recoveryPercent, frozen.recoveryPercent)
    }

    func testBiologicalAgeWeeklyCadenceInvalidatesWhenDeferredSessionsFinishLoading() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 14)))
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .female,
                                     updated: now,
                                     hasCompletedOnboarding: true)
        let beforeLoad = SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                    sessionsLoaded: false,
                                                                    now: now,
                                                                    calendar: calendar)
        let afterLoad = SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                   sessionsLoaded: true,
                                                                   now: now,
                                                                   calendar: calendar)

        XCTAssertNotEqual(beforeLoad, afterLoad)
    }

    func testPreparedDailyRollupsSkipPersistenceOnlyWhenEveryRowMatches() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 16)))
        let stored = DailyRollupStoreEntry(day: day,
                                           recovery: 72,
                                           rhr: 51,
                                           strain: 8.4,
                                           calendar: calendar)

        XCTAssertFalse(SessionStore.preparedDailyRollupsNeedPersistence([stored],
                                                                         existing: [stored],
                                                                         calendar: calendar))

        var changed = stored
        changed.recovery = 73
        XCTAssertTrue(SessionStore.preparedDailyRollupsNeedPersistence([changed],
                                                                        existing: [stored],
                                                                        calendar: calendar))

        let missingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let missing = DailyRollupStoreEntry(day: missingDay, recovery: 72, calendar: calendar)
        XCTAssertTrue(SessionStore.preparedDailyRollupsNeedPersistence([stored, missing],
                                                                        existing: [stored],
                                                                        calendar: calendar))
    }

    func testChangedReadinessInputsTriggerRemint() {
        let frozen = metric(sleepEnd: at(6))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), hrv: 52)))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), restingHR: 48)))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), respiratoryRate: 16)))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), sleepSpan: 8 * 3600)))
    }

    func testStrainAccrualOrRecoveryOutputAloneIsNotANightChange() {
        // Strain accrues all day and recovery is the OUTPUT, not an input — a
        // difference in either must NOT re-mint, or the daily freeze is defeated.
        let frozen = metric(sleepEnd: at(6), recoveryPercent: 70, strain: 3)
        let laterInDay = metric(sleepEnd: at(6), recoveryPercent: 55, strain: 12)
        XCTAssertFalse(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: laterInDay))
    }

    func testFrozenRollupRestoresScoreAndProvenanceAtomically() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = FrozenRecoverySummary(
            score: 74,
            confidence: Metrics.RecoveryEstimate.Confidence.personalBaseline.rawValue,
            source: FrozenRecoverySummary.recoveryV2Source,
            model: "recovery_v2",
            scoredDay: day,
            usesHRV: true,
            detail: "Morning HRV and resting heart rate",
            contributors: [
                .init(kind: Metrics.RecoveryEstimate.Contributor.Kind.hrv.rawValue,
                      zScore: 0.6,
                      weight: 0.65,
                      detail: "Above baseline")
            ]
        )
        let rollup = DailyRollupStoreEntry(day: day,
                                           recoverySummary: summary)
        let resolved = try XCTUnwrap(rollup.resolvedRecoverySummary())
        let estimate = resolved.recoveryEstimate

        XCTAssertEqual(estimate.percent, 74)
        XCTAssertEqual(estimate.confidence, .personalBaseline)
        XCTAssertTrue(estimate.usesHRV)
        XCTAssertEqual(estimate.detail, "Morning HRV and resting heart rate")
        XCTAssertEqual(estimate.contributors.count, 1)
    }

    func testPhysiologicalRecoveryResolverKeepsWakeDayScoreAcrossCivilMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let wakeDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2032,
                                                                       month: 1,
                                                                       day: 2)))
        let wake = wakeDay.addingTimeInterval(19 * 3_600)
        let cycle = AtriaPhysiologicalCycle(start: wake,
                                            boundaryKind: .mainSleep,
                                            anchorSleepID: "shift-sleep",
                                            expectedInterval: 24 * 3_600)
        let frozen = FrozenRecoverySummary(estimate: recoveryEstimate(percent: 72),
                                           scoredDay: wakeDay)
        let rollup = DailyRollupStoreEntry(day: wakeDay,
                                           recoverySummary: frozen,
                                           calendar: calendar)

        let resolved = DailyRecoveryResolver.currentEstimate(
            liveEstimate: recoveryEstimate(percent: 41),
            rollups: [rollup],
            metrics: [],
            physiologicalCycle: cycle,
            calendar: calendar
        )

        XCTAssertEqual(resolved.percent, 72)
        XCTAssertEqual(resolved.detail, frozen.detail)
    }

    func testAllNighterRecoveryFailsClosedInsteadOfReusingPriorHRV() {
        let cycle = AtriaPhysiologicalCycle(start: at(24),
                                            boundaryKind: .noSleepFallback,
                                            anchorSleepID: "prior-night",
                                            expectedInterval: 24 * 3_600)

        let resolved = DailyRecoveryResolver.currentEstimate(
            liveEstimate: recoveryEstimate(percent: 88),
            rollups: [],
            metrics: [],
            physiologicalCycle: cycle
        )

        XCTAssertEqual(resolved.percent, 1)
        XCTAssertEqual(resolved.confidence, .unverified)
        XCTAssertFalse(resolved.usesHRV)
        XCTAssertEqual(resolved.contributors.first?.kind, .sleep)
    }

    func testInitialWearFallbackCanUseCurrentLiveEstimate() {
        let live = recoveryEstimate(percent: 63)
        let cycle = AtriaPhysiologicalCycle(start: at(0),
                                            boundaryKind: .initialFallback,
                                            anchorSleepID: nil,
                                            expectedInterval: 24 * 3_600)

        XCTAssertEqual(DailyRecoveryResolver.currentEstimate(liveEstimate: live,
                                                              rollups: [],
                                                              metrics: [],
                                                              physiologicalCycle: cycle),
                       live)
    }

    private func recoveryEstimate(percent: Int) -> Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(percent: percent,
                                 confidence: .personalBaseline,
                                 usesHRV: true,
                                 detail: "test",
                                 contributors: [])
    }

    // MARK: - Period selector reduced to D/W/M (2026-07-08)

    /// The interactive range bars now offer only Day/Week/Month.
    func testPrimarySegmentsAreDayWeekMonth() {
        XCTAssertEqual(AtriaTrendRange.primarySegments, [.day, .week, .month])
    }

    /// Dropping the deeper ranges from the UI must NOT drop them from the enum:
    /// the per-range chart/summary data-prep loops and the internal `.all` read
    /// (yesterday-strain) still key off the full CaseIterable set.
    func testDeeperRangesStayInAllCasesForDataPrep() {
        for deeper in [AtriaTrendRange.quarter, .sixMonths, .year, .all] {
            XCTAssertTrue(AtriaTrendRange.allCases.contains(deeper),
                          "\(deeper) must remain in allCases for range math + data prep")
        }
    }
}
