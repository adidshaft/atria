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
                       source: String = "manual_sleep") -> UserConfirmedSleep {
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
                           hrv: 60,
                           hrvWindowCount: 4,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: true,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: "UTC")
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
