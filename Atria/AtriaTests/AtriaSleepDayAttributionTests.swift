import XCTest
@testable import Atria

/// Device-reproduced 2026-08-20 19:09 IST: a shifted sleeper's confirmed
/// record `1787211908-1787233500-user_adjusted_sleep` (Aug 20 13:15 -> 19:15,
/// Asia/Kolkata — both endpoints on Aug 20) displayed under AUG 19 after the
/// user EDITED (extended) its end from 16:15 to 19:15.
///
/// Mechanism: `AtriaPhysiologicalCycle.boundaryEligibleMainSleeps` requires
/// `end <= now`, so the freshly adjusted sleep whose wake sat minutes in the
/// future could not anchor the live cycle. With last night's overnight
/// detection dismissed, the cycle fell back to the PREVIOUS wake (Aug 19
/// 18:50) and `AtriaPhysiologicalDay.displayDay` — the previous wake's civil
/// day — labelled the whole current Activity window "Aug 19", with the Aug 20
/// sleep row shown inside it. The cycle math is left untouched (recovery,
/// strain, and interval accounting keep wake-to-wake authority);
/// `AtriaActivityDisplayWindow.currentLabelDay` corrects only the USER-FACING
/// label so the row groups under its own wake civil day.
final class AtriaSleepDayAttributionTests: XCTestCase {

    // MARK: - Device shape (shifted sleeper, no intervening overnight sleep)

