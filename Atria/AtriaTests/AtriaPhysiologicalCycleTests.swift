import XCTest
@testable import Atria

final class AtriaPhysiologicalCycleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2032, month: 1, day: day, hour: hour))!
    }

    private func sleep(id: String,
                       start: Date,
                       end: Date,
                       source: String = "manual_sleep",
                       hrv: Int? = 60,
                       eventTimeZoneIdentifier: String = "UTC",
                       createdAt: Date? = nil,
                       confidence: String = "user") -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: createdAt ?? end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: confidence,
                           sessions: 1,
                           samples: 100,
                           avgHR: 52,
                           peakHR: 60,
                           restingHR: 48,
                           hrv: hrv,
                           hrvWindowCount: hrv == nil ? 0 : 4,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: true,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: eventTimeZoneIdentifier)
    }

    func testMainSleepWakeStartsCurrentCycle() {
        let main = sleep(id: "main", start: date(1, 23), end: date(2, 7))
        let cycle = AtriaPhysiologicalCycle.current(now: date(2, 18),
                                                   confirmedSleeps: [main],
                                                   calendar: calendar)

        XCTAssertEqual(cycle.start, main.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(cycle.anchorSleepID, main.id)
    }

    func testPhysiologicalDayKeepsPostMidnightAwakeActivityOnPriorWakeDay() {
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        let now = date(2, 2)
        let day = AtriaPhysiologicalDay.current(now: now,
                                               confirmedSleeps: [main],
                                               calendar: calendar)

        XCTAssertEqual(day.start, main.end)
        XCTAssertEqual(day.displayDay, calendar.startOfDay(for: main.end))
        XCTAssertTrue(day.overlaps(start: date(2, 1), end: now))
    }

    func testPhysiologicalDayDoesNotResetWhileMainSleepIsUnconfirmed() {
        let prior = sleep(id: "prior", start: date(1, 0), end: date(1, 7))
        let now = date(2, 6)
        // The current in-progress night is deliberately absent from confirmed
        // sleeps: merely detecting or entering sleep cannot move Today.
        let day = AtriaPhysiologicalDay.current(now: now,
                                               confirmedSleeps: [prior],
                                               calendar: calendar)

        XCTAssertEqual(day.start, prior.end)
        XCTAssertEqual(day.boundaryKind, .mainSleep)
    }

    func testPhysiologicalDayMovesAtConfirmedMainSleepWake() {
        let prior = sleep(id: "prior", start: date(1, 0), end: date(1, 7))
        let current = sleep(id: "current", start: date(1, 23), end: date(2, 7))
        let day = AtriaPhysiologicalDay.current(now: date(2, 8),
                                               confirmedSleeps: [prior, current],
                                               calendar: calendar)

        XCTAssertEqual(day.start, current.end)
        XCTAssertEqual(day.displayDay, calendar.startOfDay(for: current.end))
        XCTAssertFalse(day.overlaps(start: date(2, 1), end: date(2, 2)))
    }

    func testPostMidnightActivityRemainsInPriorWakeCycleUntilCompletedSleep() {
        let prior = sleep(id: "prior", start: date(1, 23), end: date(2, 7))
        let beforeNextSleep = date(3, 2)
        let cycle = AtriaPhysiologicalCycle.current(now: beforeNextSleep,
                                                     confirmedSleeps: [prior],
                                                     calendar: calendar)
        let postMidnightWalk = SavedSession(
            id: UUID(),
            start: date(3, 1),
            end: date(3, 2),
            label: "Post-midnight walk",
            points: stride(from: 0.0, through: 3_600.0, by: 10).map {
                SavedSession.Point(t: $0, bpm: 120)
            },
            strapStepResearchCount: 80
        )

        let beforeSleep = SessionStore.homeSavedAggregate(
            from: [postMidnightWalk],
            rest: 50,
            maxHR: 190,
            biologicalSex: .unspecified,
            calendar: calendar,
            now: beforeNextSleep,
            cycleStart: cycle.start
        )
        XCTAssertEqual(cycle.start, prior.end)
        XCTAssertEqual(beforeSleep.savedTodayStrapSteps, 80)
        XCTAssertGreaterThan(beforeSleep.savedTodayTRIMP, 0)

        let completed = sleep(id: "completed", start: date(3, 2), end: date(3, 7))
        let afterWake = AtriaPhysiologicalCycle.current(now: date(3, 8),
                                                         confirmedSleeps: [prior, completed],
                                                         calendar: calendar)
        let afterSleep = SessionStore.homeSavedAggregate(
            from: [postMidnightWalk],
            rest: 50,
            maxHR: 190,
            biologicalSex: .unspecified,
            calendar: calendar,
            now: date(3, 8),
            cycleStart: afterWake.start
        )
        XCTAssertEqual(afterWake.start, completed.end)
        XCTAssertEqual(afterSleep.savedTodayStrapSteps, 0)
        XCTAssertEqual(afterSleep.savedTodayTRIMP, 0)
    }

    func testPhysiologicalDayNapNeverResetsBoundary() {
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        let nap = sleep(id: "nap", start: date(1, 15), end: date(1, 16), source: "manual_nap")
        let day = AtriaPhysiologicalDay.current(now: date(2, 2),
                                               confirmedSleeps: [main, nap],
                                               calendar: calendar)

        XCTAssertEqual(day.start, main.end)
    }

    func testPhysiologicalDayUsesBoundedNoSleepFallback() {
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        let day = AtriaPhysiologicalDay.current(now: date(2, 9),
                                               confirmedSleeps: [main],
                                               calendar: calendar)

        XCTAssertEqual(day.start, date(2, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(day.boundaryKind, .noSleepFallback)
    }

    // MARK: - All-nighters that run past one day
    //
    // A single missed night was covered above. The `while` loop in
    // `latestCompletedNoSleepFallback` that walks the boundary forward one
    // civil day at a time was not, so a genuine 48- or 72-hour stretch awake
    // rested on untested code. The rule these pin: with no sleep to rotate on,
    // a new physiological day still starts every 24 hours from when the last
    // one started — never a single open-ended day that grows without bound.

    func testTwoNightsWithoutSleepRollTheBoundaryTwice() {
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        let day = AtriaPhysiologicalDay.current(now: date(3, 9),
                                                confirmedSleeps: [main],
                                                calendar: calendar)
        XCTAssertEqual(day.start, date(3, 7).addingTimeInterval(30 * 60),
                       "the boundary must advance to the SECOND rollover")
        XCTAssertEqual(day.boundaryKind, .noSleepFallback)
    }

    func testThreeNightsWithoutSleepKeepTheDayBoundedAtTwentyFourHours() {
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        let day = AtriaPhysiologicalDay.current(now: date(4, 20),
                                                confirmedSleeps: [main],
                                                calendar: calendar)
        XCTAssertEqual(day.start, date(4, 7).addingTimeInterval(30 * 60))
        // The day the user is standing in is never longer than one rollover.
        XCTAssertLessThanOrEqual(date(4, 20).timeIntervalSince(day.start),
                                 24 * 60 * 60,
                                 "an all-nighter must not produce an unbounded day")
    }

    func testTheRolloverDoesNotFireBeforeItsGrace() {
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        // One minute before wake + 24h + 30m: still the original wake's day.
        let justBefore = date(2, 7).addingTimeInterval(29 * 60)
        let day = AtriaPhysiologicalDay.current(now: justBefore,
                                                confirmedSleeps: [main],
                                                calendar: calendar)
        XCTAssertEqual(day.start, date(1, 7))
        XCTAssertEqual(day.boundaryKind, .mainSleep,
                       "the grace exists so the rollover cannot race sleep settlement")
    }

    func testSleepingAgainEndsTheAllNighterRunAtTheRealWake() {
        // The point of the fallback is to keep days bounded while no sleep is
        // recorded — not to keep owning the day once one is.
        let main = sleep(id: "main", start: date(1, 0), end: date(1, 7))
        let afterTheAllNighter = sleep(id: "recovery-sleep",
                                       start: date(3, 2),
                                       end: date(3, 11))
        let day = AtriaPhysiologicalDay.current(now: date(3, 13),
                                                confirmedSleeps: [main, afterTheAllNighter],
                                                calendar: calendar)
        XCTAssertEqual(day.start, date(3, 11),
                       "a real wake takes the boundary back from the fallback")
        XCTAssertEqual(day.boundaryKind, .mainSleep)
    }

    func testUnambiguousHROnlyAutomaticSleepStartsMainSleepCycle() {
        let automatic = sleep(id: "hr-only-main",
                              start: date(1, 23),
                              end: date(2, 7),
                              source: "auto_confirmed_sleep_hr_only")
        let cycle = AtriaPhysiologicalCycle.current(now: date(2, 18),
                                                   confirmedSleeps: [automatic],
                                                   calendar: calendar)

        XCTAssertEqual(cycle.start, automatic.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(cycle.anchorSleepID, automatic.id)
    }

    func testNapDoesNotSplitMainSleepCycle() {
        let main = sleep(id: "main", start: date(1, 23), end: date(2, 7))
        let nap = sleep(id: "nap", start: date(2, 14), end: date(2, 15), source: "manual_nap")
        let cycle = AtriaPhysiologicalCycle.current(now: date(2, 18),
                                                   confirmedSleeps: [main, nap],
                                                   calendar: calendar)

        XCTAssertEqual(cycle.start, main.end)
        XCTAssertEqual(cycle.anchorSleepID, main.id)
    }

    func testExplicitShiftWorkerSleepStartsCycleRegardlessOfClockHour() {
        let shiftSleep = sleep(id: "shift", start: date(2, 8), end: date(2, 15), source: "manual_sleep")
        let cycle = AtriaPhysiologicalCycle.current(now: date(2, 20),
                                                   confirmedSleeps: [shiftSleep],
                                                   calendar: calendar)

        XCTAssertEqual(cycle.start, shiftSleep.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
    }

    func testShiftWorkerRecoveryCanSettleAtTwoAMFromConfirmedWake() throws {
        let day = calendar.startOfDay(for: date(3, 2))
        let shiftSleep = sleep(id: "shift-2am",
                               start: date(2, 18),
                               end: date(3, 2),
                               source: "manual_sleep")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [shiftSleep],
                                            calendar: calendar)

        let metric = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [],
            sessions: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: date(3, 2),
            calendar: calendar
        ))

        XCTAssertEqual(metric.sleepEnd, shiftSleep.end)
        XCTAssertEqual(metric.hrv, shiftSleep.hrv)
        XCTAssertEqual(metric.sleepDuration, shiftSleep.duration)
    }

    func testConfirmedSleepWithoutHRVDoesNotBorrowWholeSessionOrDayHRV() throws {
        let day = calendar.startOfDay(for: date(3, 7))
        let mainSleep = sleep(id: "sleep-without-qualified-hrv",
                              start: date(2, 23),
                              end: date(3, 7),
                              hrv: nil)
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [mainSleep],
                                            calendar: calendar)
        let overlapping = SavedSession(id: UUID(),
                                       start: date(2, 20),
                                       end: date(3, 9),
                                       label: "Long wear with out-of-window HRV",
                                       points: stride(from: 0.0, through: 13 * 3_600.0, by: 10).map {
                                           SavedSession.Point(t: $0, bpm: 52)
                                       },
                                       hrv: 91)
        let computed = SavedDailyMetric(day: day,
                                        recoveryPercent: 80,
                                        recoveryConfidence: "test",
                                        hrv: 87,
                                        restingHR: 50,
                                        respiratoryRate: 14,
                                        sleepDuration: nil,
                                        sleepSpan: nil,
                                        sleepStart: nil,
                                        sleepEnd: nil,
                                        sleepSource: nil,
                                        sleepStageSegments: [],
                                        sleepConsistencyPercent: nil,
                                        strain: 3)

        let metric = try XCTUnwrap(SessionStore.makeMorningFrozenDailyMetric(
            for: day,
            computed: [computed],
            sessions: [overlapping],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: date(3, 9),
            calendar: calendar
        ))

        XCTAssertNil(metric.hrv)
        XCTAssertEqual(metric.sleepEnd, mainSleep.end)
        XCTAssertEqual(metric.sleepDuration, mainSleep.duration)
    }

    func testCivilMidnightDoesNotMintAnotherRecoveryBeforeNextConfirmedSleep() {
        let previous = sleep(id: "previous", start: date(1, 23), end: date(2, 7))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [previous],
                                            calendar: calendar)
        let currentCivilDay = calendar.startOfDay(for: date(3, 5))
        let wear = SavedSession(id: UUID(),
                                start: date(2, 22),
                                end: date(3, 5),
                                label: "Overnight wear",
                                points: stride(from: 0.0, through: 7 * 3_600.0, by: 60).map {
                                    SavedSession.Point(t: $0, bpm: 52)
                                })

        let metric = SessionStore.makeMorningFrozenDailyMetric(for: currentCivilDay,
                                                                computed: [],
                                                                sessions: [wear],
                                                                sleep: snapshot,
                                                                baseline: PersonalBaseline(),
                                                                maxHR: 190,
                                                                now: date(3, 5),
                                                                calendar: calendar)

        // Civil midnight may retain an honest wear/activity row, but cannot
        // mint a second sleep/recovery cycle before another confirmed wake.
        XCTAssertEqual(metric?.restingHR, 52)
        XCTAssertNil(metric?.hrv)
        XCTAssertNil(metric?.sleepDuration)
        XCTAssertNil(metric?.sleepEnd)
        XCTAssertNil(metric?.recoveryPercent)
    }

    func testSplitResumedConfirmedSleepKeepsLatestWakeAsSingleCycleBoundary() {
        let first = sleep(id: "first-fragment", start: date(1, 23), end: date(2, 3))
        let resumed = sleep(id: "resumed-fragment", start: date(2, 4), end: date(2, 8))
        let cycle = AtriaPhysiologicalCycle.current(now: date(2, 12),
                                                   confirmedSleeps: [first, resumed],
                                                   calendar: calendar)

        XCTAssertEqual(cycle.start, resumed.end)
        XCTAssertEqual(cycle.anchorSleepID, resumed.id)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
    }

    func testLinkedResumedSleepUsesFinalWakeButKeepsOriginalMainAnchor() {
        let main = sleep(id: "main-fragment",
                         start: date(1, 23),
                         end: date(2, 3))
        let resumed = sleep(id: "resumed-fragment",
                            start: date(2, 3).addingTimeInterval(30 * 60),
                            end: date(2, 7),
                            source: "resumed_sleep")

        let cycle = AtriaPhysiologicalCycle.current(now: date(2, 12),
                                                    confirmedSleeps: [main, resumed],
                                                    calendar: calendar)
        let latest = AtriaPhysiologicalCycle.latestCompletedMainSleep(
            now: date(2, 12),
            confirmedSleeps: [main, resumed]
        )

        XCTAssertEqual(cycle.start, resumed.end)
        XCTAssertEqual(cycle.anchorSleepID, main.id)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(latest?.id, main.id)
        XCTAssertEqual(latest?.start, main.start)
        XCTAssertEqual(latest?.end, resumed.end)
        XCTAssertEqual(latest?.duration, main.duration + resumed.duration)
    }

    func testRespiratoryBaselineExcludesCurrentConfirmedMainSleepAndNaps() throws {
        func night(id: String,
                   day: Int,
                   rate: Double,
                   source: String = "manual_sleep") -> SleepHistorySnapshot.Night {
            SleepHistorySnapshot.Night(id: id,
                                       day: date(day, 0),
                                       start: date(day - 1, 23),
                                       end: date(day, 7),
                                       duration: source == "manual_nap" ? 60 * 60 : 8 * 60 * 60,
                                       restingHR: 50,
                                       hrv: 60,
                                       respiratoryRate: rate,
                                       sleepEfficiency: 0.9,
                                       confidence: "user",
                                       source: source,
                                       confirmed: true,
                                       stageSegments: [],
                                       eventTimeZoneIdentifier: "UTC")
        }
        let current = night(id: "current", day: 5, rate: 30)
        let nap = night(id: "nap", day: 4, rate: 40, source: "manual_nap")
        let prior = (0..<PersonalBaseline.trustedMinimumSamples).map {
            night(id: "prior-\($0)", day: 4 - $0, rate: 15)
        }
        let snapshot = SleepHistorySnapshot(nights: [current, nap] + prior,
                                            confirmedCount: prior.count + 2,
                                            candidateCount: 0)

        let baseline = try XCTUnwrap(snapshot.respiratoryBaselineStats)
        XCTAssertEqual(baseline.count, PersonalBaseline.trustedMinimumSamples)
        XCTAssertEqual(baseline.mean, 15, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.respiratoryBaselineCount, PersonalBaseline.trustedMinimumSamples)
        XCTAssertEqual(snapshot.respiratoryBaselineMean ?? 0, 15, accuracy: 0.000_001)
    }

    func testRespiratoryCandidateDoesNotEvictLatestPriorConfirmedBaselineNight() throws {
        func night(id: String,
                   day: Int,
                   rate: Double,
                   confirmed: Bool) -> SleepHistorySnapshot.Night {
            SleepHistorySnapshot.Night(id: id,
                                       day: date(day, 0),
                                       start: date(day - 1, 23),
                                       end: date(day, 7),
                                       duration: 8 * 60 * 60,
                                       restingHR: 50,
                                       hrv: 60,
                                       respiratoryRate: rate,
                                       sleepEfficiency: 0.9,
                                       confidence: confirmed ? "user" : "candidate",
                                       source: confirmed ? "manual_sleep" : "sleep_candidate",
                                       confirmed: confirmed,
                                       stageSegments: [],
                                       eventTimeZoneIdentifier: "UTC")
        }
        let prior = (0..<PersonalBaseline.trustedMinimumSamples).map {
            night(id: "prior-\($0)", day: 4 - $0, rate: 15, confirmed: true)
        }
        let snapshot = SleepHistorySnapshot(
            nights: [night(id: "candidate", day: 5, rate: 30, confirmed: false)] + prior,
            confirmedCount: prior.count,
            candidateCount: 1
        )

        let baseline = try XCTUnwrap(snapshot.respiratoryBaselineStats)
        XCTAssertEqual(baseline.count, PersonalBaseline.trustedMinimumSamples)
        XCTAssertEqual(baseline.mean, 15, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.respiratoryBaselineCount, PersonalBaseline.trustedMinimumSamples)
    }

    func testHistoricalStrainCacheBeginsAtWakeNotCivilMidnight() {
        let shiftSleep = sleep(id: "shift",
                               start: date(2, 12),
                               end: date(2, 19),
                               source: "manual_sleep")
        let now = date(3, 2)
        let interval = SessionStore.historicalStrainCacheInterval(now: now,
                                                                   confirmedSleeps: [shiftSleep],
                                                                   calendar: calendar)

        XCTAssertEqual(interval.start, shiftSleep.end)
        XCTAssertEqual(interval.end, now)
        XCTAssertLessThan(interval.start, calendar.startOfDay(for: now))
    }

    func testDeletingAnchorSleepRevertsToPreviousPhysiologicalBoundary() {
        let previous = sleep(id: "previous", start: date(1, 23), end: date(2, 7))
        let deleted = sleep(id: "deleted", start: date(2, 23), end: date(3, 7))

        let beforeDelete = AtriaPhysiologicalCycle.current(now: date(3, 12),
                                                          confirmedSleeps: [previous, deleted],
                                                          calendar: calendar)
        let afterDelete = AtriaPhysiologicalCycle.current(now: date(3, 12),
                                                         confirmedSleeps: [previous],
                                                         calendar: calendar)

        XCTAssertEqual(beforeDelete.anchorSleepID, deleted.id)
        XCTAssertEqual(afterDelete.start, date(3, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(afterDelete.boundaryKind, .noSleepFallback)
    }

    func testEditingAnchorSleepMovesBoundaryToEditedWake() {
        let original = sleep(id: "original", start: date(2, 23), end: date(3, 7))
        let edited = sleep(id: "edited", start: date(2, 23), end: date(3, 9), source: "user_adjusted_sleep")

        XCTAssertEqual(AtriaPhysiologicalCycle.current(now: date(3, 12),
                                                       confirmedSleeps: [original],
                                                       calendar: calendar).start,
                       date(3, 7))
        XCTAssertEqual(AtriaPhysiologicalCycle.current(now: date(3, 12),
                                                       confirmedSleeps: [edited],
                                                       calendar: calendar).start,
                       date(3, 9))
    }

    func testAllNighterCreatesDeterministicNoSleepBoundary() {
        let main = sleep(id: "main", start: date(1, 23), end: date(2, 7))
        let cycle = AtriaPhysiologicalCycle.current(now: date(3, 10),
                                                   confirmedSleeps: [main],
                                                   calendar: calendar)

        XCTAssertEqual(cycle.start, date(3, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(cycle.boundaryKind, .noSleepFallback)
    }

    func testShortSleepRecordCannotMaskNoSleepRollover() {
        let priorMain = sleep(id: "prior-main", start: date(1, 23), end: date(2, 7))
        let shortRest = sleep(id: "short-rest",
                              start: date(3, 2),
                              end: date(3, 4),
                              source: "manual_sleep")

        let cycle = AtriaPhysiologicalCycle.current(now: date(3, 10),
                                                    confirmedSleeps: [priorMain, shortRest],
                                                    calendar: calendar)

        XCTAssertEqual(cycle.start, date(3, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(cycle.boundaryKind, .noSleepFallback)
        XCTAssertEqual(cycle.anchorSleepID, priorMain.id)
    }

    func testNoPriorMainSleepStaysInitialInsteadOfInventingAllNighterRecovery() {
        let shortRest = sleep(id: "short-rest",
                              start: date(2, 2),
                              end: date(2, 4),
                              source: "manual_sleep")

        let cycle = AtriaPhysiologicalCycle.current(now: date(3, 10),
                                                    confirmedSleeps: [shortRest],
                                                    calendar: calendar)

        XCTAssertEqual(cycle.boundaryKind, .initialFallback)
        XCTAssertNil(cycle.anchorSleepID)
    }

    func testNoSleepFallbackPreservesLocalWakeHourAcrossSpringDST() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            losAngeles.date(from: DateComponents(year: 2032,
                                                 month: 3,
                                                 day: day,
                                                 hour: hour,
                                                 minute: minute))!
        }
        // DST begins on 2032-03-14 in Los Angeles. The next local 07:00 is
        // only 23 elapsed hours after the prior wake, but it is the correct
        // bounded physiological rollover.
        let main = sleep(id: "dst-main",
                         start: local(13, 23),
                         end: local(14, 7),
                         eventTimeZoneIdentifier: "America/Los_Angeles")
        let cycle = AtriaPhysiologicalCycle.current(now: local(15, 7, 30),
                                                    confirmedSleeps: [main],
                                                    calendar: losAngeles)

        XCTAssertEqual(cycle.start, local(15, 7, 30))
        XCTAssertEqual(losAngeles.component(.hour, from: cycle.start), 7)
        XCTAssertEqual(cycle.boundaryKind, .noSleepFallback)
    }

    func testNoSleepFallbackWaitsForSleepSettlementBeforeRollover() {
        let main = sleep(id: "main", start: date(1, 23), end: date(2, 7))

        let whileOvernightSleepCanStillSettle = AtriaPhysiologicalCycle.current(
            now: date(3, 7).addingTimeInterval(29 * 60),
            confirmedSleeps: [main],
            calendar: calendar
        )
        let afterSettlement = AtriaPhysiologicalCycle.current(
            now: date(3, 7).addingTimeInterval(30 * 60),
            confirmedSleeps: [main],
            calendar: calendar
        )

        XCTAssertEqual(whileOvernightSleepCanStillSettle.start, main.end)
        XCTAssertEqual(whileOvernightSleepCanStillSettle.boundaryKind, .mainSleep)
        XCTAssertEqual(afterSettlement.start, date(3, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(afterSettlement.boundaryKind, .noSleepFallback)
    }

    func testMultipleAllNightersAdvanceOneCivilBoundaryAtATime() {
        let main = sleep(id: "main", start: date(1, 23), end: date(2, 7))
        let first = AtriaPhysiologicalCycle.current(
            now: date(3, 10),
            confirmedSleeps: [main],
            calendar: calendar
        )
        let second = AtriaPhysiologicalCycle.current(
            now: date(4, 10),
            confirmedSleeps: [main],
            calendar: calendar
        )

        XCTAssertEqual(first.start, date(3, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(second.start, date(4, 7).addingTimeInterval(30 * 60))
        XCTAssertEqual(first.boundaryKind, .noSleepFallback)
        XCTAssertEqual(second.boundaryKind, .noSleepFallback)
        XCTAssertLessThan(first.start, second.start)
    }

    func testLateConfirmedSleepCannotMoveCycleBehindSealedFallback() {
        let prior = sleep(id: "prior", start: date(1, 23), end: date(2, 7))
        let sealedFallback = date(3, 7).addingTimeInterval(30 * 60)
        let learnedLate = sleep(
            id: "learned-late",
            start: date(3, 1),
            end: date(3, 6),
            source: "auto_confirmed_sleep",
            createdAt: date(3, 10)
        )

        let cycle = AtriaPhysiologicalCycle.current(
            now: date(3, 12),
            confirmedSleeps: [prior, learnedLate],
            calendar: calendar
        )
        let anchor = AtriaPhysiologicalCycle.latestCompletedMainSleep(
            now: date(3, 12),
            confirmedSleeps: [prior, learnedLate],
            calendar: calendar
        )

        XCTAssertEqual(cycle.start, sealedFallback)
        XCTAssertEqual(cycle.boundaryKind, .noSleepFallback)
        XCTAssertEqual(cycle.anchorSleepID, prior.id)
        XCTAssertEqual(anchor?.id, prior.id)

        let crossingWorkout = SavedSession(
            id: UUID(),
            start: date(3, 6),
            end: date(3, 8),
            label: "Crossing fallback",
            points: stride(from: 0.0, through: 7_200.0, by: 10).map {
                SavedSession.Point(t: $0, bpm: 120)
            },
            strapStepResearchCount: 200
        )
        let aggregate = SessionStore.homeSavedAggregate(
            from: [crossingWorkout],
            rest: 50,
            maxHR: 190,
            biologicalSex: .unspecified,
            calendar: calendar,
            now: date(3, 12),
            cycleStart: cycle.start
        )
        XCTAssertEqual(aggregate.savedTodayStrapSteps, 50)
    }

    func testLateManualSleepSupersedesSealedFallbackAndRecomputesCycle() {
        let prior = sleep(id: "prior", start: date(1, 23), end: date(2, 7))
        let corrected = sleep(
            id: "manual-correction",
            start: date(3, 0),
            end: date(3, 6),
            source: "manual_sleep",
            createdAt: date(3, 10)
        )

        let cycle = AtriaPhysiologicalCycle.current(
            now: date(3, 12),
            confirmedSleeps: [prior, corrected],
            calendar: calendar
        )

        XCTAssertEqual(cycle.start, corrected.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(cycle.anchorSleepID, corrected.id)
    }

    func testLateUserConfirmedReviewSupersedesSealedFallback() {
        let prior = sleep(id: "prior", start: date(1, 23), end: date(2, 7))
        let confirmedReview = sleep(
            id: "confirmed-review",
            start: date(3, 0),
            end: date(3, 6),
            source: "sleep_window",
            createdAt: date(3, 10),
            confidence: "user_confirmed_hr_only"
        )

        let cycle = AtriaPhysiologicalCycle.current(
            now: date(3, 12),
            confirmedSleeps: [prior, confirmedReview],
            calendar: calendar
        )

        XCTAssertEqual(cycle.start, confirmedReview.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(cycle.anchorSleepID, confirmedReview.id)
    }

    func testCompactSleepSnapshotPreservesLateConfirmationBoundaryParity() {
        let prior = sleep(
            id: "prior",
            start: date(1, 23),
            end: date(2, 7)
        )
        let learnedLate = sleep(
            id: "learned-late",
            start: date(3, 1),
            end: date(3, 6),
            source: "auto_confirmed_sleep",
            createdAt: date(3, 10)
        )
        let now = date(3, 12)
        let expected = AtriaPhysiologicalDay.current(
            now: now,
            confirmedSleeps: [prior, learnedLate],
            calendar: calendar
        )
        let compact = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [prior, learnedLate],
            calendar: calendar
        )
        let projected = AtriaPhysiologicalDay.current(
            now: now,
            sleepHistory: compact,
            calendar: calendar
        )

        XCTAssertEqual(
            expected.start,
            date(3, 7).addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(expected.boundaryKind, .noSleepFallback)
        XCTAssertEqual(projected, expected)
    }

    func testSleepWakingAfterFallbackStartsLaterNonOverlappingCycle() {
        let prior = sleep(id: "prior", start: date(1, 23), end: date(2, 7))
        let current = sleep(
            id: "current",
            start: date(3, 5),
            end: date(3, 9),
            createdAt: date(3, 10)
        )

        let cycle = AtriaPhysiologicalCycle.current(
            now: date(3, 12),
            confirmedSleeps: [prior, current],
            calendar: calendar
        )

        XCTAssertEqual(cycle.start, current.end)
        XCTAssertEqual(cycle.boundaryKind, .mainSleep)
        XCTAssertEqual(cycle.anchorSleepID, current.id)
    }

    func testNoSleepFallbackPreservesEventZoneAfterTravel() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        func losAngelesDate(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            losAngeles.date(from: DateComponents(
                year: 2032,
                month: 1,
                day: day,
                hour: hour,
                minute: minute
            ))!
        }
        let prior = sleep(
            id: "travel-anchor",
            start: losAngelesDate(1, 23),
            end: losAngelesDate(2, 7),
            eventTimeZoneIdentifier: "America/Los_Angeles"
        )
        let expected = losAngelesDate(3, 7, 30)

        let cycle = AtriaPhysiologicalCycle.current(
            now: expected.addingTimeInterval(2 * 60 * 60),
            confirmedSleeps: [prior],
            calendar: tokyo
        )

        XCTAssertEqual(cycle.start, expected)
        XCTAssertEqual(cycle.boundaryKind, .noSleepFallback)
    }

    func testNoSleepFallbackPreservesLocalWakeAcrossFallDST() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            losAngeles.date(from: DateComponents(
                year: 2032,
                month: 11,
                day: day,
                hour: hour,
                minute: minute
            ))!
        }
        let main = sleep(
            id: "fall-dst-main",
            start: local(5, 23),
            end: local(6, 7),
            eventTimeZoneIdentifier: "America/Los_Angeles"
        )
        let cycle = AtriaPhysiologicalCycle.current(
            now: local(7, 8),
            confirmedSleeps: [main],
            calendar: losAngeles
        )

        XCTAssertEqual(cycle.start, local(7, 7, 30))
        XCTAssertEqual(cycle.boundaryKind, .noSleepFallback)
    }

    func testLateCrossMidnightSleepIsAttributedToWakeCivilDay() {
        let session = SavedSession(id: UUID(),
                                   start: date(2, 23),
                                   end: date(3, 13),
                                   label: "Late wake",
                                   points: [SavedSession.Point(t: 0, bpm: 52)],
                                   eventTimeZoneIdentifier: "UTC")

        XCTAssertEqual(SessionStore.aggregateSleepDay(for: [session],
                                                       eventTimeZoneIdentifier: "UTC",
                                                       calendar: calendar),
                       calendar.startOfDay(for: date(3, 13)))
    }

    func testSleepWakeDayUsesEventTimeZoneWhenOutputCalendarDiffers() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let start = try XCTUnwrap(tokyo.date(from: DateComponents(year: 2032,
                                                                 month: 1,
                                                                 day: 2,
                                                                 hour: 23)))
        let end = try XCTUnwrap(tokyo.date(from: DateComponents(year: 2032,
                                                               month: 1,
                                                               day: 3,
                                                               hour: 12)))
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Tokyo late wake",
                                   points: [SavedSession.Point(t: 0, bpm: 52)],
                                   eventTimeZoneIdentifier: "Asia/Tokyo")

        XCTAssertEqual(SessionStore.aggregateSleepDay(for: [session],
                                                       eventTimeZoneIdentifier: "Asia/Tokyo",
                                                       calendar: calendar),
                       date(3, 0))
    }

    func testHomeAggregateSplitsTRIMPAndStepsAtCycleBoundary() {
        let boundary = date(3, 7)
        let session = SavedSession(id: UUID(),
                                   start: date(3, 6),
                                   end: date(3, 8),
                                   label: "Boundary walk",
                                   // Keep samples inside the production continuity limit;
                                   // minute-spaced points intentionally form isolated gaps and
                                   // therefore cannot produce cardiovascular load.
                                   points: stride(from: 0.0, through: 7_200.0, by: 10.0).map {
                                       SavedSession.Point(t: $0, bpm: 120)
                                   },
                                   strapStepResearchCount: 200)
        let aggregate = SessionStore.homeSavedAggregate(from: [session],
                                                        rest: 50,
                                                        maxHR: 190,
                                                        biologicalSex: .unspecified,
                                                        calendar: calendar,
                                                        now: date(3, 8),
                                                        cycleStart: boundary)

        XCTAssertGreaterThan(aggregate.savedTodayTRIMP, 0)
        XCTAssertEqual(aggregate.savedTodayStrapSteps, 100)
    }

    func testLiveStepDeltaDoesNotLeakPriorCycleAcrossActiveCheckpoint() {
        let reconciled = AtriaHomeModel.mergedStrapStepResearchCount(
            savedToday: 100,
            savedActiveSession: 100,
            savedActiveSessionTotal: 900,
            liveActiveSession: 925
        )

        XCTAssertEqual(reconciled, 125)
    }

    @MainActor
    func testLiveTRIMPExcludesActiveSessionSamplesBeforeCycleBoundary() {
        let boundary = date(3, 7)
        let samples = stride(from: -600.0, through: 600.0, by: 10.0).map {
            HRSample(t: boundary.addingTimeInterval($0), bpm: 150)
        }
        let actual = WidgetSnapshotPublisher.incrementalLiveTRIMP(samples: samples,
                                                                   rest: 60,
                                                                   max: 190,
                                                                   cycleStart: boundary)
        let expectedSamples = samples.filter { $0.t >= boundary }
        let expected = Metrics.trimp(expectedSamples.map {
            ($0.t.timeIntervalSince(boundary), $0.bpm)
        }, rest: 60, max: 190)

        XCTAssertEqual(actual, expected, accuracy: 0.000_001)
    }
}
