import XCTest
@testable import Atria

/// Sleep Planner math (2026-07-07): goal fractions, efficiency learning
/// gate, and the worked-back bedtime including midnight wrap.
final class AtriaSleepPlannerTests: XCTestCase {
    func testPeakPlanWorksBackFromWake() {
        // Need 8h, wake by 6:30 (390), learned efficiency 0.9 from 5 nights:
        // in bed 8/0.9 = 8h53m before 6:30 → 21:37.
        let plan = AtriaSleepPlanner.plan(needHours: 8, goal: .peak, wakeByMinutes: 390,
                                          nightEfficiencies: [0.9, 0.9, 0.9, 0.9, 0.9])
        XCTAssertEqual(plan.targetSleepHours, 8)
        XCTAssertFalse(plan.efficiencyIsDefault)
        XCTAssertEqual(plan.inBedByMinutes, (390 - 533 + 1440) % 1440)
    }

    func testBedtimeWrapsPastMidnight() {
        let plan = AtriaSleepPlanner.plan(needHours: 8, goal: .peak, wakeByMinutes: 390,
                                          nightEfficiencies: [0.9, 0.9, 0.9, 0.9, 0.9])
        XCTAssertEqual(plan.inBedByMinutes, (390 - 533 + 1440) % 1440)
        XCTAssertEqual(plan.inBedByMinutes, 1297)  // 21:37
    }

    func testGetByAimsForSeventyPercent() {
        let plan = AtriaSleepPlanner.plan(needHours: 10, goal: .getBy, wakeByMinutes: 420,
                                          nightEfficiencies: [])
        XCTAssertEqual(plan.targetSleepHours, 7.0, accuracy: 0.001)
        XCTAssertTrue(plan.efficiencyIsDefault)
        XCTAssertEqual(plan.assumedEfficiency, 0.90, accuracy: 0.001)
    }

    func testEfficiencyNeedsFiveRealNights() {
        let learning = AtriaSleepPlanner.assumedEfficiency(nightEfficiencies: [0.8, 0.8, 0.8, 0.8])
        XCTAssertTrue(learning.isDefault)
        let learned = AtriaSleepPlanner.assumedEfficiency(nightEfficiencies: [0.8, 0.82, 0.84, 0.86, 0.88])
        XCTAssertFalse(learned.isDefault)
        XCTAssertEqual(learned.value, 0.84, accuracy: 0.001)
        // Junk efficiencies (holes, >1) never count toward the gate.
        let junk = AtriaSleepPlanner.assumedEfficiency(nightEfficiencies: [0.2, 1.4, 0.9, 0.9, 0.9])
        XCTAssertTrue(junk.isDefault)
    }

    func testEvenEfficiencyHistoryUsesBothMiddleNights() {
        let learned = AtriaSleepPlanner.assumedEfficiency(
            nightEfficiencies: [0.70, 0.76, 0.82, 0.88, 0.94, 1.0]
        )
        XCTAssertEqual(learned.value, 0.85, accuracy: 0.000_001)
        XCTAssertFalse(learned.isDefault)
    }

    /// W3.3: without a wake alarm the plan follows the wearer's own schedule.
    /// The owner sleeps ~13:15–19:15; a 07:30 default put "in bed by" ~12 h off.
    func testPlanWithoutAlarmWorksBackFromTheTypicalShiftedWake() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wakes = (1...5).map { offset -> Date in
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: base))!
            return calendar.date(bySettingHour: 19, minute: 10 + offset, second: 0, of: day)!
        }
        let wakeBy = AtriaSleepPlanner.resolvedWakeByMinutes(alarmEnabled: false,
                                                             alarmWakeByMinutes: 7 * 60 + 30,
                                                             recentMainWakes: wakes,
                                                             calendar: calendar)
        XCTAssertEqual(wakeBy, 19 * 60 + 13)
        let plan = AtriaSleepPlanner.plan(needHours: 6, goal: .peak, wakeByMinutes: wakeBy, nightEfficiencies: [])
        XCTAssertGreaterThanOrEqual(plan.inBedByMinutes, 11 * 60)
        XCTAssertLessThanOrEqual(plan.inBedByMinutes, 14 * 60, "in bed around midday, not at night")
    }

    func testAlarmWinsAndThinHistoryFallsBackToTheStoredWake() {
        let wakes = [Date(timeIntervalSince1970: 1_800_000_000)]
        XCTAssertEqual(AtriaSleepPlanner.resolvedWakeByMinutes(alarmEnabled: true, alarmWakeByMinutes: 400,
                                                               recentMainWakes: wakes), 400)
        XCTAssertEqual(AtriaSleepPlanner.resolvedWakeByMinutes(alarmEnabled: false, alarmWakeByMinutes: 450,
                                                               recentMainWakes: wakes), 450,
                       "fewer than 3 wakes is not a typical schedule yet")
    }
}