    func testAdjustedAfternoonSleepStaysOnItsCivilDayWhileWakeIsMinutesAhead() {
        let calendar = kolkata
        let priorWake = sleep(id: "prior-adjusted",
                              start: date(2026, 8, 19, 12, 50, calendar: calendar),
                              end: date(2026, 8, 19, 18, 50, calendar: calendar),
                              source: "user_adjusted_sleep",
                              eventTimeZoneIdentifier: "Asia/Kolkata")
        let adjusted = sleep(id: "1787211908-1787233500-user_adjusted_sleep",
                             start: date(2026, 8, 20, 13, 15, calendar: calendar),
                             end: date(2026, 8, 20, 19, 15, calendar: calendar),
                             source: "user_adjusted_sleep",
                             eventTimeZoneIdentifier: "Asia/Kolkata")
        // Last night's overnight detection (23:53 -> 09:01) was DISMISSED, so
        // no confirmed sleep exists between the two records.
        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [priorWake, adjusted],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(
                    start: date(2026, 8, 19, 23, 53, calendar: calendar),
                    end: date(2026, 8, 20, 9, 1, calendar: calendar))
            ],
            calendar: calendar)
        let now = date(2026, 8, 20, 19, 9, calendar: calendar)
        let aug19 = date(2026, 8, 19, 0, calendar: calendar)
        let aug20 = date(2026, 8, 20, 0, calendar: calendar)

        // The cycle authority deliberately stays put: the adjusted wake has not
        // passed yet, so physiological accounting still runs from Aug 19 18:50.
        let cycleDay = AtriaPhysiologicalDay.current(now: now,
                                                     sleepHistory: snapshot,
                                                     calendar: calendar)
        XCTAssertEqual(cycleDay.start, priorWake.end,
                       "wake-to-wake accounting keeps the previous wake until the edited wake passes")
        XCTAssertEqual(cycleDay.displayDay, aug19,
                       "the raw cycle label is the previous wake's civil day — the pre-fix failure input")

        // The fix: the USER-FACING current window is labelled Aug 20, so the
        // Aug 20 sleep row groups under its own civil day.
        let window = AtriaActivityDisplayWindow.current(now: now,
                                                        sleepHistory: snapshot,
                                                        calendar: calendar)
        XCTAssertEqual(window.interval.start, priorWake.end,
                       "interval accounting is untouched by the label correction")
        XCTAssertEqual(window.labelDay, aug20,
                       "a confirmed sleep lying entirely inside Aug 20 must group under Aug 20")

        // The row itself is present in the current-day selection (mirrors
        // makeDaySections' current-day arguments).
        let currentRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: window.interval,
            calendar: calendar,
            includeStartBoundarySleep: true,
            mainSleepOwnershipDay: nil)
        XCTAssertTrue(currentRows.contains { $0.id == adjusted.id },
                      "the edited sleep stays visible on the current day view")

        // And the Aug 19 historical view does NOT also claim it.
        let aug19Window = AtriaActivityDisplayWindow.historical(day: aug19,
                                                                sleepHistory: snapshot,
                                                                calendar: calendar)
        let aug19Rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: aug19Window.interval,
            calendar: calendar,
            mainSleepOwnershipDay: aug19)
        XCTAssertTrue(aug19Rows.contains { $0.id == priorWake.id })
        XCTAssertFalse(aug19Rows.contains { $0.id == adjusted.id },
                       "an Aug 20 sleep must not appear under the Aug 19 day view")
    }

    func testSaveThenAdjustKeepsTheSleepOnTheSameCivilDay() {
        let calendar = kolkata
        let priorWake = sleep(id: "prior-adjusted",
                              start: date(2026, 8, 19, 12, 50, calendar: calendar),
                              end: date(2026, 8, 19, 18, 50, calendar: calendar),
                              source: "user_adjusted_sleep",
                              eventTimeZoneIdentifier: "Asia/Kolkata")
        let aug20 = date(2026, 8, 20, 0, calendar: calendar)

        // Fresh save 13:15 -> 16:15, viewed shortly after: labelled Aug 20.
        let saved = sleep(id: "saved-initial",
                          start: date(2026, 8, 20, 13, 15, calendar: calendar),
                          end: date(2026, 8, 20, 16, 15, calendar: calendar),
                          source: "user_adjusted_sleep",
                          eventTimeZoneIdentifier: "Asia/Kolkata")
        let savedSnapshot = SleepHistorySnapshot(rollups: [],
                                                 confirmedSleeps: [priorWake, saved],
                                                 calendar: calendar)
        let afterSave = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 16, 20, calendar: calendar),
            sleepHistory: savedSnapshot,
            calendar: calendar)
        XCTAssertEqual(afterSave.labelDay, aug20)

        // Adjust extends the end past "now" (the device edit at 19:09 set the
        // wake to 19:15). The record must NOT move to Aug 19.
        let adjusted = sleep(id: "saved-adjusted",
                             start: date(2026, 8, 20, 13, 15, calendar: calendar),
                             end: date(2026, 8, 20, 19, 15, calendar: calendar),
                             source: "user_adjusted_sleep",
                             eventTimeZoneIdentifier: "Asia/Kolkata")
        let adjustedSnapshot = SleepHistorySnapshot(rollups: [],
                                                    confirmedSleeps: [priorWake, adjusted],
                                                    calendar: calendar)
        let afterAdjust = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 19, 9, calendar: calendar),
            sleepHistory: adjustedSnapshot,
            calendar: calendar)
        XCTAssertEqual(afterAdjust.labelDay, aug20,
                       "adjusting the end forward must not move the entry to the previous day")

        // Once the edited wake passes, the cycle itself advances and the label
        // derivation is a no-op agreeing with it.
        let afterWake = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 19, 30, calendar: calendar),
            sleepHistory: adjustedSnapshot,
            calendar: calendar)
        XCTAssertEqual(afterWake.interval.start, adjusted.end)
        XCTAssertEqual(afterWake.labelDay, aug20)
    }

    // MARK: - Conventional overnight sleep must not regress

    func testConventionalOvernightSleepGroupsUnderItsWakeDay() {
        let calendar = kolkata
        let priorNight = sleep(id: "prior-night",
                               start: date(2026, 8, 18, 23, 0, calendar: calendar),
                               end: date(2026, 8, 19, 7, 0, calendar: calendar),
                               eventTimeZoneIdentifier: "Asia/Kolkata")
        let overnight = sleep(id: "overnight",
                              start: date(2026, 8, 19, 23, 0, calendar: calendar),
                              end: date(2026, 8, 20, 7, 0, calendar: calendar),
                              eventTimeZoneIdentifier: "Asia/Kolkata")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [priorNight, overnight],
                                            calendar: calendar)
        let aug19 = date(2026, 8, 19, 0, calendar: calendar)
        let aug20 = date(2026, 8, 20, 0, calendar: calendar)

        // Snapshot day derivation: the wake civil day.
        XCTAssertTrue(snapshot.nights.contains {
            $0.id == overnight.id && calendar.isDate($0.day, inSameDayAs: aug20)
        })

        // Current window after the wake: labelled by the wake day, unchanged.
        let window = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 9, 0, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar)
        XCTAssertEqual(window.interval.start, overnight.end)
        XCTAssertEqual(window.labelDay, aug20)

        // The bedtime day does not claim the overnight record.
        let aug19Window = AtriaActivityDisplayWindow.historical(day: aug19,
                                                                sleepHistory: snapshot,
                                                                calendar: calendar)
        let aug19Rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            interval: aug19Window.interval,
            calendar: calendar,
            mainSleepOwnershipDay: aug19)
        XCTAssertTrue(aug19Rows.contains { $0.id == priorNight.id })
        XCTAssertFalse(aug19Rows.contains { $0.id == overnight.id },
                       "a 23:00 -> 07:00 night belongs to the wake day, never the bedtime day")
    }

    func testConventionalOvernightEditedWakeMinutesAheadKeepsWakeDayLabel() {
        let calendar = kolkata
        let priorNight = sleep(id: "prior-night",
                               start: date(2026, 8, 18, 23, 0, calendar: calendar),
                               end: date(2026, 8, 19, 7, 0, calendar: calendar),
                               eventTimeZoneIdentifier: "Asia/Kolkata")
        // Same edit shape as the device bug, but for a normal overnight
        // sleeper who rounds the wake up right after getting out of bed.
        let edited = sleep(id: "overnight-edited",
                           start: date(2026, 8, 19, 23, 0, calendar: calendar),
                           end: date(2026, 8, 20, 7, 15, calendar: calendar),
                           source: "user_adjusted_sleep",
                           eventTimeZoneIdentifier: "Asia/Kolkata")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [priorNight, edited],
                                            calendar: calendar)
        let window = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 7, 10, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar)
        XCTAssertEqual(window.labelDay,
                       date(2026, 8, 20, 0, calendar: calendar),
                       "the edited night groups under its wake day even while the wake is minutes ahead")
    }

    // MARK: - Fail-closed guards on the label correction

    func testPendingNapDoesNotRelabelTheCurrentDay() {
        let calendar = kolkata
        let priorWake = sleep(id: "prior-adjusted",
                              start: date(2026, 8, 19, 12, 50, calendar: calendar),
                              end: date(2026, 8, 19, 18, 50, calendar: calendar),
                              source: "user_adjusted_sleep",
                              eventTimeZoneIdentifier: "Asia/Kolkata")
        let nap = sleep(id: "afternoon-nap",
                        start: date(2026, 8, 20, 13, 15, calendar: calendar),
                        end: date(2026, 8, 20, 19, 15, calendar: calendar),
                        source: "user_adjusted_nap",
                        eventTimeZoneIdentifier: "Asia/Kolkata")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [priorWake, nap],
                                            calendar: calendar)
        let window = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 19, 9, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar)
        XCTAssertEqual(window.labelDay,
                       date(2026, 8, 19, 0, calendar: calendar),
                       "a nap never advances the current day's label")
    }

    func testPendingWakeOnAnotherCivilDayDoesNotRelabelToday() {
        let calendar = kolkata
        let priorWake = sleep(id: "prior-adjusted",
                              start: date(2026, 8, 19, 12, 50, calendar: calendar),
                              end: date(2026, 8, 19, 18, 50, calendar: calendar),
                              source: "user_adjusted_sleep",
                              eventTimeZoneIdentifier: "Asia/Kolkata")
        // A record whose wake sits on TOMORROW's civil day must not label the
        // current window with a day that has not begun.
        let crossDay = sleep(id: "cross-day",
                             start: date(2026, 8, 20, 13, 15, calendar: calendar),
                             end: date(2026, 8, 21, 5, 0, calendar: calendar),
                             source: "user_adjusted_sleep",
                             eventTimeZoneIdentifier: "Asia/Kolkata")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [priorWake, crossDay],
                                            calendar: calendar)
        // Before the prior wake's no-sleep rollover (18:50 + 1 day + 30 min).
        let window = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 19, 10, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar)
        XCTAssertEqual(window.labelDay,
                       date(2026, 8, 19, 0, calendar: calendar))
    }

    func testAcrossMidnightWithoutNewWakeKeepsTheCycleLabel() {
        let calendar = kolkata
        let priorNight = sleep(id: "prior-night",
                               start: date(2026, 8, 18, 23, 0, calendar: calendar),
                               end: date(2026, 8, 19, 7, 0, calendar: calendar),
                               eventTimeZoneIdentifier: "Asia/Kolkata")
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [priorNight],
                                            calendar: calendar)
        // 01:00 the following civil day, no new sleep: the deliberate
        // "Today · Aug 19" across-midnight disclosure stands — only a
        // confirmed current-civil-day wake may advance the label.
        let window = AtriaActivityDisplayWindow.current(
            now: date(2026, 8, 20, 1, 0, calendar: calendar),
            sleepHistory: snapshot,
            calendar: calendar)
        XCTAssertEqual(window.interval.start, priorNight.end)
        XCTAssertEqual(window.labelDay,
                       date(2026, 8, 19, 0, calendar: calendar))
    }

    // MARK: - Fixtures

    private var kolkata: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
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
                       eventTimeZoneIdentifier: String = "Asia/Kolkata") -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: "user_adjusted_hr_only",
                           sessions: 1,
                           samples: 100,
                           avgHR: 58,
                           peakHR: 66,
                           restingHR: 54,
                           hrv: 55,
                           hrvWindowCount: 4,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: false,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: eventTimeZoneIdentifier)
    }
}
