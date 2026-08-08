import XCTest
@testable import Atria

/// Recovery-freeze staleness (2026-07-08 Scope 1): the frozen daily recovery is
/// preserved all day, but must RE-MINT when the scored night's inputs change
/// (sleep confirm / EXTEND / adjust) — otherwise the persisted recovery + trend
/// point outlive the night they describe. Locks the pure change-detector so a
/// night edit re-freezes while intra-day strain accrual never does.
final class AtriaRecoveryFreezeTests: XCTestCase {
    private func at(_ h: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + h * 3600) }

    func testHistoryAndSleepWaitForMatchingMetricRollupPublication() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let entry = try XCTUnwrap(source.range(
            of: "private func publishFullHistorySnapshotIfCurrent"
        ))
        let prepared = try XCTUnwrap(source.range(
            of: "private func publishPreparedDailyMetricsAndRollupsIfCurrent"
        ))
        let entryBody = source[entry.lowerBound..<prepared.lowerBound]
        XCTAssertFalse(entryBody.contains("historySnapshot = history"))
        XCTAssertFalse(entryBody.contains("sleepHistorySnapshot = sleep"))

        let persistence = try XCTUnwrap(source.range(
            of: "private func persistDailyRollups",
            range: prepared.upperBound..<source.endIndex
        ))
        let preparedBody = source[prepared.lowerBound..<persistence.lowerBound]
        XCTAssertTrue(preparedBody.contains("historySnapshot = history"))
        XCTAssertTrue(preparedBody.contains("sleepHistorySnapshot = sleep"))
        XCTAssertTrue(
            preparedBody.range(of: "sleepHistorySnapshot = sleep")!.lowerBound
                < preparedBody.range(of: "persistPreparedDailyRollups(preparation)")!.lowerBound
        )
    }

    func testFrozenRecoveryAcceptsLinkedResumedFinalWakeWithoutAcceptingStaleEdit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = at(24)
        let start = day.addingTimeInterval(-10 * 3_600)
        let originalEnd = start.addingTimeInterval(4 * 3_600)
        let finalWake = day
        let original = SleepHistorySnapshot.Night(
            id: "main-fragment",
            day: day,
            start: start,
            end: originalEnd,
            duration: 4 * 3_600,
            restingHR: 63,
            hrv: 42,
            respiratoryRate: 10.5,
            sleepEfficiency: 0.82,
            confidence: "confirmed",
            source: "overnight_sleep",
            confirmed: true,
            stageSegments: []
        )
        let cycle = AtriaPhysiologicalCycle(
            start: finalWake,
            boundaryKind: .mainSleep,
            anchorSleepID: original.id,
            expectedInterval: 24 * 3_600
        )
        let estimate = Metrics.RecoveryEstimate(
            percent: 39,
            confidence: .unverified,
            usesHRV: true,
            detail: "frozen linked night",
            contributors: []
        )
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: estimate, scoredDay: day))
        let metric = SavedDailyMetric(
            day: day,
            recoveryPercent: 39,
            recoveryConfidence: estimate.confidence.rawValue,
            hrv: 42,
            restingHR: 63,
            respiratoryRate: 10.5,
            sleepDuration: 6 * 3_600,
            sleepSpan: finalWake.timeIntervalSince(start),
            sleepStart: start,
            sleepEnd: finalWake,
            sleepSource: "overnight_sleep",
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: nil,
            recoverySummary: frozen
        )
        let rollup = DailyRollupStoreEntry(
            day: day,
            recoverySummary: frozen,
            calendar: calendar
        )

        XCTAssertEqual(DailyRecoveryResolver.summary(
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            anchorSleep: original,
            calendar: calendar
        )?.score, 39)

        let sameBoundaryEdit = SleepHistorySnapshot.Night(
            id: original.id,
            day: day,
            start: start,
            end: finalWake,
            duration: 5 * 3_600,
            restingHR: 63,
            hrv: 42,
            respiratoryRate: 10.5,
            sleepEfficiency: 0.82,
            confidence: "confirmed",
            source: "overnight_sleep",
            confirmed: true,
            stageSegments: []
        )
        XCTAssertNil(DailyRecoveryResolver.summary(
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            anchorSleep: sameBoundaryEdit,
            calendar: calendar
        ), "a true same-boundary edit must still invalidate the frozen row")
    }

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

    func testRecoveryUsesOnlyMotionBackedSleepEfficiencyOnHistoricalAndMorningPaths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027,
                                                                   month: 1,
                                                                   day: 16)))
        let start = day.addingTimeInterval(-8 * 3_600)
        let end = day

        func sleepNight(efficiency: Double?, motionValidated: Bool) -> SleepHistorySnapshot.Night {
            SleepHistorySnapshot.Night(
                id: "efficiency-\(motionValidated)-\(efficiency ?? -1)",
                day: day,
                start: start,
                end: end,
                duration: 8 * 3_600,
                restingHR: 52,
                hrv: nil,
                respiratoryRate: nil,
                sleepEfficiency: efficiency,
                confidence: motionValidated
                    ? "user_confirmed_motion_validated"
                    : "user_confirmed_hr_only",
                source: "aggregate_sleep",
                confirmed: true,
                stageSegments: [],
                eventTimeZoneIdentifier: "UTC",
                motionValidated: motionValidated
            )
        }

        let hrOnlyWithRawCoverage = sleepNight(efficiency: 1, motionValidated: false)
        let hrOnlyWithoutEfficiency = sleepNight(efficiency: nil, motionValidated: false)
        let validated = sleepNight(efficiency: 0.91, motionValidated: true)

        func historicalMetric(_ night: SleepHistorySnapshot.Night) throws -> SavedDailyMetric {
            try XCTUnwrap(SessionStore.makeSavedDailyMetrics(
                rollups: [rollup(day: day)],
                sleep: SleepHistorySnapshot(nights: [night],
                                            confirmedCount: 1,
                                            candidateCount: 0),
                baseline: PersonalBaseline(),
                calendar: calendar
            ).first)
        }

        XCTAssertEqual(try historicalMetric(hrOnlyWithRawCoverage).recoveryPercent,
                       try historicalMetric(hrOnlyWithoutEfficiency).recoveryPercent,
                       "capture/span coverage must not silently boost Recovery")

        let hrOnlyMorning = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [],
            sessions: [],
            sleep: SleepHistorySnapshot(nights: [hrOnlyWithRawCoverage],
                                        confirmedCount: 1,
                                        candidateCount: 0),
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: end.addingTimeInterval(60),
            calendar: calendar
        ))
        XCTAssertNil(hrOnlyMorning.recoverySummary?.inputSnapshot?.sleepEfficiency)

        let validatedMorning = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [],
            sessions: [],
            sleep: SleepHistorySnapshot(nights: [validated],
                                        confirmedCount: 1,
                                        candidateCount: 0),
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: end.addingTimeInterval(60),
            calendar: calendar
        ))
        XCTAssertEqual(try XCTUnwrap(validatedMorning.recoverySummary?.inputSnapshot?.sleepEfficiency),
                       0.91,
                       accuracy: 0.000_001)
    }

    func testMorningSleepNeedUsesExactNightReceiptAndLeavesLegacyTargetUnknown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027,
                                                                   month: 1,
                                                                   day: 16)))
        let start = day.addingTimeInterval(-8 * 3_600)
        let end = day
        let components = AtriaSleepBudget.sleepNeedComponents(
            baseHours: 8,
            yesterdayStrain: 12,
            debtHours: 1,
            sameDayNapHours: 0
        )
        let receipt = AtriaSleepBudget.FrozenNeed(components)

        func sleepNight(frozenNeed: AtriaSleepBudget.FrozenNeed?,
                        legacyNeed: TimeInterval?) -> SleepHistorySnapshot.Night {
            SleepHistorySnapshot.Night(
                id: frozenNeed == nil ? "legacy-need" : "receipt-need",
                day: day,
                start: start,
                end: end,
                duration: 8 * 3_600,
                restingHR: 52,
                hrv: nil,
                respiratoryRate: nil,
                sleepEfficiency: nil,
                confidence: "user_confirmed_hr_only",
                source: "aggregate_sleep",
                confirmed: true,
                stageSegments: [],
                eventTimeZoneIdentifier: "UTC",
                motionValidated: false,
                sleepNeedSeconds: legacyNeed,
                frozenSleepNeed: frozenNeed
            )
        }

        func morningMetric(_ night: SleepHistorySnapshot.Night) throws -> SavedDailyMetric {
            try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
                for: day,
                computed: [],
                sessions: [],
                sleep: SleepHistorySnapshot(nights: [night],
                                            confirmedCount: 1,
                                            candidateCount: 0),
                baseline: PersonalBaseline(),
                maxHR: 190,
                now: end.addingTimeInterval(60),
                calendar: calendar
            ))
        }

        XCTAssertEqual(try XCTUnwrap(morningMetric(sleepNight(frozenNeed: receipt,
                                                              legacyNeed: nil)).sleepNeedSeconds),
                       receipt.seconds,
                       accuracy: 0.000_001)
        XCTAssertNil(try morningMetric(sleepNight(frozenNeed: nil,
                                                  legacyNeed: receipt.seconds)).sleepNeedSeconds,
                     "a legacy seconds-only row has no replayable target receipt")
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

    func testMergeDailyMetricHistoryKeepsFirstComputedMetricForDuplicateCivilDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 14)))
        let first = SavedDailyMetric(
            day: day,
            recoveryPercent: 72,
            recoveryConfidence: "personal",
            hrv: 56,
            restingHR: 51,
            respiratoryRate: 13.8,
            sleepDuration: 7 * 3_600,
            sleepSpan: 7.5 * 3_600,
            sleepStart: day.addingTimeInterval(-7.5 * 3_600),
            sleepEnd: day,
            sleepSource: "auto_sleep",
            sleepStageSegments: [],
            sleepConsistencyPercent: 84,
            strain: 5.6
        )
        let duplicateTimestamp = SavedDailyMetric(
            day: day.addingTimeInterval(12 * 3_600),
            recoveryPercent: 38,
            recoveryConfidence: "learning",
            hrv: 31,
            restingHR: 68,
            respiratoryRate: 16.2,
            sleepDuration: 4 * 3_600,
            sleepSpan: 4.5 * 3_600,
            sleepStart: day.addingTimeInterval(4 * 3_600),
            sleepEnd: day.addingTimeInterval(8.5 * 3_600),
            sleepSource: "incremental_overlap",
            sleepStageSegments: [],
            sleepConsistencyPercent: 46,
            strain: 11.8
        )

        let merged = SessionStore.mergeDailyMetricHistory(
            existing: [],
            computed: [first, duplicateTimestamp],
            sessions: [],
            sleep: SleepHistorySnapshot(rollups: [], confirmedSleeps: []),
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: day.addingTimeInterval(2 * 86_400),
            calendar: calendar
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.day, day)
        XCTAssertEqual(merged.first?.recoveryPercent, 72)
        XCTAssertEqual(merged.first?.strain, 5.6)
    }

    func testBoundedRRWindowEndsPreferRecentSignalAndRespectLimit() {
        XCTAssertEqual(
            SessionStore.rrReferenceWindowEndSeconds(
                first: 0,
                last: 3_600,
                scanStep: 15,
                maximumWindows: 3
            ),
            [3_570, 3_585, 3_600]
        )
        XCTAssertEqual(
            SessionStore.rrReferenceWindowEndSeconds(first: 0,
                                                       last: 330,
                                                       scanStep: 15),
            [300, 315, 330]
        )
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

    func testInitialWearFallbackUsesOnePersistedLimitedRecoveryAcrossSurfaces() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2032, month: 1, day: 2
        )))
        let cycle = AtriaPhysiologicalCycle(
            start: day.addingTimeInterval(6 * 3_600),
            boundaryKind: .initialFallback,
            anchorSleepID: nil,
            expectedInterval: 24 * 3_600
        )
        let persisted = Metrics.RecoveryEstimate(
            percent: 46,
            confidence: .unverified,
            usesHRV: false,
            detail: "Limited confidence · sleep and HRV unavailable · conservative RHR-only estimate",
            contributors: [
                .init(kind: .hrv,
                      zScore: 0,
                      weight: 0,
                      detail: "HRV unavailable; excluded",
                      displayValue: "HRV unavailable"),
                .init(kind: .restingHeartRate,
                      zScore: -1.45,
                      weight: 0.2,
                      detail: "RHR -1.5σ",
                      displayValue: "Resting HR 73 bpm"),
                .init(kind: .sleep,
                      zScore: 0,
                      weight: 0,
                      detail: "Sleep unavailable; excluded",
                      displayValue: "Sleep unavailable"),
            ]
        )
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: persisted,
                                                         scoredDay: day))
        let rollup = DailyRollupStoreEntry(day: day,
                                           recoverySummary: frozen,
                                           calendar: calendar)
        let metric = SavedDailyMetric(
            day: day,
            recoveryPercent: 46,
            recoveryConfidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            hrv: nil,
            restingHR: 73,
            respiratoryRate: nil,
            sleepDuration: nil,
            sleepSpan: nil,
            sleepStart: nil,
            sleepEnd: nil,
            sleepSource: nil,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: 7.1,
            recoverySummary: frozen
        )
        let liveRecompute = Metrics.RecoveryEstimate(
            percent: 56,
            confidence: .unverified,
            usesHRV: false,
            detail: "later live RHR recompute",
            contributors: persisted.contributors
        )

        let summary = try XCTUnwrap(DailyRecoveryResolver.summary(
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            calendar: calendar
        ))
        let canonical = DailyRecoveryResolver.currentEstimate(
            liveEstimate: liveRecompute,
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            calendar: calendar
        )
        let presented = SessionStore.presentationRecoveryEstimate(
            authoritative: canonical,
            hasConfirmedMainSleep: false,
            hasFrozenRecovery: true,
            pendingSleepReview: nil,
            baseline: PersonalBaseline(),
            respiratoryBaseline: nil,
            now: cycle.start.addingTimeInterval(60),
            physiologicalCycle: cycle,
            calendar: calendar
        )

        XCTAssertEqual(summary.score, 46)
        XCTAssertEqual(canonical.percent, 46)
        XCTAssertEqual(presented.percent, 46)
        XCTAssertEqual(canonical.detail, persisted.detail)
    }

    func testInitialWearFallbackRejectsAnySleepOrHRVAuthority() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2032, month: 1, day: 2
        )))
        let cycle = AtriaPhysiologicalCycle(
            start: day.addingTimeInterval(6 * 3_600),
            boundaryKind: .initialFallback,
            anchorSleepID: nil,
            expectedInterval: 24 * 3_600
        )
        let sleepEstimate = recoveryEstimate(percent: 79)
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: sleepEstimate,
                                                         scoredDay: day))
        let rollup = DailyRollupStoreEntry(day: day,
                                           recoverySummary: frozen,
                                           calendar: calendar)
        let metric = SavedDailyMetric(
            day: day,
            recoveryPercent: 79,
            recoveryConfidence: sleepEstimate.confidence.rawValue,
            hrv: 62,
            restingHR: 51,
            respiratoryRate: 14.2,
            sleepDuration: 7 * 3_600,
            sleepSpan: 8 * 3_600,
            sleepStart: day,
            sleepEnd: day.addingTimeInterval(8 * 3_600),
            sleepSource: "sleep_window",
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: nil,
            recoverySummary: frozen
        )

        XCTAssertNil(DailyRecoveryResolver.summary(
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            calendar: calendar
        ))
    }

    func testNoSleepRolloverUsesPersistedLimitedRecoveryInsteadOfLiveDrift() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2032, month: 1, day: 2
        )))
        let cycle = AtriaPhysiologicalCycle(
            start: day.addingTimeInterval(15 * 3_600),
            boundaryKind: .noSleepFallback,
            anchorSleepID: "last-confirmed-main-sleep",
            expectedInterval: 24 * 3_600
        )
        let persisted = Metrics.RecoveryEstimate(
            percent: 46,
            confidence: .unverified,
            usesHRV: false,
            detail: "Limited confidence · sleep and HRV unavailable · conservative RHR-only estimate",
            contributors: [
                .init(kind: .hrv,
                      zScore: 0,
                      weight: 0,
                      detail: "HRV unavailable; excluded"),
                .init(kind: .restingHeartRate,
                      zScore: -1.45,
                      weight: 0.2,
                      detail: "RHR -1.5σ"),
                .init(kind: .sleep,
                      zScore: 0,
                      weight: 0,
                      detail: "Sleep unavailable; excluded"),
            ]
        )
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: persisted,
                                                         scoredDay: day))
        let rollup = DailyRollupStoreEntry(day: day,
                                           recoverySummary: frozen,
                                           calendar: calendar)
        let metric = SavedDailyMetric(
            day: day,
            recoveryPercent: 46,
            recoveryConfidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            hrv: nil,
            restingHR: 73,
            respiratoryRate: nil,
            sleepDuration: nil,
            sleepSpan: nil,
            sleepStart: nil,
            sleepEnd: nil,
            sleepSource: nil,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: 7.4,
            recoverySummary: frozen
        )
        let live = Metrics.RecoveryEstimate(
            percent: 38,
            confidence: .unverified,
            usesHRV: false,
            detail: "later live RHR recompute",
            contributors: persisted.contributors
        )

        XCTAssertEqual(DailyRecoveryResolver.currentEstimate(
            liveEstimate: live,
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            calendar: calendar
        ).percent, 46)

        let drifted = SavedDailyMetric(
            day: day,
            recoveryPercent: 38,
            recoveryConfidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            hrv: nil,
            restingHR: 82,
            respiratoryRate: nil,
            sleepDuration: nil,
            sleepSpan: nil,
            sleepStart: nil,
            sleepEnd: nil,
            sleepSource: nil,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: 8.2,
            recoverySummary: FrozenRecoverySummary(estimate: live, scoredDay: day)
        )
        let merged = SessionStore.mergeDailyMetricHistory(
            existing: [metric],
            computed: [drifted],
            sessions: [],
            sleep: .empty,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: day.addingTimeInterval(19 * 3_600),
            calendar: calendar
        )
        let preserved = try XCTUnwrap(merged.first)
        XCTAssertEqual(preserved.recoveryPercent, 46)
        XCTAssertEqual(preserved.restingHR, 73)
        XCTAssertEqual(preserved.strain, 8.2,
                       "only cumulative strain may advance during the same fallback day")
    }

    func testNoSleepAfternoonBoundaryAcceptsPersistedMidnightScoreInsideSameCycle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let cycleDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2032, month: 1, day: 2
        )))
        let cycle = AtriaPhysiologicalCycle(
            start: cycleDay.addingTimeInterval(15 * 3_600),
            boundaryKind: .noSleepFallback,
            anchorSleepID: "last-confirmed-main-sleep",
            expectedInterval: 24 * 3_600
        )
        let metricDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: cycleDay))
        let persisted = Metrics.RecoveryEstimate(
            percent: 58,
            confidence: .unverified,
            usesHRV: false,
            detail: "Limited confidence · sleep and HRV unavailable · conservative RHR-only estimate",
            contributors: [
                .init(kind: .hrv, zScore: 0, weight: 0, detail: "HRV unavailable; excluded"),
                .init(kind: .restingHeartRate, zScore: 0, weight: 0.2, detail: "RHR 0.0σ"),
                .init(kind: .sleep, zScore: 0, weight: 0, detail: "Sleep unavailable; excluded"),
            ]
        )
        let frozen = try XCTUnwrap(FrozenRecoverySummary(estimate: persisted,
                                                         scoredDay: metricDay))
        let rollup = DailyRollupStoreEntry(day: metricDay,
                                           recoverySummary: frozen,
                                           calendar: calendar)
        let metric = SavedDailyMetric(
            day: metricDay,
            recoveryPercent: 58,
            recoveryConfidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            hrv: nil,
            restingHR: 62,
            respiratoryRate: nil,
            sleepDuration: nil,
            sleepSpan: nil,
            sleepStart: nil,
            sleepEnd: nil,
            sleepSource: nil,
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: 2.2,
            recoverySummary: frozen
        )
        let laterLive = Metrics.RecoveryEstimate(
            percent: 71,
            confidence: .unverified,
            usesHRV: false,
            detail: "later live RHR recompute",
            contributors: persisted.contributors
        )

        XCTAssertEqual(DailyRecoveryResolver.currentEstimate(
            liveEstimate: laterLive,
            rollups: [rollup],
            metrics: [metric],
            physiologicalCycle: cycle,
            calendar: calendar
        ).percent, 58)
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

    func testMetricDetailPeriodsAreCalendarAlignedAndNavigable() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 10,
            hour: 12
        )))

        let day = AtriaTrendRange.day.periodInterval(
            containing: anchor,
            calendar: calendar
        )
        XCTAssertEqual(
            calendar.dateComponents([.day], from: day.start, to: day.end).day,
            1,
            "calendar arithmetic must survive DST instead of assuming 86,400 seconds"
        )

        let month = AtriaTrendRange.month.periodInterval(
            containing: anchor,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: month.start), 1)
        XCTAssertEqual(calendar.component(.month, from: month.start), 3)
        XCTAssertEqual(calendar.component(.month, from: month.end), 4)

        let previous = AtriaTrendRange.month.adjacentPeriodAnchor(
            from: anchor,
            offset: -1,
            calendar: calendar
        )
        let previousMonth = AtriaTrendRange.month.periodInterval(
            containing: previous,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.month, from: previousMonth.start), 2)
        XCTAssertEqual(previousMonth.end, month.start)
    }
}
