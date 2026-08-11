import XCTest
@testable import Atria

final class AtriaHistoricalPhysiologicalCycleTests: XCTestCase {
    private var utc: Calendar {
        calendar(timeZoneIdentifier: "UTC")
    }

    func testConsecutiveNightsResolveWakeToWakeAndOwnOnlyWakeDaySleep() throws {
        let calendar = utc
        let first = sleep(id: "first",
                          start: date(2026, 8, 1, 23, calendar: calendar),
                          end: date(2026, 8, 2, 7, calendar: calendar))
        let second = sleep(id: "second",
                           start: date(2026, 8, 2, 23, calendar: calendar),
                           end: date(2026, 8, 3, 7, calendar: calendar))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [first, second],
                                            calendar: calendar)
        let wakeDay = date(2026, 8, 2, 0, calendar: calendar)

        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: wakeDay,
            sleepHistory: snapshot,
            calendar: calendar
        )
        let window = AtriaActivityDisplayWindow.historical(
            day: wakeDay,
            sleepHistory: snapshot,
            calendar: calendar
        )
        let rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: cycle.interval,
            calendar: calendar,
            mainSleepOwnershipDay: wakeDay
        )

        XCTAssertEqual(cycle.interval, DateInterval(start: first.end, end: second.end))
        XCTAssertEqual(cycle.startBoundary, .mainSleep(id: first.id))
        XCTAssertEqual(cycle.endBoundary, .mainSleep(id: second.id))
        XCTAssertEqual(cycle.followingRecoverySleepID, second.id)
        XCTAssertFalse(cycle.usesCivilFallback)
        XCTAssertEqual(window.interval, cycle.interval)
        XCTAssertEqual(window.historicalStartBoundary, cycle.startBoundary)
        XCTAssertEqual(Set(rows.map(\.id)), [first.id],
                       "The next night starts on this civil date but belongs only to its wake date")
    }

    func testNoSleepDateUsesDeterministicRolloverAndUnknownHistoryUsesCivilFallback() {
        let calendar = utc
        let anchor = sleep(id: "anchor",
                           start: date(2026, 8, 1, 23, calendar: calendar),
                           end: date(2026, 8, 2, 7, calendar: calendar))
        let noSleepDay = date(2026, 8, 3, 0, calendar: calendar)
        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: noSleepDay,
            confirmedSleeps: [anchor],
            calendar: calendar
        )

        XCTAssertEqual(cycle.interval.start,
                       date(2026, 8, 3, 7, 30, calendar: calendar))
        XCTAssertEqual(cycle.interval.end,
                       date(2026, 8, 4, 7, 30, calendar: calendar))
        XCTAssertEqual(cycle.startBoundary, .noSleepFallback(anchorSleepID: anchor.id))
        XCTAssertEqual(cycle.endBoundary, .noSleepFallback(anchorSleepID: anchor.id))

        let unknownDay = date(2026, 7, 30, 0, calendar: calendar)
        let unknown = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: unknownDay,
            confirmedSleeps: [anchor],
            calendar: calendar
        )
        XCTAssertEqual(unknown.interval,
                       DateInterval(start: unknownDay,
                                    end: date(2026, 7, 31, 0, calendar: calendar)))
        XCTAssertTrue(unknown.usesCivilFallback)
        XCTAssertEqual(unknown.endBoundary, .civilDayFallback)
    }

    func testNoSleepRolloverKeepsEventLocalClockAcrossDST() throws {
        let losAngeles = calendar(timeZoneIdentifier: "America/Los_Angeles")
        let anchor = sleep(id: "dst-anchor",
                           start: date(2026, 3, 6, 23, calendar: losAngeles),
                           end: date(2026, 3, 7, 7, calendar: losAngeles),
                           eventTimeZoneIdentifier: "America/Los_Angeles")
        let selectedDay = date(2026, 3, 8, 0, calendar: losAngeles)
        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: selectedDay,
            confirmedSleeps: [anchor],
            calendar: losAngeles
        )
        let components = losAngeles.dateComponents([.hour, .minute],
                                                   from: cycle.interval.start)

        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(cycle.interval.start.timeIntervalSince(anchor.end),
                       23.5 * 3_600,
                       accuracy: 1,
                       "Spring-forward arithmetic must preserve 07:30 local, not add 86,400 seconds")
    }

    func testTravelWakeIsOwnedByEventLocalDay() {
        let output = calendar(timeZoneIdentifier: "America/Los_Angeles")
        let tokyo = calendar(timeZoneIdentifier: "Asia/Tokyo")
        let wake = date(2026, 8, 3, 0, 30, calendar: tokyo)
        let traveled = sleep(id: "tokyo-wake",
                             start: wake.addingTimeInterval(-7 * 3_600),
                             end: wake,
                             eventTimeZoneIdentifier: "Asia/Tokyo")
        let eventWakeDay = date(2026, 8, 3, 0, calendar: output)

        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: eventWakeDay,
            confirmedSleeps: [traveled],
            calendar: output
        )

        XCTAssertEqual(cycle.interval.start, wake)
        XCTAssertEqual(cycle.startBoundary, .mainSleep(id: traveled.id))
        XCTAssertEqual(cycle.displayDay, eventWakeDay)
        XCTAssertNotEqual(output.startOfDay(for: wake), eventWakeDay,
                          "The assertion must exercise a real output-zone/event-zone date split")
    }

    func testResumedSleepMintsOneBoundaryButBothDurableRowsShareWakeDay() {
        let calendar = utc
        let main = sleep(id: "main",
                         start: date(2026, 8, 2, 23, calendar: calendar),
                         end: date(2026, 8, 3, 3, calendar: calendar))
        let resumed = sleep(id: "resumed",
                            start: date(2026, 8, 3, 3, 20, calendar: calendar),
                            end: date(2026, 8, 3, 7, 20, calendar: calendar),
                            source: "resumed_sleep")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [main, resumed],
                                            calendar: calendar)
        let wakeDay = date(2026, 8, 3, 0, calendar: calendar)
        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: wakeDay,
            sleepHistory: snapshot,
            calendar: calendar
        )
        let rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: cycle.interval,
            calendar: calendar,
            mainSleepOwnershipDay: wakeDay
        )

        XCTAssertEqual(cycle.interval.start, resumed.end)
        XCTAssertEqual(cycle.startBoundary, .mainSleep(id: main.id))
        XCTAssertEqual(Set(rows.map(\.id)), [main.id, resumed.id])
    }

    func testNapsAndPendingSleepRemainOverlapRecords() {
        let calendar = utc
        let first = sleep(id: "first",
                          start: date(2026, 8, 1, 23, calendar: calendar),
                          end: date(2026, 8, 2, 7, calendar: calendar))
        let nap = sleep(id: "nap",
                        start: date(2026, 8, 2, 15, calendar: calendar),
                        end: date(2026, 8, 2, 16, calendar: calendar),
                        source: "manual_nap")
        let second = sleep(id: "second",
                           start: date(2026, 8, 2, 23, calendar: calendar),
                           end: date(2026, 8, 3, 7, calendar: calendar))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [first, nap, second],
                                            calendar: calendar)
        let pending = night(id: "pending",
                            day: date(2026, 8, 2, 0, calendar: calendar),
                            start: date(2026, 8, 2, 20, calendar: calendar),
                            end: date(2026, 8, 2, 21, 30, calendar: calendar),
                            confirmed: false,
                            source: "sleep_candidate")
        let wakeDay = date(2026, 8, 2, 0, calendar: calendar)
        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: wakeDay,
            sleepHistory: snapshot,
            calendar: calendar
        )
        let rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: pending,
            interval: cycle.interval,
            calendar: calendar,
            mainSleepOwnershipDay: wakeDay
        )

        XCTAssertEqual(Set(rows.map(\.id)), [first.id, nap.id, pending.id])
        XCTAssertFalse(rows.contains { $0.id == second.id })
    }

    func testEarlyMorningWorkoutUsesSameCycleFollowingWakeRecovery() {
        let calendar = utc
        let priorWake = sleep(id: "prior",
                              start: date(2026, 8, 1, 23, calendar: calendar),
                              end: date(2026, 8, 2, 7, calendar: calendar))
        let recoverySleep = sleep(id: "recovery",
                                  start: date(2026, 8, 3, 2, 30, calendar: calendar),
                                  end: date(2026, 8, 3, 7, calendar: calendar))
        let workout = workout(id: "early",
                              start: date(2026, 8, 3, 1, calendar: calendar),
                              end: date(2026, 8, 3, 2, calendar: calendar))
        let recoveryDay = date(2026, 8, 3, 0, calendar: calendar)
        let prior = [60, 70, 80].enumerated().map { index, score in
            DailyRollupStoreEntry(
                day: calendar.date(byAdding: .day,
                                   value: -(index + 1),
                                   to: recoveryDay)!,
                recovery: score,
                calendar: calendar
            )
        }
        let observed = DailyRollupStoreEntry(day: recoveryDay,
                                             recovery: 80,
                                             calendar: calendar)
        let owningCycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: date(2026, 8, 2, 0, calendar: calendar),
            confirmedSleeps: [priorWake, recoverySleep],
            calendar: calendar
        )
        let nextCycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: recoveryDay,
            confirmedSleeps: [priorWake, recoverySleep],
            calendar: calendar
        )

        let effect = AtriaActivityRecoveryEffect.make(
            workout: workout,
            rollups: [observed] + prior,
            confirmedSleeps: [priorWake, recoverySleep],
            calendar: calendar,
            now: date(2026, 8, 3, 12, calendar: calendar)
        )

        XCTAssertEqual(effect.status,
                       .observed(delta: 10, recovery: 80, baseline: 70, samples: 3),
                       "01:00 activity belongs to the wake cycle ending at the same morning recovery, not the next civil date")
        XCTAssertEqual(AtriaActivitySelectedDayWorkouts.overlapping(
            [workout], interval: owningCycle.interval
        ).map(\.id), [workout.id])
        XCTAssertTrue(AtriaActivitySelectedDayWorkouts.overlapping(
            [workout], interval: nextCycle.interval
        ).isEmpty)
    }

    func testRecoveryAttributionFailsClosedWhenNoSleepRolloverWins() {
        let calendar = utc
        let priorWake = sleep(id: "prior",
                              start: date(2026, 8, 1, 23, calendar: calendar),
                              end: date(2026, 8, 2, 7, calendar: calendar))
        let lateSleep = sleep(id: "late",
                              start: date(2026, 8, 3, 23, calendar: calendar),
                              end: date(2026, 8, 4, 10, calendar: calendar))
        let workout = workout(id: "after-rollover",
                              start: date(2026, 8, 3, 8, calendar: calendar),
                              end: date(2026, 8, 3, 9, calendar: calendar))

        let effect = AtriaActivityRecoveryEffect.make(
            workout: workout,
            rollups: [],
            confirmedSleeps: [priorWake, lateSleep],
            calendar: calendar,
            now: date(2026, 8, 5, 12, calendar: calendar)
        )

        XCTAssertEqual(effect.status, .unavailable)
        XCTAssertFalse(effect.detail.lowercased().contains("next-morning recovery"))
    }

    func testOpenPhysiologicalDayKeepsRecoveryPendingUntilSleepOrRollover() {
        let calendar = utc
        let priorWake = sleep(id: "prior",
                              start: date(2026, 8, 1, 23, calendar: calendar),
                              end: date(2026, 8, 2, 7, calendar: calendar))
        let workout = workout(id: "evening",
                              start: date(2026, 8, 2, 18, calendar: calendar),
                              end: date(2026, 8, 2, 19, calendar: calendar))

        let effect = AtriaActivityRecoveryEffect.make(
            workout: workout,
            rollups: [],
            confirmedSleeps: [priorWake],
            calendar: calendar,
            now: date(2026, 8, 2, 20, calendar: calendar)
        )

        XCTAssertEqual(effect.status, .pending)
        XCTAssertEqual(effect.valueText, "After your next sleep")
    }

    func testHistoricalBoundaryPreservesAdjustedSleepCoveragePolicy() {
        let calendar = utc
        let wakeDay = date(2026, 8, 3, 0, calendar: calendar)
        let dense = sleep(id: "dense-adjusted",
                          start: date(2026, 8, 3, 6, 30, calendar: calendar),
                          end: date(2026, 8, 3, 7, calendar: calendar),
                          source: "user_adjusted_sleep",
                          measuredDuration: 30 * 60)
        let denseCycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: wakeDay,
            confirmedSleeps: [dense],
            calendar: calendar
        )
        XCTAssertEqual(denseCycle.startBoundary, .mainSleep(id: dense.id))

        let sparse = sleep(id: "sparse-adjusted",
                           start: date(2026, 8, 2, 23, calendar: calendar),
                           end: date(2026, 8, 3, 7, calendar: calendar),
                           source: "user_adjusted_sleep",
                           measuredDuration: 30 * 60)
        let sparseCycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: wakeDay,
            confirmedSleeps: [sparse],
            calendar: calendar
        )
        XCTAssertTrue(sparseCycle.usesCivilFallback)
    }

    private func calendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    private func date(_ year: Int,
                      _ month: Int,
                      _ day: Int,
                      _ hour: Int,
                      _ minute: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year,
                                           month: month,
                                           day: day,
                                           hour: hour,
                                           minute: minute))!
    }

    private func sleep(id: String,
                       start: Date,
                       end: Date,
                       source: String = "manual_sleep",
                       eventTimeZoneIdentifier: String = "UTC",
                       measuredDuration: TimeInterval? = nil) -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: "user_confirmed",
                           sessions: 1,
                           samples: 100,
                           avgHR: 52,
                           peakHR: 60,
                           restingHR: 48,
                           hrv: 60,
                           hrvWindowCount: 4,
                           duration: measuredDuration ?? end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: true,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: eventTimeZoneIdentifier)
    }

    private func night(id: String,
                       day: Date,
                       start: Date,
                       end: Date,
                       confirmed: Bool,
                       source: String) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: day,
                                   start: start,
                                   end: end,
                                   duration: end.timeIntervalSince(start),
                                   restingHR: 52,
                                   hrv: nil,
                                   respiratoryRate: nil,
                                   sleepEfficiency: nil,
                                   confidence: confirmed ? "confirmed" : "review_needed",
                                   source: source,
                                   confirmed: confirmed,
                                   stageSegments: [])
    }

    private func workout(id: String,
                         start: Date,
                         end: Date) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: id,
                             createdAt: end,
                             start: start,
                             end: end,
                             label: "Workout",
                             source: "test",
                             confidence: "user_confirmed",
                             sessions: 1,
                             samples: 100,
                             avgHR: 120,
                             peakHR: 150,
                             p95HR: 145,
                             p99HR: 149,
                             thresholdHR: 110,
                             streamCoveragePercent: 100,
                             observedDuration: end.timeIntervalSince(start),
                             reason: "test",
                             zoneSeconds: [:])
    }
}
