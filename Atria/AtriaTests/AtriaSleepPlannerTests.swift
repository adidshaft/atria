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
}
