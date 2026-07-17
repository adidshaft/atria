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
                       eventTimeZoneIdentifier: String = "UTC") -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: "user",
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
        XCTAssertEqual(afterDelete.start, date(3, 7))
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

        XCTAssertEqual(cycle.start, date(3, 7))
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

        XCTAssertEqual(cycle.start, date(3, 7))
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

        XCTAssertEqual(cycle.start, local(15, 7))
        XCTAssertEqual(losAngeles.component(.hour, from: cycle.start), 7)
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
