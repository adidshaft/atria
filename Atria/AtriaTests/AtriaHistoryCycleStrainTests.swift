import XCTest
@testable import Atria

/// 2026-09-03: History listed each day's civil rollup strain while the
/// strain chart one tap away plots `physiologicalCycleStrainByDisplayDay`.
/// The same date could therefore carry two numbers — widest for a shifted
/// sleeper, whose evening work lands in the next civil day but the same
/// cycle.
final class AtriaHistoryCycleStrainTests: XCTestCase {
    func testCycleStrainOverridesTheCivilBucketOnTheSameDay() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_788_307_200))
        let rollup = DailyRollupStoreEntry(day: day, tzOffsetMinutes: 0, recovery: 62, strain: 8)
        let model = AtriaHistoryModel.make(rollups: [rollup],
                                           workouts: [],
                                           sleeps: [],
                                           cycleStrainByDisplayDay: [rollup.day: 16.5])
        XCTAssertEqual(model.days.count, 1)
        XCTAssertEqual(model.days.first?.strain, 16.5)
        XCTAssertEqual(model.days.first?.recovery, 62, "only strain moves")
    }

    func testAnEmptyCycleMapLeavesCivilStrainUntouched() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_788_307_200))
        let rollup = DailyRollupStoreEntry(day: day, tzOffsetMinutes: 0, recovery: 62, strain: 8)
        let overlaid = AtriaHistoryModel.make(rollups: [rollup],
                                              workouts: [],
                                              sleeps: [],
                                              cycleStrainByDisplayDay: [:])
        let civil = AtriaHistoryModel.make(rollups: [rollup], workouts: [], sleeps: [])
        XCTAssertEqual(overlaid, civil)
        XCTAssertEqual(civil.days.first?.strain, 8)
    }

    func testACycleZeroOverridesANonZeroCivilBucket() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_788_307_200))
        let rollup = DailyRollupStoreEntry(day: day, tzOffsetMinutes: 0, strain: 9)
        let model = AtriaHistoryModel.make(rollups: [rollup],
                                           workouts: [],
                                           sleeps: [],
                                           cycleStrainByDisplayDay: [rollup.day: 0])
        XCTAssertEqual(model.days.first?.strain, 0)
    }

    func testHealthAndTheDaySheetFeedTheCycleMap() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let health = try String(contentsOf: app.appendingPathComponent("AtriaHealthScreen.swift"),
                                encoding: .utf8)
        XCTAssertTrue(health.contains("reviewCandidateDays: historyReviewCandidateDays,\n            cycleStrainByDisplayDay: store.physiologicalCycleStrainByDisplayDay"),
                      "Vitals History must overlay the same cycle series the strain chart uses")
        let history = try String(contentsOf: app.appendingPathComponent("AtriaHistorySection.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(history.contains("WeeklyReport.applyingCycleStrain(rollups,"),
                      "the History model uses the same overlay as the weekly report")
        XCTAssertTrue(history.contains("cycleStrainByDisplayDay: input.cycleStrainByDisplayDay"),
                      "the off-main projection must carry the map")
        let overview = try String(contentsOf: app.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(overview.contains("cycleStrainByDisplayDay: preparationBaseInput.cycleStrainByDisplayDay"),
                      "double-tap on a strain bar must open a day sheet with the same number")
    }
}
