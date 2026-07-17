import XCTest
@testable import Atria

final class AtriaWeeklyPlanRenderingTests: XCTestCase {
    func testLoadedPlanIsReusedWithoutRereadingItsWeekFile() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var mondayComponents = DateComponents()
        mondayComponents.yearForWeekOfYear = 2027
        mondayComponents.weekOfYear = 12
        mondayComponents.weekday = 2
        mondayComponents.hour = 9
        let monday = try XCTUnwrap(calendar.date(from: mondayComponents))
        let tuesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: monday))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-weekly-plan-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = WeeklyPlan(rollups: [], now: monday, calendar: calendar)
        let replacement = WeeklyPlan(rollups: [], now: tuesday, calendar: calendar)
        XCTAssertNotEqual(first.generatedAt, replacement.generatedAt)

        let writer = WeeklyPlanStore(directory: directory)
        writer.save(first)

        let subject = WeeklyPlanStore(directory: directory)
        XCTAssertEqual(subject.plan(isoYear: first.isoYear, isoWeek: first.isoWeek), first)

        writer.save(replacement)
        XCTAssertEqual(subject.plan(isoYear: first.isoYear, isoWeek: first.isoWeek), first,
                       "a loaded week should be served from memory instead of rereading its JSON file")
    }

    func testTodayBodyReadsWeeklyPlanFromProjectedState() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("weeklyPlan = store.currentWeeklyPlan()"))
        XCTAssertTrue(source.contains("sessionProjectionStore.state.weeklyPlan"))
        XCTAssertTrue(source.contains("publisher(for: .NSCalendarDayChanged)"))
        XCTAssertFalse(source.contains("WeeklyPlanStore().currentPlan(rollups: highlightRollups)"))
    }
}
