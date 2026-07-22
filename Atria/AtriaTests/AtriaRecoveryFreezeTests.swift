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

    private func rollup(day: Date,
                        hrv: Int? = nil,
                        restingHR: Int? = nil,
                        sleepDuration: TimeInterval? = nil,
                        strain: Double = 6) -> DailyRollup {
        DailyRollup(day: day,
                    sessions: 1,
                    activityCandidates: 0,
                    workouts: 0,
                    confirmedWorkouts: 0,
                    restCandidates: 0,
                    sleepReady: 0,
                    sleepCandidates: 0,
                    duration: 3_600,
                    sleepDuration: sleepDuration,
                    sleepSpan: sleepDuration,
                    sleepStart: nil,
                    sleepEnd: nil,
                    sleepSource: nil,
                    sleepStageSegments: [],
                    strain: strain,
                    avgHRV: hrv,
                    restingHR: restingHR,
                    avgRespiratoryRate: nil)
    }

    private func night(day: Date,
                       start: Date,
                       end: Date,
                       confirmed: Bool = true,
                       source: String = "manual_sleep",
                       hrv: Int? = 63) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: "night-\(day.timeIntervalSince1970)-\(confirmed)",
                                   day: day,
                                   start: start,
                                   end: end,
                                   duration: 7 * 3_600,
                                   restingHR: 49,
                                   hrv: hrv,
                                   respiratoryRate: 14.2,
                                   sleepEfficiency: 0.91,
                                   confidence: confirmed ? "manual_user_entered" : "review_needed",
                                   source: source,
                                   confirmed: confirmed,
                                   stageSegments: [])
    }

    func testHistoricalConfirmedMainSleepProjectsOntoOtherwiseSparseRollup() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 16)))
        let start = day.addingTimeInterval(-8 * 3_600)
        let end = day.addingTimeInterval(7 * 3_600)
        let confirmed = night(day: day, start: start, end: end)
        let sleep = SleepHistorySnapshot(nights: [confirmed], confirmedCount: 1, candidateCount: 0)

        let projected = try XCTUnwrap(SessionStore.makeSavedDailyMetrics(rollups: [rollup(day: day,
                                                                                         hrv: 88,
                                                                                         restingHR: 41,
                                                                                         sleepDuration: 9 * 3_600)],
                                                                         sleep: sleep,
                                                                         baseline: PersonalBaseline(),
                                                                         calendar: calendar).first)

        XCTAssertEqual(projected.hrv, 63)
        XCTAssertEqual(projected.restingHR, 49)
        XCTAssertEqual(projected.respiratoryRate, 14.2)
        XCTAssertEqual(projected.sleepDuration, 7 * 3_600)
        XCTAssertEqual(projected.sleepSpan, 15 * 3_600)
        XCTAssertEqual(projected.sleepStart, start)
        XCTAssertEqual(projected.sleepEnd, end)
        XCTAssertEqual(projected.sleepSource, "manual_sleep")
    }

    func testUnconfirmedSleepCandidateCannotProjectHistoricalRecoveryInputs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 16)))
        let candidate = night(day: day,
                              start: day.addingTimeInterval(-8 * 3_600),
                              end: day.addingTimeInterval(7 * 3_600),
                              confirmed: false,
                              source: "sleep_candidate")
        let sleep = SleepHistorySnapshot(nights: [candidate], confirmedCount: 0, candidateCount: 1)

        let projected = try XCTUnwrap(SessionStore.makeSavedDailyMetrics(rollups: [rollup(day: day)],
                                                                         sleep: sleep,
                                                                         baseline: PersonalBaseline(),
                                                                         calendar: calendar).first)

        XCTAssertNil(projected.hrv)
        XCTAssertNil(projected.restingHR)
        XCTAssertNil(projected.sleepDuration)
        XCTAssertNil(projected.sleepStart)
        XCTAssertNil(projected.sleepEnd)
        XCTAssertNil(projected.recoveryPercent)
        XCTAssertEqual(projected.strain, 6)
    }

    func testCurrentDayWithoutConfirmedSleepKeepsActivityButNotRecovery() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 16)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let historical = night(day: yesterday,
                               start: yesterday.addingTimeInterval(-8 * 3_600),
                               end: yesterday.addingTimeInterval(7 * 3_600))
        let sleep = SleepHistorySnapshot(nights: [historical], confirmedCount: 1, candidateCount: 0)
        let activity = metric(sleepDuration: nil,
                              sleepSpan: nil,
                              hrv: 71,
                              restingHR: 55,
                              respiratoryRate: nil,
                              recoveryPercent: 80,
                              strain: 8)
        let computedToday = SavedDailyMetric(day: today,
                                             recoveryPercent: activity.recoveryPercent,
                                             recoveryConfidence: activity.recoveryConfidence,
                                             hrv: activity.hrv,
                                             restingHR: activity.restingHR,
                                             respiratoryRate: activity.respiratoryRate,
                                             sleepDuration: nil,
                                             sleepSpan: nil,
                                             sleepStart: nil,
                                             sleepEnd: nil,
                                             sleepSource: nil,
                                             sleepStageSegments: [],
                                             sleepConsistencyPercent: nil,
                                             strain: activity.strain)

        let merged = SessionStore.mergeDailyMetricHistory(existing: [],
                                                          computed: [computedToday],
                                                          sessions: [],
                                                          sleep: sleep,
                                                          baseline: PersonalBaseline(),
                                                          maxHR: 190,
                                                          now: today.addingTimeInterval(12 * 3_600),
                                                          calendar: calendar)
        let retained = try XCTUnwrap(merged.first { calendar.isDate($0.day, inSameDayAs: today) })

        XCTAssertEqual(retained.restingHR, 55)
        XCTAssertEqual(retained.strain, 8)
        XCTAssertNil(retained.hrv)
        XCTAssertNil(retained.sleepDuration)
        XCTAssertNil(retained.recoveryPercent)
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

    func testMatchingConfirmedSleepRepairsPreviouslyBlankDayOneRecovery() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027,
                                                                   month: 1,
                                                                   day: 16)))
        let start = day.addingTimeInterval(-7 * 3_600)
        let end = day
        let confirmed = night(day: day,
                              start: start,
                              end: end,
                              hrv: nil)
        let sleep = SleepHistorySnapshot(nights: [confirmed],
                                         confirmedCount: 1,
                                         candidateCount: 0)
        let blank = SavedDailyMetric(day: day,
                                     recoveryPercent: nil,
                                     recoveryConfidence: "learning",
                                     hrv: nil,
                                     restingHR: confirmed.restingHR,
                                     respiratoryRate: confirmed.respiratoryRate,
                                     sleepDuration: confirmed.duration,
                                     sleepSpan: end.timeIntervalSince(start),
                                     sleepStart: start,
                                     sleepEnd: end,
                                     sleepSource: confirmed.source,
                                     sleepStageSegments: [],
                                     sleepConsistencyPercent: nil,
                                     strain: 2.5)

        XCTAssertTrue(SessionStore.frozenRecoveryMatchesConfirmedNight(
            frozen: blank,
            night: confirmed
        ), "the migration must not depend on a synthetic sleep edit")

        let merged = SessionStore.mergeDailyMetricHistory(
            existing: [blank],
            computed: [],
            sessions: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: end.addingTimeInterval(3_600),
            calendar: calendar
        )
        let repaired = try XCTUnwrap(merged.first)
        XCTAssertNotNil(repaired.recoveryPercent)
        XCTAssertEqual(repaired.recoveryConfidence,
                       Metrics.RecoveryEstimate.Confidence.unverified.rawValue)
        XCTAssertEqual(repaired.recoverySummary?.usesHRV, false)
        XCTAssertTrue(repaired.recoverySummary?.detail.contains("HRV unavailable") == true)
    }

    func testMatchingConfirmedSleepRepairsFrozenScoreThatFalselyClaimsMissingHRV() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027,
                                                                   month: 1,
                                                                   day: 17)))
        let start = day.addingTimeInterval(-6.5 * 3_600)
        let end = day
        let confirmed = night(day: day,
                              start: start,
                              end: end,
                              hrv: nil)
        let sleep = SleepHistorySnapshot(nights: [confirmed],
                                         confirmedCount: 1,
                                         candidateCount: 0)
        let contradictorySummary = FrozenRecoverySummary(
            score: 66,
            confidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            source: FrozenRecoverySummary.recoveryV2Source,
            model: "recovery_v2",
            scoredDay: day,
            usesHRV: true,
            detail: "HRV provisional baseline",
            contributors: [
                .init(kind: Metrics.RecoveryEstimate.Contributor.Kind.hrv.rawValue,
                      zScore: 0,
                      weight: 0.60,
                      detail: "HRV provisional baseline")
            ]
        )
        let frozen = SavedDailyMetric(
            day: day,
            recoveryPercent: 66,
            recoveryConfidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            hrv: nil,
            restingHR: confirmed.restingHR,
            respiratoryRate: confirmed.respiratoryRate,
            sleepDuration: confirmed.duration,
            sleepSpan: end.timeIntervalSince(start),
            sleepStart: start,
            sleepEnd: end,
            sleepSource: confirmed.source,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: 2.5,
            recoverySummary: contradictorySummary
        )

        XCTAssertTrue(SessionStore.frozenRecoveryMatchesConfirmedNight(
            frozen: frozen,
            night: confirmed
        ), "the repair must run even when the sleep inputs themselves are unchanged")

        let merged = SessionStore.mergeDailyMetricHistory(
            existing: [frozen],
            computed: [],
            sessions: [],
            sleep: sleep,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: end.addingTimeInterval(3_600),
            calendar: calendar
        )
        let repaired = try XCTUnwrap(merged.first)
        XCTAssertNotNil(repaired.recoveryPercent)
        XCTAssertEqual(repaired.hrv, nil)
        XCTAssertEqual(repaired.recoveryConfidence,
                       Metrics.RecoveryEstimate.Confidence.unverified.rawValue)
        XCTAssertEqual(repaired.recoverySummary?.usesHRV, false)
        XCTAssertEqual(repaired.recoverySummary?.contributors.first(where: {
            $0.kind == Metrics.RecoveryEstimate.Contributor.Kind.hrv.rawValue
        })?.weight, 0)
        XCTAssertTrue(repaired.recoverySummary?.detail.contains("HRV unavailable") == true)
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
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: recoveryEstimate(percent: 72),
                                                        scoredDay: wakeDay))
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

    func testPhysiologicalRecoveryResolverRejectsStaleSameDayFreezeAfterSleepSave() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2032,
                                                                   month: 1,
                                                                   day: 2)))
        let sleepStart = day.addingTimeInterval(60 * 60)
        let wake = day.addingTimeInterval(9 * 60 * 60)
        let anchor = confirmedNight(id: "new-anchor",
                                    day: day,
                                    start: sleepStart,
                                    end: wake,
                                    restingHR: 51,
                                    hrv: 66,
                                    respiratoryRate: 14.2)
        let cycle = AtriaPhysiologicalCycle(start: wake,
                                            boundaryKind: .mainSleep,
                                            anchorSleepID: anchor.id,
                                            expectedInterval: 24 * 3_600)
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: recoveryEstimate(percent: 79),
                                                        scoredDay: day))
        let rollup = DailyRollupStoreEntry(day: day,
                                           recoverySummary: frozen,
                                           calendar: calendar)
        // This row belongs to an older sleep that happened to end on the same
        // civil day. It is the exact persistence race that occurs while a newly
        // confirmed sleep is awaiting its background daily-metric refresh.
        let staleMetric = dailyMetric(day: day,
                                      recovery: 79,
                                      sleepStart: sleepStart.addingTimeInterval(-2 * 3_600),
                                      sleepEnd: wake.addingTimeInterval(-2 * 3_600),
                                      restingHR: 55,
                                      hrv: 48,
                                      respiratoryRate: 15.1)

        let resolved = DailyRecoveryResolver.summary(rollups: [rollup],
                                                     metrics: [staleMetric],
                                                     physiologicalCycle: cycle,
                                                     anchorSleep: anchor,
                                                     calendar: calendar)

        XCTAssertNil(resolved)
        XCTAssertEqual(DailyRecoveryResolver.currentEstimate(
            liveEstimate: recoveryEstimate(percent: 44),
            rollups: [rollup],
            metrics: [staleMetric],
            physiologicalCycle: cycle,
            anchorSleep: anchor,
            calendar: calendar
        ).percent, 44)
    }

    func testPhysiologicalRecoveryResolverAcceptsFreezeForCurrentConfirmedSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2032,
                                                                   month: 1,
                                                                   day: 2)))
        let sleepStart = day.addingTimeInterval(60 * 60)
        let wake = day.addingTimeInterval(9 * 60 * 60)
        let anchor = confirmedNight(id: "current-anchor",
                                    day: day,
                                    start: sleepStart,
                                    end: wake,
                                    restingHR: 51,
                                    hrv: 66,
                                    respiratoryRate: 14.2)
        let cycle = AtriaPhysiologicalCycle(start: wake,
                                            boundaryKind: .mainSleep,
                                            anchorSleepID: anchor.id,
                                            expectedInterval: 24 * 3_600)
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: recoveryEstimate(percent: 79),
                                                        scoredDay: day))
        let rollup = DailyRollupStoreEntry(day: day,
                                           recoverySummary: frozen,
                                           calendar: calendar)
        let matchingMetric = dailyMetric(day: day,
                                         recovery: 79,
                                         sleepStart: sleepStart,
                                         sleepEnd: wake,
                                         restingHR: 51,
                                         hrv: 66,
                                         respiratoryRate: 14.2)

        let resolved = DailyRecoveryResolver.summary(rollups: [rollup],
                                                     metrics: [matchingMetric],
                                                     physiologicalCycle: cycle,
                                                     anchorSleep: anchor,
                                                     calendar: calendar)

        XCTAssertEqual(resolved?.score, 79)
    }

    func testMissingConfirmedSleepKeepsExplicitlyLimitedCurrentEstimate() {
        let cycle = AtriaPhysiologicalCycle(start: at(24),
                                            boundaryKind: .noSleepFallback,
                                            anchorSleepID: "prior-night",
                                            expectedInterval: 24 * 3_600)
        let live = recoveryEstimate(percent: 88)

        let resolved = DailyRecoveryResolver.currentEstimate(
            liveEstimate: live,
            rollups: [],
            metrics: [],
            physiologicalCycle: cycle
        )

        XCTAssertEqual(resolved, live)
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

    func testRecoveryProvenanceSurvivesMetricAndRollupJSONRoundTrip() throws {
        let day = at(24)
        let estimate = Metrics.RecoveryEstimate(
            percent: 74,
            confidence: .personalBaseline,
            usesHRV: true,
            detail: "HRV above baseline",
            contributors: [
                .init(kind: .hrv,
                      zScore: 1.25,
                      weight: 0.55,
                      detail: "overnight RMSSD",
                      displayValue: "62 ms",
                      direction: 1)
            ]
        )
        let summary = try XCTUnwrap(FrozenRecoverySummary(estimate: estimate, scoredDay: day))
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 74,
                                      recoveryConfidence: "legacy-placeholder",
                                      hrv: 62,
                                      restingHR: 51,
                                      respiratoryRate: 13.8,
                                      sleepDuration: 7.5 * 3_600,
                                      sleepSpan: 8 * 3_600,
                                      sleepStart: day.addingTimeInterval(-8 * 3_600),
                                      sleepEnd: day,
                                      sleepSource: "sleep_window",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: 88,
                                      strain: 5.2,
                                      recoverySummary: summary)

        let metricData = try JSONEncoder().encode(metric)
        let decodedMetric = try JSONDecoder().decode(SavedDailyMetric.self, from: metricData)
        let normalizedSummary = summary.replacingScoredDay(decodedMetric.day)
        XCTAssertEqual(decodedMetric.recoverySummary, normalizedSummary)
        XCTAssertEqual(decodedMetric.recoveryConfidence, summary.confidence)

        let rollup = try XCTUnwrap(SessionStore.makeDailyRollupStoreEntries(
            metrics: [decodedMetric], sessions: []
        ).first)
        let decodedRollup = try JSONDecoder().decode(
            DailyRollupStoreEntry.self,
            from: JSONEncoder().encode(rollup)
        )
        let resolved = try XCTUnwrap(decodedRollup.resolvedRecoverySummary(matching: decodedMetric))
        XCTAssertEqual(resolved, normalizedSummary)
        XCTAssertEqual(resolved.recoveryEstimate, estimate)
    }

    func testLearningEstimateCannotFreezeAsZero() {
        let estimate = Metrics.RecoveryEstimate(percent: nil,
                                                confidence: .learning,
                                                usesHRV: false,
                                                detail: "learning",
                                                contributors: [])
        XCTAssertNil(FrozenRecoverySummary(estimate: estimate, scoredDay: at(24)))
    }

    private func recoveryEstimate(percent: Int) -> Metrics.RecoveryEstimate {
        Metrics.RecoveryEstimate(percent: percent,
                                 confidence: .personalBaseline,
                                 usesHRV: true,
                                 detail: "test",
                                 contributors: [])
    }

    private func confirmedNight(id: String,
                                day: Date,
                                start: Date,
                                end: Date,
                                restingHR: Int,
                                hrv: Int,
                                respiratoryRate: Double) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: day,
                                   start: start,
                                   end: end,
                                   duration: end.timeIntervalSince(start),
                                   restingHR: restingHR,
                                   hrv: hrv,
                                   respiratoryRate: respiratoryRate,
                                   sleepEfficiency: 0.9,
                                   confidence: "confirmed",
                                   source: "sleep_window",
                                   confirmed: true,
                                   stageSegments: [])
    }

    private func dailyMetric(day: Date,
                             recovery: Int,
                             sleepStart: Date,
                             sleepEnd: Date,
                             restingHR: Int,
                             hrv: Int,
                             respiratoryRate: Double) -> SavedDailyMetric {
        let duration = sleepEnd.timeIntervalSince(sleepStart)
        return SavedDailyMetric(day: day,
                                recoveryPercent: recovery,
                                recoveryConfidence: Metrics.RecoveryEstimate.Confidence.personalBaseline.rawValue,
                                hrv: hrv,
                                restingHR: restingHR,
                                respiratoryRate: respiratoryRate,
                                sleepDuration: duration,
                                sleepSpan: duration,
                                sleepStart: sleepStart,
                                sleepEnd: sleepEnd,
                                sleepSource: "sleep_window",
                                sleepStageSegments: [],
                                sleepConsistencyPercent: nil,
                                strain: nil)
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
