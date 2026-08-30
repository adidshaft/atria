import XCTest
@testable import Atria

/// Physiological-day counter alignment (2026-08-30): the owner's directive is
/// that steps/strain/zone counters restart at the main-sleep boundary that
/// divides physiological days. These tests pin the three gaps closed in that
/// pass:
/// 1. Zone minutes subtract confirmed sleep exactly like the strain aggregate
///    (a fallback cycle must not book the night as restMinutes).
/// 2. Under a physiological open window, a stale civil archive row can never
///    masquerade as the open cycle's step receipt.
/// 3. The strain detail's dated-day series is cycle-keyed: closed wake-to-wake
///    cycles labelled by predominant civil day, summed in TRIMP space.
final class AtriaPhysiologicalDayCounterAlignmentTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func sleep(id: String, start: Date, end: Date) -> UserConfirmedSleep {
        UserConfirmedSleep(id: id,
                           createdAt: end,
                           start: start,
                           end: end,
                           source: "manual_sleep",
                           confidence: "user_confirmed",
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

    private func session(start: Date,
                         duration: TimeInterval,
                         bpm: Int,
                         cadence: TimeInterval = 10) -> SavedSession {
        SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Wear",
            points: stride(from: 0, through: duration, by: cadence).map {
                SavedSession.Point(t: $0, bpm: bpm)
            }
        )
    }

    // MARK: - Fix 1: zone minutes exclude confirmed sleep

    func testZoneMinutesSubtractConfirmedSleepLikeStrain() {
        let calendar = utc
        let cycleStart = date(2026, 8, 2, 6, calendar: calendar)
        let now = date(2026, 8, 2, 20, calendar: calendar)
        // 14h of low-and-steady wear covering an afternoon main sleep
        // (the owner's real shifted schedule: main sleep mid-afternoon).
        let wear = session(start: cycleStart, duration: 14 * 3_600, bpm: 70)
        let sleepInterval = DateInterval(
            start: date(2026, 8, 2, 14, 30, calendar: calendar),
            end: date(2026, 8, 2, 18, 30, calendar: calendar)
        )

        let without = SessionStore.makeTodayHRZoneMinutes(
            sessions: [wear],
            rest: 60,
            maxHR: 200,
            now: now,
            cycleStart: cycleStart,
            calendar: calendar
        )
        let with = SessionStore.makeTodayHRZoneMinutes(
            sessions: [wear],
            rest: 60,
            maxHR: 200,
            now: now,
            cycleStart: cycleStart,
            excludedLoadIntervals: [sleepInterval],
            calendar: calendar
        )

        XCTAssertTrue(without.hasSamples)
        XCTAssertTrue(with.hasSamples)
        // The 4h confirmed sleep must leave restMinutes, matching the strain
        // aggregate that excludes the same interval via includedLoadIntervals.
        assertWithin(without.restMinutes - with.restMinutes, 240, tolerance: 5)
        assertWithin(with.restMinutes, 600, tolerance: 10)
    }

    func testZoneMinutesDefaultParameterIsByteIdenticalToExplicitEmpty() {
        let calendar = utc
        let cycleStart = date(2026, 8, 2, 6, calendar: calendar)
        let now = date(2026, 8, 2, 20, calendar: calendar)
        let wear = session(start: cycleStart, duration: 4 * 3_600, bpm: 140)

        let defaulted = SessionStore.makeTodayHRZoneMinutes(
            sessions: [wear], rest: 60, maxHR: 200,
            now: now, cycleStart: cycleStart, calendar: calendar
        )
        let explicit = SessionStore.makeTodayHRZoneMinutes(
            sessions: [wear], rest: 60, maxHR: 200,
            now: now, cycleStart: cycleStart,
            excludedLoadIntervals: [], calendar: calendar
        )

        XCTAssertEqual(defaulted, explicit,
                       "The added parameter's default must not perturb existing callers")
    }

