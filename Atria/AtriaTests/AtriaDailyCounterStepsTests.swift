import XCTest
@testable import Atria

/// Turning the drained strap data into a daily step count.
///
/// The cadence model is structurally blind to normal walking in drained
/// history: rows arrive at ~1.04 Hz (Nyquist 0.52 Hz) while walking runs at
/// 1.7–2.2 Hz. On device a confirmed 21-minute walk carrying 1,457 counter
/// ticks resolved to **0 steps**, and whole days came out at ~1,300.
///
/// The counter does see it, and its scale is measured, not guessed — the
/// counted physical corpus recorded 132 real steps against 155 ticks and then
/// predicted a held-out 136-step walk from 160 ticks at 0.0% error. It is safe
/// as a DAILY total because the same corpus proved the counter is silent at
/// rest ("preceding 60-second rest delta = 0 ticks"), so idle time cannot
/// inflate it.
///
/// The one shape that CAN inflate it is sustained non-gait arm work — the same
/// shape recorded as a physical FAIL in
/// `evidence/2026-07-27-gate4-arm-control-failure` (planted feet, arm
/// swinging, 166 published steps). Those spans are removed from coverage using
/// the user's own workout label.
///
/// Verified against the real pulled shards (2026-08-22 … 2026-08-25):
///
/// | day   | raw ticks | −non-gait | steps | covered |
/// |-------|-----------|-----------|-------|---------|
/// | 08-22 |  7,769    |  7,769    | 6,616 | 18.2 h  |
/// | 08-23 |  4,067    |  4,067    | 3,464 | 16.0 h  |
/// | 08-24 | 12,956    |  8,728    | 7,433 | 21.5 h  |
/// | 08-25 |  4,790    |  4,790    | 4,079 | 11.4 h  |
final class AtriaDailyCounterStepsTests: XCTestCase {

    private typealias Store = AtriaWhoop4MotionTickCompactStore
    private typealias Model = AtriaWhoop4MotionTickStepModel

    private let base = Date(timeIntervalSince1970: 1_787_572_800)

    private func interval(_ from: TimeInterval,
                          _ to: TimeInterval) -> DateInterval {
        DateInterval(start: base.addingTimeInterval(from),
                     end: base.addingTimeInterval(to))
    }

    // MARK: - The measured scale

    func testDailyTotalsMatchTheCountedCorpusScale() {
        // Aug 24: 8,728 gait-candidate ticks -> the owner expected "at least
        // 7-8k" for that day.
        let augustTwentyFour = Model.publishedSteps(
            motionTicks: 8_728,
            validation: Model.physicallyValidatedWhoop4V24
        )
        XCTAssertEqual(augustTwentyFour, 7_433)

        // Aug 22: 7,769 ticks over only 18.2h of coverage.
        let augustTwentyTwo = Model.publishedSteps(
            motionTicks: 7_769,
            validation: Model.physicallyValidatedWhoop4V24
        )
        XCTAssertEqual(augustTwentyTwo, 6_616)
    }

    func testRestPublishesNothingSoIdleTimeCannotInflateADay() {
        XCTAssertEqual(
            Model.publishedSteps(motionTicks: 0,
                                 validation: Model.physicallyValidatedWhoop4V24),
            0
        )
    }

    // MARK: - Non-gait exclusion

    func testAWorkoutInsideTheDayIsCutOutOfStepCoverage() {
        let day = [interval(0, 3_600)]
        let strength = [interval(1_200, 2_400)]
        let result = Store.subtracting(strength, from: day)
        XCTAssertEqual(result, [interval(0, 1_200), interval(2_400, 3_600)],
                       "the strength block must contribute no step coverage")
    }

    func testAWorkoutOverlappingTheDayEdgeTrimsRatherThanDrops() {
        XCTAssertEqual(
            Store.subtracting([interval(-600, 900)], from: [interval(0, 3_600)]),
            [interval(900, 3_600)]
        )
        XCTAssertEqual(
            Store.subtracting([interval(3_000, 9_000)], from: [interval(0, 3_600)]),
            [interval(0, 3_000)]
        )
    }

    func testAWorkoutCoveringTheWholeDayLeavesNoStepCoverage() {
        XCTAssertTrue(
            Store.subtracting([interval(-10, 4_000)],
                              from: [interval(0, 3_600)]).isEmpty
        )
    }

    func testOverlappingWorkoutsAreMergedBeforeSubtracting() {
        let result = Store.subtracting(
            [interval(600, 1_800), interval(1_200, 2_400)],
            from: [interval(0, 3_600)]
        )
        XCTAssertEqual(result, [interval(0, 600), interval(2_400, 3_600)])
    }

    func testNoExclusionsLeavesCoverageExactlyAsItWas() {
        let day = [interval(0, 3_600), interval(7_200, 9_000)]
        XCTAssertEqual(Store.subtracting([], from: day), day)
    }

    // MARK: - Which activities can produce footfalls

    func testSeatedAndUpperBodyActivitiesAreExcluded() {
        for type in [AtriaWorkoutActivityType.strength,
                     .powerlifting, .cycling, .spin, .rowing, .swimming,
                     .yoga, .pilates, .meditation, .elliptical,
                     .iceSkating, .skiing, .climbing] {
            XCTAssertFalse(type.producesFootfalls,
                           "\(type.rawValue) cannot produce footfalls")
        }
    }

    func testWalkingFamilyActivitiesAreKept() {
        for type in [AtriaWorkoutActivityType.walking,
                     .running, .hiking, .dogWalking, .trackAndField,
                     .hiit, .basketball, .football, .tennis] {
            XCTAssertTrue(type.producesFootfalls,
                          "\(type.rawValue) must keep contributing steps")
        }
    }

    func testUnknownActivitiesDefaultToCountingRatherThanErasing() {
        // Conservative by design: an unlisted activity should under-exclude
        // (small overcount) rather than silently erase real walking.
        XCTAssertTrue(AtriaWorkoutActivityType.other.producesFootfalls)
        XCTAssertTrue(AtriaWorkoutActivityType.sport.producesFootfalls)
    }

    // MARK: - Wiring

    func testTheDailyReadTakesTheLargerOfCadenceAndCounter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Atria/AtriaWhoop4MotionTickCompactStore.swift"
            )
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("steps: max(estimate?.steps ?? 0, counterSteps)"),
            "cadence still wins where it can resolve; the counter carries the "
                + "day where 1 Hz history makes cadence unrecoverable"
        )
        XCTAssertTrue(source.contains("excludedIntervals: [DateInterval] = []"),
                      "exclusion must default to empty")
    }

    func testTheDailyCallerSuppliesNonGaitWindows() throws {
        let sessions = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sessions.contains("excludedIntervals: nonGaitWindows"))
        XCTAssertTrue(sessions.contains(").producesFootfalls else { return nil }"),
                      "the exclusion list is built from the footfall classifier")
    }
}
