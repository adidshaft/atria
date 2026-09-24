import XCTest
@testable import Atria

/// Steps week chart honesty (2026-09-24): a partial day (today so far, thin
/// strap coverage, receipt-only) shows its count with an at-least marker and
/// is never judged as a missed goal.
final class AtriaStepsWeekChartPartialTests: XCTestCase {
    typealias Chart = AtriaStepsWeekChart

    func testUnfinishedDayIsNeverColouredAsAMissedGoal() {
        XCTAssertEqual(Chart.barStyle(steps: 1_200, goal: 10_000, isPartial: true), .partial,
                       "08:00 today with 1,200 steps is not a red day")
        XCTAssertEqual(Chart.barStyle(steps: 1_200, goal: 10_000, isPartial: false), .wellUnder)
        XCTAssertEqual(Chart.barStyle(steps: 6_000, goal: 10_000, isPartial: false), .under)
        // A lower bound that already clears the goal is a met goal.
        XCTAssertEqual(Chart.barStyle(steps: 10_400, goal: 10_000, isPartial: true), .met)
    }

    func testPartialCountIsAnAtLeastNeverAFakeTotal() {
        XCTAssertTrue(Chart.countLabel(steps: 4_210, isPartial: true).hasSuffix("+"))
        XCTAssertFalse(Chart.countLabel(steps: 4_210, isPartial: false).hasSuffix("+"))
        XCTAssertEqual(Chart.countLabel(steps: 4_210, isPartial: true)
                        .filter(\.isNumber), "4210", "the marker labels the count; it never changes it")
    }

    private func record(coverage: Int, complete: Bool) -> AtriaCivilDayStepAuthority.DayRecord {
        .init(dayStartUnix: 0, steps: 5_000, ticks: 6_000, knownCoverageSeconds: coverage,
              sourceFingerprint: "f", exclusionFingerprint: "e", computedAtUnix: 0,
              dayWasComplete: complete)
    }

    func testCoverageFloorIsARatioOfTheActualDayLength() {
        let day: TimeInterval = 86_400
        XCTAssertTrue(AtriaCivilDayStepAuthority.isPartial(record: record(coverage: 86_400, complete: false),
                                                           dayLength: day), "an open day is partial")
        XCTAssertFalse(AtriaCivilDayStepAuthority.isPartial(record: record(coverage: 80_000, complete: true),
                                                            dayLength: day))
        XCTAssertTrue(AtriaCivilDayStepAuthority.isPartial(record: record(coverage: 40_000, complete: true),
                                                           dayLength: day), "strap off half the day")
        // DST: 23 h day, 19 h covered is ≥ 80 %.
        XCTAssertFalse(AtriaCivilDayStepAuthority.isPartial(record: record(coverage: 19 * 3_600, complete: true),
                                                            dayLength: 23 * 3_600))
    }
}