    private func assertWithin(_ lhs: Int, _ rhs: Int, tolerance: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(lhs - rhs), tolerance,
                                 "\(lhs) not within \(tolerance) of \(rhs)",
                                 file: file, line: line)
    }

    // MARK: - Fix 2: no civil masquerade under a physiological open window

    private func civilStepDay(dayStart: Date,
                              dayEnd: Date,
                              stepCount: Int) -> AtriaHistoricalDailyConsumerProjection.StepDay {
        AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2026-08-02",
            dayStart: dayStart,
            dayEnd: dayEnd,
            state: .available,
            stepCount: stepCount,
            knownStepDeltaSum: stepCount,
            knownEpochCount: stepCount,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: Int(dayEnd.timeIntervalSince(dayStart)),
            missingCoverageSeconds: 0
        )
    }

    func testPhysiologicalWindowWithoutMatchingReceiptIsNotReadyNeverCivil() {
        let calendar = utc
        let civilDay = date(2026, 8, 2, 0, calendar: calendar)
        let wake = date(2026, 8, 2, 4, calendar: calendar)
        let now = date(2026, 8, 2, 12, calendar: calendar)
        // A civil archive row (midnight-bounded) that does NOT carry the wake
        // boundary. Before 2026-08-30 it fell through as the open cycle's
        // "complete" count.
        let staleCivilRow = civilStepDay(dayStart: civilDay,
                                         dayEnd: date(2026, 8, 2, 3, calendar: calendar),
                                         stepCount: 5_000)

        let value = AtriaDailyStepPresentation.resolve(
            day: civilDay,
            now: now,
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [staleCivilRow],
            physiologicalDayStart: wake,
            calendar: calendar
        )

        XCTAssertNil(value.count,
                     "A civil row must never masquerade as the open cycle's receipt")
        XCTAssertEqual(value.completeness, .unavailable)
        XCTAssertEqual(value.source, .none)
        XCTAssertEqual(value.unavailabilityReason, .noCurrentCycleReceipt)
        XCTAssertEqual(value.detailText, "No verified receipt for this cycle")
    }

    func testPhysiologicalWindowStillAcceptsExactWakeBoundedReceipt() {
        let calendar = utc
        let civilDay = date(2026, 8, 2, 0, calendar: calendar)
        let wake = date(2026, 8, 2, 4, calendar: calendar)
        let now = date(2026, 8, 2, 12, calendar: calendar)
        let wakeBounded = civilStepDay(dayStart: wake,
                                       dayEnd: now,
                                       stepCount: 3_200)

        let value = AtriaDailyStepPresentation.resolve(
            day: civilDay,
            now: now,
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [wakeBounded],
            physiologicalDayStart: wake,
            calendar: calendar
        )

        XCTAssertEqual(value.count, 3_200)
        XCTAssertEqual(value.completeness, .complete)
        XCTAssertEqual(value.source, .verifiedCanonical)
    }

    func testCivilCallerWithoutPhysiologicalWindowKeepsCivilreceipt() {
        let calendar = utc
        let civilDay = date(2026, 8, 2, 0, calendar: calendar)
        let row = civilStepDay(dayStart: civilDay,
                               dayEnd: date(2026, 8, 3, 0, calendar: calendar),
                               stepCount: 5_000)

        // The history-row caller (HistoryVerifiedStepDayRow) passes NO
        // physiologicalDayStart; the civil path is pinned byte-identical.
        let value = AtriaDailyStepPresentation.resolve(
            day: civilDay,
            now: date(2026, 8, 4, 0, calendar: calendar),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [row],
            calendar: calendar
        )

        XCTAssertEqual(value.count, 5_000)
        XCTAssertEqual(value.completeness, .complete)
        XCTAssertEqual(value.detailText, "Verified complete day")
    }

    // MARK: - Fix 3: cycle-keyed strain series for the dated day view

    private func makeSeries(sessions: [SavedSession],
                            confirmedSleeps: [UserConfirmedSleep],
                            now: Date,
                            calendar: Calendar) -> [Date: Double]? {
        let open = AtriaPhysiologicalCycle.current(now: now,
                                                   confirmedSleeps: confirmedSleeps,
                                                   calendar: calendar)
        return SessionStore.physiologicalCycleStrainByDisplayDayCancellable(
            canonicalSessions: sessions,
            confirmedSleeps: confirmedSleeps,
            confirmedWorkouts: [],
            archiveHeartRatePoints: [],
            rest: 60,
            maxHR: 200,
            biologicalSex: .unspecified,
            openCycleStart: open.start,
            now: now,
            calendar: calendar
        )
    }

    func testShiftedSchedulePreWakeLoadStaysWithItsCycle() throws {
        let calendar = utc
        // The owner's real shape: main sleep mid-afternoon, ~14:30-18:30.
        let sleeps = [
            sleep(id: "a",
                  start: date(2026, 8, 1, 14, 30, calendar: calendar),
                  end: date(2026, 8, 1, 18, 30, calendar: calendar)),
            sleep(id: "b",
                  start: date(2026, 8, 2, 14, 30, calendar: calendar),
                  end: date(2026, 8, 2, 18, 30, calendar: calendar)),
            sleep(id: "c",
                  start: date(2026, 8, 3, 14, 30, calendar: calendar),
                  end: date(2026, 8, 3, 18, 30, calendar: calendar)),
        ]
        // Load on either side of civil midnight, both inside the ONE cycle
        // [Aug 2 18:30 wake -> Aug 3 18:30 wake]: civil grouping shreds this
        // across Aug 2 and Aug 3; the cycle series must not.
        let preMidnight = session(start: date(2026, 8, 2, 20, calendar: calendar),
                                  duration: 3_600, bpm: 150)
        let postMidnight = session(start: date(2026, 8, 3, 10, calendar: calendar),
                                   duration: 3_600, bpm: 150)
        let now = date(2026, 8, 3, 20, calendar: calendar)

        let series = try XCTUnwrap(makeSeries(
            sessions: [preMidnight, postMidnight],
            confirmedSleeps: sleeps,
            now: now,
            calendar: calendar
        ))

        let aug3 = date(2026, 8, 3, 0, calendar: calendar)
        let full = try XCTUnwrap(series[aug3],
                                 "The cycle's predominant civil day (18.5h of 24h) is Aug 3")
        XCTAssertGreaterThan(full, 0)
        // The earlier cycle [Aug 1 18:30 -> Aug 2 18:30] carries no evidence:
        // no bar is fabricated for it, and the pre-midnight load must NOT
        // appear under Aug 2 the way civil grouping put it there.
        XCTAssertEqual(series.count, 1)
        XCTAssertNil(series[date(2026, 8, 2, 0, calendar: calendar)])

        // Removing the pre-wake (pre-midnight) hour lowers the SAME bar,
        // proving that load travels with its physiological cycle.
        let withoutPreMidnight = try XCTUnwrap(makeSeries(
            sessions: [postMidnight],
            confirmedSleeps: sleeps,
            now: now,
            calendar: calendar
        ))
        let reduced = try XCTUnwrap(withoutPreMidnight[aug3])
        XCTAssertLessThan(reduced, full)
    }

    func testTwoClosedCyclesSharingACivilDaySumInTRIMPSpace() throws {
        let calendar = utc
        let sleeps = [
            sleep(id: "w1",
                  start: date(2026, 8, 4, 18, calendar: calendar),
                  end: date(2026, 8, 4, 22, calendar: calendar)),
            sleep(id: "w2",
                  start: date(2026, 8, 5, 16, calendar: calendar),
                  end: date(2026, 8, 5, 20, calendar: calendar)),
            sleep(id: "w3",
                  start: date(2026, 8, 5, 21, calendar: calendar),
                  end: date(2026, 8, 6, 0, 30, calendar: calendar)),
        ]
        // Cycle 1 [Aug 4 22:00 -> Aug 5 20:00] predominates Aug 5 (20h of 22h).
        // Cycle 2 [Aug 5 20:00 -> Aug 6 00:30] predominates Aug 5 (4h of 4.5h).
        // Cycle 2's load sits in its awake gap (20:00 wake -> 21:00 bedtime);
        // load during the 21:00-00:30 recovery sleep would rightly be excluded.
        let inCycle1 = session(start: date(2026, 8, 5, 8, calendar: calendar),
                               duration: 3_600, bpm: 150)
        let inCycle2 = session(start: date(2026, 8, 5, 20, 5, calendar: calendar),
                               duration: 45 * 60, bpm: 150)
        let now = date(2026, 8, 6, 10, calendar: calendar)
        let sessions = [inCycle1, inCycle2]

        let series = try XCTUnwrap(makeSeries(
            sessions: sessions,
            confirmedSleeps: sleeps,
            now: now,
            calendar: calendar
        ))

        let aug5 = date(2026, 8, 5, 0, calendar: calendar)
        let summed = try XCTUnwrap(series[aug5])
        // TRIMP-space sum, one saturating display map at the end (GAP-09 rule):
        // rebuild the expectation from the SAME hero machinery per cycle.
        let sleepIntervals = sleeps.map { DateInterval(start: $0.start, end: $0.end) }
        func cycleTRIMP(start: Date, end: Date) throws -> Double {
            try XCTUnwrap(SessionStore.homeSavedAggregateCancellable(
                from: sessions,
                rest: 60,
                maxHR: 200,
                biologicalSex: .unspecified,
                calendar: calendar,
                now: end,
                cycleStart: start,
                excludedLoadIntervals: sleepIntervals,
                shouldContinue: { true }
            )).savedTodayTRIMP
        }
        let expected = Metrics.strain(fromTRIMP:
            (try cycleTRIMP(start: date(2026, 8, 4, 22, calendar: calendar),
                            end: date(2026, 8, 5, 20, calendar: calendar)))
            + (try cycleTRIMP(start: date(2026, 8, 5, 20, calendar: calendar),
                              end: date(2026, 8, 6, 0, 30, calendar: calendar)))
        )
        XCTAssertEqual(summed, expected, accuracy: 1e-9)

        // And the sum genuinely raises the bar over either cycle alone.
        let onlyFirst = try XCTUnwrap(makeSeries(sessions: [inCycle1],
                                                 confirmedSleeps: sleeps,
                                                 now: now,
                                                 calendar: calendar))
        XCTAssertLessThan(try XCTUnwrap(onlyFirst[aug5]), summed)
    }

    func testExactMidnightSplitKeepsTheEarlierDay() throws {
        let calendar = utc
        let sleeps = [
            sleep(id: "n1",
                  start: date(2026, 8, 7, 8, calendar: calendar),
                  end: date(2026, 8, 7, 12, calendar: calendar)),
            sleep(id: "n2",
                  start: date(2026, 8, 8, 8, calendar: calendar),
                  end: date(2026, 8, 8, 12, calendar: calendar)),
        ]
        // Cycle [Aug 7 12:00 -> Aug 8 12:00] splits 12h/12h at midnight; the
        // predominant-day precedent (AtriaStepsWeekChart) keeps the EARLIER day.
        let load = session(start: date(2026, 8, 7, 18, calendar: calendar),
                           duration: 3_600, bpm: 150)
        let now = date(2026, 8, 8, 20, calendar: calendar)

        let series = try XCTUnwrap(makeSeries(sessions: [load],
                                              confirmedSleeps: sleeps,
                                              now: now,
                                              calendar: calendar))

        XCTAssertNotNil(series[date(2026, 8, 7, 0, calendar: calendar)])
        XCTAssertNil(series[date(2026, 8, 8, 0, calendar: calendar)])
    }

    func testNoConfirmedSleepsYieldsEmptySeriesSoChartsKeepCivilValues() throws {
        let calendar = utc
        let load = session(start: date(2026, 8, 7, 18, calendar: calendar),
                           duration: 3_600, bpm: 150)

        let series = try XCTUnwrap(makeSeries(sessions: [load],
                                              confirmedSleeps: [],
                                              now: date(2026, 8, 8, 20, calendar: calendar),
                                              calendar: calendar))

        // No confirmed boundaries -> no cycle claims; every day charts its
        // civil rollup value (the honesty rule, documented on the builder).
        XCTAssertTrue(series.isEmpty)
    }

    func testOpenCycleIsNeverInTheSeries() throws {
        let calendar = utc
        let sleeps = [
            sleep(id: "n1",
                  start: date(2026, 8, 7, 14, 30, calendar: calendar),
                  end: date(2026, 8, 7, 18, 30, calendar: calendar)),
        ]
        // All load sits in the OPEN cycle (after the only wake): the hero owns
        // that value; the series must not compute a competing "today".
        let load = session(start: date(2026, 8, 7, 20, calendar: calendar),
                           duration: 3_600, bpm: 150)

        let series = try XCTUnwrap(makeSeries(sessions: [load],
                                              confirmedSleeps: sleeps,
                                              now: date(2026, 8, 7, 22, calendar: calendar),
                                              calendar: calendar))

        XCTAssertTrue(series.isEmpty)
    }
}
