import XCTest
@testable import Atria

/// 2026-09-02: a learning weekly-plan target shows what it has counted so
/// far ("1 of 3 nights") on its gauge, the shape every other learning state
/// uses, instead of the word "Learning" over an empty gauge. The minimum is
/// stored with the target so plans decode and the row needs no constants.
final class AtriaWeeklyPlanLearningProgressTests: XCTestCase {
    private func target(kind: WeeklyPlanTarget.Kind, remaining: Int?, needed: Int?) -> WeeklyPlanTarget {
        WeeklyPlanTarget(id: kind.rawValue, kind: kind, title: "t", detail: "d",
                         goal: 4, current: 0,
                         learningNightsRemaining: remaining, learningNightsNeeded: needed)
    }

    func testBedtimeLearningCountsNightsRecorded() {
        XCTAssertEqual(target(kind: .bedtimeConsistency, remaining: 3, needed: 3).learningProgressText, "0 of 3 nights")
        XCTAssertEqual(target(kind: .bedtimeConsistency, remaining: 1, needed: 3).learningProgressText, "2 of 3 nights")
        XCTAssertEqual(target(kind: .bedtimeConsistency, remaining: 1, needed: 3).learningProgress, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testRHRLearningCountsMornings() {
        XCTAssertEqual(target(kind: .rhrInRange, remaining: 2, needed: 3).learningProgressText, "1 of 3 mornings")
    }

    func testTargetsWithoutTheStoredMinimumFallBackToTheWord() {
        // Plans saved before the minimum was stored: learning, but no count.
        let legacy = target(kind: .bedtimeConsistency, remaining: 2, needed: nil)
        XCTAssertTrue(legacy.isLearning)
        XCTAssertNil(legacy.learningProgressText)
        XCTAssertEqual(legacy.learningProgress, 0)
        XCTAssertNil(target(kind: .bedtimeConsistency, remaining: nil, needed: 3).learningProgressText,
                     "a real target is not learning and never shows a learning count")
    }

    func testPlanBuildersStoreTheMinimumWithLearningTargets() throws {
        let plan = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaWeeklyPlan.swift"), encoding: .utf8)
        XCTAssertTrue(plan.contains("learningNightsNeeded: minimumBedtimeNights)"))
        XCTAssertTrue(plan.contains("learningNightsNeeded: minimumTrustedRHRDays)"))

        let today = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(today.contains("Text(target.isLearning ? (target.learningProgressText ?? \"Learning\") : target.progressText)"))
        XCTAssertTrue(today.contains("Gauge(value: target.isLearning ? target.learningProgress : target.progress)"))
    }
}
