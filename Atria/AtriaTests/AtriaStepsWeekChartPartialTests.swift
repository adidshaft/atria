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

/// Live R10 off under the power policy (strap below its battery floor): the
/// Today count comes only from the strap's history bank. It must read as a
/// partial count from history, never as zero and never as a finished day.
final class AtriaStepsLivePausedPresentationTests: XCTestCase {
    private func presentation(count: Int?, completeness: AtriaDailyStepPresentation.Completeness,
                              source: AtriaDailyStepPresentation.Source,
                              note: AtriaLiveDataNote?) -> AtriaDailyStepPresentation {
        var p = AtriaDailyStepPresentation(day: Date(timeIntervalSince1970: 1_790_000_000),
                                           count: count, completeness: completeness, source: source,
                                           isValidated: true, capturedAt: nil, coverageFraction: 0.4)
        p.livePauseNote = note
        return p
    }

    func testPausedPartialCountIsLabelledAsHistoryNotZero() {
        let p = presentation(count: 2_310, completeness: .partial, source: .verifiedCanonical,
                             note: .liveMotionPausedStrapBattery(12))
        XCTAssertEqual(p.valueText, "2310")
        XCTAssertEqual(p.detailText, "Live steps paused · strap 12% · from strap history")
        XCTAssertEqual(p.motionAvailabilityFootnote?.hasPrefix("Live steps are paused"), true)
    }

    func testPausedWithNothingDrainedYetIsDashesNotZero() {
        let p = presentation(count: 0, completeness: .partial, source: .verifiedCanonical,
                             note: .liveMotionPausedStrapBattery(9))
        XCTAssertEqual(p.valueText, "--", "an undrained bank is not a zero-step day")
        let none = presentation(count: nil, completeness: .unavailable, source: .none,
                                note: .liveMotionPausedLowPowerMode)
        XCTAssertEqual(none.detailText, "Live steps paused · Low Power Mode · from strap history")
    }

    func testCatchUpNoteAndNoNoteKeepTheExistingCopy() {
        let base = presentation(count: 2_310, completeness: .partial, source: .verifiedCanonical, note: nil)
        let catchingUp = presentation(count: 2_310, completeness: .partial, source: .verifiedCanonical,
                                      note: .catchingUpHistory)
        XCTAssertEqual(catchingUp.detailText, base.detailText)
        XCTAssertEqual(catchingUp.motionAvailabilityFootnote, base.motionAvailabilityFootnote)
        // A complete, verified day never gets the paused wording.
        let complete = presentation(count: 9_000, completeness: .complete, source: .verifiedCanonical,
                                    note: .liveMotionPausedStrapBattery(12))
        XCTAssertEqual(complete.detailText, "Verified complete day")
    }
}
