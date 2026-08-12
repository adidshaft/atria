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

    func testActivityReprojectsStoredWakeDayIntoCallerCalendar() throws {
        let storageCalendar = calendar(timeZoneIdentifier: "Asia/Kolkata")
        let projectionCalendar = utc
        let wakeDay = date(2026, 8, 3, 0, calendar: projectionCalendar)
        let saved = sleep(
            id: "utc-wake-kolkata-snapshot",
            start: date(2026, 8, 3, 5, calendar: projectionCalendar),
            end: date(2026, 8, 3, 13, calendar: projectionCalendar),
            eventTimeZoneIdentifier: "UTC"
        )
        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [saved],
            calendar: storageCalendar
        )
        let stored = try XCTUnwrap(snapshot.nights.first { $0.id == saved.id })

        XCTAssertFalse(projectionCalendar.isDate(stored.day, inSameDayAs: wakeDay),
                       "The fixture must preserve the cross-output-calendar mismatch")

        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: wakeDay,
            sleepHistory: snapshot,
            calendar: projectionCalendar
        )
        let wakeDayRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            selectedDay: wakeDay,
            calendar: projectionCalendar
        )
        let priorDayRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            selectedDay: date(2026, 8, 2, 0, calendar: projectionCalendar),
            calendar: projectionCalendar
        )

        XCTAssertEqual(cycle.startBoundary, .mainSleep(id: saved.id))
        XCTAssertEqual(wakeDayRows.map(\.id), [saved.id])
        XCTAssertTrue(priorDayRows.isEmpty,
                      "A stored calendar label must not duplicate the sleep onto the prior projected day")
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

    // MARK: - Display-interval marker extension (handoff-5 P0-C)

    // The current physiological window starts at the anchoring wake, so the
    // sleep the user woke from ends exactly at `interval.start`. Its row is
    // admitted (boundary relaxation) but a marker clipped to the physiological
    // interval collapses to zero width — the physically reproduced "saved Sleep
    // row below the chart, empty marker band above it". The display interval
    // reaches back to the anchor's start so the marker carries factual bounds.
    func testCurrentWindowDisplayIntervalReachesBackToAnchorSleep() {
        let calendar = utc
        let anchor = sleep(id: "anchor",
                           start: date(2026, 8, 12, 6, 15, calendar: calendar),
                           end: date(2026, 8, 12, 15, 27, calendar: calendar))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [anchor],
                                            calendar: calendar)
        let now = date(2026, 8, 12, 18, 0, calendar: calendar)
        let window = AtriaActivityDisplayWindow.current(now: now,
                                                        sleepHistory: snapshot,
                                                        calendar: calendar)
        XCTAssertEqual(window.interval.start, anchor.end,
                       "physiological accounting still starts at the wake")
        XCTAssertEqual(window.displayInterval.start, anchor.start,
                       "the display reaches back to the anchoring sleep's start")
        XCTAssertEqual(window.displayInterval.end, window.interval.end)

        // Row/marker parity: the admitted boundary row clips to a non-empty
        // span against the display interval; against the physiological interval
        // it collapses to zero width (the old bug, kept as documentation).
        let rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: window.interval,
            calendar: calendar,
            includeStartBoundarySleep: true,
            mainSleepOwnershipDay: nil
        )
        XCTAssertEqual(rows.map(\.id), [anchor.id])
        let clippedStart = max(anchor.start, window.displayInterval.start)
        let clippedEnd = min(anchor.end, window.displayInterval.end)
        XCTAssertGreaterThan(clippedEnd, clippedStart,
                             "the marker span is non-empty under the display clip")
        let physiologicalClipEnd = min(anchor.end, window.interval.end)
        XCTAssertLessThanOrEqual(physiologicalClipEnd, window.interval.start,
                                 "the physiological clip alone yields no span — the pre-fix failure")
    }

    func testHistoricalWindowDisplayIntervalReachesBackToAnchorSleep() {
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
        let window = AtriaActivityDisplayWindow.historical(
            day: date(2026, 8, 2, 0, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar
        )
        XCTAssertEqual(window.interval.start, first.end)
        XCTAssertEqual(window.displayInterval.start, first.start,
                       "the historical display also reaches back to the wake-day anchor")
    }

    // A rollover or civil boundary has no saved sleep to reach back to; the
    // display interval must stay exactly the physiological interval.
    func testDisplayIntervalUnchangedWithoutAnchorSleep() {
        let calendar = utc
        let anchor = sleep(id: "anchor",
                           start: date(2026, 8, 1, 23, calendar: calendar),
                           end: date(2026, 8, 2, 7, calendar: calendar))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [anchor],
                                            calendar: calendar)
        // Aug 4 has no sleep at all: the window starts on a rollover/civil
        // boundary, not a wake.
        let window = AtriaActivityDisplayWindow.historical(
            day: date(2026, 8, 4, 0, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar
        )
        XCTAssertEqual(window.displayInterval, window.interval,
                       "no anchor sleep, no extension — a fake full-day span is forbidden")
    }

    // "Last night's nap" belongs to TODAY (2026-08-12 user decision): a nap
    // reclassified out of the mains chains into the night block that anchors
    // the current day (gap to the main sleep ≤ the resumed-sleep separation),
    // shows on Today next to the sleep the user woke from, and no prior window
    // claims it. Rows and markers agree because both consume the same selector
    // and the same extended interval.
    func testNightBlockNapBelongsToTodayAfterReclassification() {
        let calendar = utc
        let priorMain = sleep(id: "prior-main",
                              start: date(2026, 8, 10, 3, 30, calendar: calendar),
                              end: date(2026, 8, 10, 11, 55, calendar: calendar))
        let nap = sleep(id: "nap",
                        start: date(2026, 8, 12, 0, 58, calendar: calendar),
                        end: date(2026, 8, 12, 3, 41, calendar: calendar),
                        source: "user_adjusted_nap")
        let longMain = sleep(id: "long-main",
                             start: date(2026, 8, 12, 6, 15, calendar: calendar),
                             end: date(2026, 8, 12, 15, 27, calendar: calendar))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [priorMain, nap, longMain],
                                            calendar: calendar)
        let now = date(2026, 8, 12, 18, 0, calendar: calendar)

        let current = AtriaActivityDisplayWindow.current(now: now,
                                                         sleepHistory: snapshot,
                                                         calendar: calendar)
        XCTAssertEqual(current.interval.start, longMain.end,
                       "the long main anchors the current day once the short record is a nap")
        // The night block chains the 2h34m gap back to the nap's start, and the
        // display interval covers the whole block.
        XCTAssertEqual(current.displayInterval.start, nap.start,
                       "the display window covers the full night block, nap included")
        let currentRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: current.displayInterval,
            calendar: calendar,
            includeStartBoundarySleep: true,
            mainSleepOwnershipDay: nil
        )
        XCTAssertEqual(Set(currentRows.map(\.id)), [longMain.id, nap.id],
                       "Today shows the whole night it woke from: the main sleep AND last night's nap")

        // No REACHABLE prior day view may also claim the night-block records
        // (production navigation steps only through days before Today's label).
        for dayOffset in 0...1 {
            let labelDay = calendar.date(byAdding: .day,
                                         value: dayOffset,
                                         to: calendar.startOfDay(for: priorMain.end))!
            let window = AtriaActivityDisplayWindow.historical(
                day: labelDay,
                sleepHistory: snapshot,
                calendar: calendar
            )
            let rows = AtriaActivitySelectedDaySleeps.overlapping(
                snapshot: snapshot,
                pendingReview: nil,
                interval: window.interval,
                calendar: calendar,
                mainSleepOwnershipDay: window.labelDay
            )
            XCTAssertFalse(rows.contains { $0.id == nap.id },
                           "a prior window must not double-claim the current night block")
        }
    }

    // A distant nap (gap to the next main sleep beyond the resumed-sleep
    // separation) does NOT chain into the night block: it keeps its
    // interval-overlap placement on a prior day, and an overlapping
    // nap-inside-sleep record (a real user data shape) chains with its host.
    func testNightBlockChainRespectsSeparationAndOverlap() {
        let calendar = utc
        let distantNap = sleep(id: "distant-nap",
                               start: date(2026, 8, 11, 13, 0, calendar: calendar),
                               end: date(2026, 8, 11, 14, 0, calendar: calendar),
                               source: "user_adjusted_nap")
        let shortSleep = sleep(id: "short-sleep",
                               start: date(2026, 8, 12, 0, 58, calendar: calendar),
                               end: date(2026, 8, 12, 3, 41, calendar: calendar))
        let insideNap = sleep(id: "inside-nap",
                              start: date(2026, 8, 12, 1, 1, calendar: calendar),
                              end: date(2026, 8, 12, 3, 17, calendar: calendar),
                              source: "user_adjusted_nap")
        let longMain = sleep(id: "long-main",
                             start: date(2026, 8, 12, 6, 15, calendar: calendar),
                             end: date(2026, 8, 12, 15, 27, calendar: calendar))
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [distantNap, shortSleep, insideNap, longMain],
                                            calendar: calendar)
        let blockStart = AtriaActivityDisplayWindow.nightBlockStart(
            endingAt: longMain.end,
            sleepHistory: snapshot
        )
        // 6:15 − 3:41 = 2h34m chains the short sleep; the nap INSIDE it chains
        // by overlap; the 13:00–14:00 nap the previous afternoon is 10h51m
        // before the block and stays out.
        XCTAssertEqual(blockStart, shortSleep.start,
                       "the block chains through the short sleep and its overlapping nap, not the distant afternoon nap")
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
