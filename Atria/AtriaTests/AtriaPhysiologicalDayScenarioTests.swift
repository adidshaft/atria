import XCTest
@testable import Atria

/// docs/PHYSIOLOGICAL_DAY.md scenarios: a day runs wake → next wake, anchored
/// on the main sleep wherever it falls on the clock. Every live surface
/// (Today, strain, steps receipts, recovery attribution) and the historical
/// day resolver delegate to `AtriaPhysiologicalCycle`, so these pin it.
final class AtriaPhysiologicalDayScenarioTests: XCTestCase {
    /// Asia/Kolkata (the owner's zone): the shifted-schedule cases are real
    /// local times, not a UTC convenience.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func sleep(_ id: String, _ start: Date, _ end: Date,
                       source: String = "manual_sleep") -> UserConfirmedSleep {
        UserConfirmedSleep(id: id, createdAt: end, start: start, end: end,
                           source: source, confidence: "user", sessions: 1, samples: 100,
                           avgHR: 52, peakHR: 60, restingHR: 48, hrv: 60, hrvWindowCount: 4,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test", motionSource: "test", motionValidated: true,
                           stageSegments: nil, eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    private func today(_ now: Date, _ sleeps: [UserConfirmedSleep]) -> AtriaPhysiologicalDay {
        AtriaPhysiologicalDay.current(now: now, confirmedSleeps: sleeps, calendar: calendar)
    }

    private func history(_ day: Int, _ sleeps: [UserConfirmedSleep]) -> AtriaHistoricalPhysiologicalCycle {
        AtriaHistoricalPhysiologicalCycle.resolve(displayDay: at(day, 12), confirmedSleeps: sleeps,
                                                  calendar: calendar)
    }

    // 1. Normal night.
    func testNormalNightDayRunsWakeToWakeAcrossMidnight() {
        let n1 = sleep("n1", at(19, 23), at(20, 7))
        let n2 = sleep("n2", at(20, 23, 30), at(21, 7, 15))
        // 00:40 after midnight, not yet asleep: still the 20th's day.
        let late = today(at(21, 0, 40), [n1])
        XCTAssertEqual(late.start, n1.end)
        XCTAssertEqual(late.displayDay, calendar.startOfDay(for: at(20, 12)))
        let day20 = history(20, [n1, n2])
        XCTAssertEqual(day20.interval, DateInterval(start: n1.end, end: n2.end))
        XCTAssertEqual(day20.startBoundary, .mainSleep(id: "n1"))
        XCTAssertEqual(day20.endBoundary, .mainSleep(id: "n2"))
    }

    // 2. Shifted afternoon sleeper (main sleep ~13:15 → 19:15).
    func testShiftedAfternoonSleeperDayStartsAtTheEveningWake() {
        let s1 = sleep("s1", at(19, 13, 15), at(19, 19, 15))
        let s2 = sleep("s2", at(20, 13, 40), at(20, 19, 5))
        // 02:00 and 11:00 the next civil day are still inside the same day.
        for now in [at(20, 2), at(20, 11)] {
            let day = today(now, [s1])
            XCTAssertEqual(day.start, s1.end, "midnight is not a boundary for \(now)")
            XCTAssertEqual(day.boundaryKind, .mainSleep)
        }
        let day19 = history(19, [s1, s2])
        XCTAssertEqual(day19.interval, DateInterval(start: s1.end, end: s2.end))
        // The afternoon sleep closes the day and opens the next one.
        XCTAssertEqual(today(at(20, 21), [s1, s2]).start, s2.end)
    }

    // 3. Split night (up at 2 am for 30 min), stored as two main sleeps.
    func testSplitNightIsOneNightForTheDayBoundary() {
        let prior = sleep("prior", at(19, 23), at(20, 7))
        let first = sleep("first", at(20, 23), at(21, 2))       // 3 h: a main sleep
        let second = sleep("second", at(21, 2, 30), at(21, 7, 30))
        let all = [prior, first, second]
        // Once the second half is confirmed (after its 07:30 wake), the 02:00
        // wake is not a boundary: the day runs to the final wake. (Before
        // then the second half is unknown; the verbatim end <= now gate that
        // AtriaCycleFlipSettlementTests pins is deliberately kept.)
        XCTAssertEqual(today(at(21, 9), all).start, second.end)
        XCTAssertEqual(today(at(21, 9), [prior, first]).start, first.end,
                       "without the second half, the 02:00 wake stands")
        // History: the 20th runs to the final wake, with no orphaned
        // 02:00 → 07:30 interval owned by no day.
        let day20 = history(20, all)
        XCTAssertEqual(day20.interval, DateInterval(start: prior.end, end: second.end))
        XCTAssertEqual(history(21, all).interval.start, second.end)
    }

    /// The same split straddling midnight: the evening half's 23:50 wake must
    /// not become the 20th's anchor (that would label the 20th's whole waking
    /// day with the night's values).
    func testSplitNightAcrossMidnightKeepsTheWakingDayOnItsOwnDate() {
        let prior = sleep("prior", at(19, 23), at(20, 7))
        let evening = sleep("evening", at(20, 20, 30), at(20, 23, 50))
        let rest = sleep("rest", at(21, 0, 30), at(21, 6, 45))
        let day20 = history(20, [prior, evening, rest])
        XCTAssertEqual(day20.startBoundary, .mainSleep(id: "prior"))
        XCTAssertEqual(day20.interval, DateInterval(start: prior.end, end: rest.end))
    }

    /// A real second sleep after a long awake gap is NOT merged: a biphasic
    /// schedule (night + afternoon) keeps both boundaries.
    func testSeparateSleepsAfterALongAwakeGapStayDistinct() {
        let bridged = AtriaPhysiologicalCycle.bridgingBriefAwakenings([
            sleep("a", at(20, 1), at(20, 6)),
            sleep("b", at(20, 13), at(20, 17)),   // 7 h later
        ])
        XCTAssertEqual(bridged.map(\.id), ["a", "b"])
        let justUnder = AtriaPhysiologicalCycle.bridgingBriefAwakenings([
            sleep("a", at(20, 1), at(20, 4)),
            sleep("b", at(20, 5, 29), at(20, 9)),  // 89 min later
        ])
        XCTAssertEqual(justUnder.map(\.id), ["b"])
    }

    // 4. Naps never start a new day — whatever the clock says.
    func testNapsDoNotStartANewDay() {
        let night = sleep("night", at(19, 23), at(20, 7))
        let afternoonNap = sleep("nap", at(20, 14), at(20, 15, 30), source: "manual_nap")
        let autoShortNap = sleep("short", at(20, 17), at(20, 18), source: "auto_sleep")
        let day = today(at(20, 20), [night, afternoonNap, autoShortNap])
        XCTAssertEqual(day.start, night.end)
        XCTAssertEqual(day.boundaryKind, .mainSleep)
        // Same for a shifted sleeper's late-night nap.
        let shifted = sleep("shifted", at(19, 13, 15), at(19, 19, 15))
        let lateNap = sleep("lateNap", at(20, 2), at(20, 3), source: "manual_nap")
        XCTAssertEqual(today(at(20, 5), [shifted, lateNap]).start, shifted.end)
    }

    // 5. No-sleep day: the day rolls wake + 24 h (+ settlement grace), never
    //    at midnight, and never carries yesterday forever.
    func testNoSleepDayRollsAtTheWakeAnniversaryNotMidnight() {
        let last = sleep("last", at(19, 23), at(20, 7))
        let justAfterMidnight = today(at(21, 0, 30), [last])
        XCTAssertEqual(justAfterMidnight.start, last.end)
        let grace = AtriaPhysiologicalCycle.noSleepSettlementGrace
        let rolled = today(at(21, 9), [last])
        XCTAssertEqual(rolled.boundaryKind, .noSleepFallback)
        XCTAssertEqual(rolled.start, at(21, 7).addingTimeInterval(grace))
        let twoDaysLater = today(at(22, 9), [last])
        XCTAssertEqual(twoDaysLater.start, at(22, 7).addingTimeInterval(grace))
    }
}
