import XCTest
@testable import Atria

final class AtriaMetricAuthorityConsistencyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return value
    }

    private func date(_ day: Int, _ hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: day,
            hour: hour
        ))!
    }

    func testTodaySleepDeltaUsesThePriorSleepDayNotArrayPosition() {
        let current = DailyRollupStoreEntry(
            day: date(29),
            sleepPerformance: 74,
            calendar: calendar
        )
        let prior = DailyRollupStoreEntry(
            day: date(28),
            sleepPerformance: 61,
            calendar: calendar
        )
        let older = DailyRollupStoreEntry(
            day: date(27),
            sleepPerformance: 92,
            calendar: calendar
        )

        XCTAssertEqual(
            AtriaTodaySleepDeltaAuthority.previousPerformance(
                before: date(29),
                rollups: [current, prior, older],
                calendar: calendar
            ),
            61
        )
        XCTAssertEqual(
            AtriaTodaySleepDeltaAuthority.previousPerformance(
                before: date(29),
                rollups: [prior, older],
                calendar: calendar
            ),
            61,
            "the comparison remains correct while today's rollup is still settling"
        )
    }

    func testAdaptiveNeedChangesPerformanceWhenPriorStrainIsPresent() {
        let withoutStrain = AtriaSleepBudget.sleepNeed(
            baseHours: 8,
            yesterdayStrain: nil,
            debtHours: 0,
            sameDayNapHours: 0
        )
        let withStrain = AtriaSleepBudget.sleepNeed(
            baseHours: 8,
            yesterdayStrain: 15,
            debtHours: 0,
            sameDayNapHours: 0
        )

        XCTAssertEqual(withoutStrain, 8, accuracy: 0.001)
        XCTAssertEqual(withStrain, 8.62, accuracy: 0.001)
        XCTAssertEqual(
            AtriaSleepBudget.performancePercent(slept: 7.5, needed: withoutStrain),
            94
        )
        XCTAssertEqual(
            AtriaSleepBudget.performancePercent(slept: 7.5, needed: withStrain),
            87
        )
    }

    func testSleepSurfacesUsePriorStrainAndFreshAuthority() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sources = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let home = try String(
            contentsOf: sources.appendingPathComponent("AtriaHomeView.swift"),
            encoding: .utf8
        )
        let overview = try String(
            contentsOf: sources.appendingPathComponent("AtriaOverviewSections.swift"),
            encoding: .utf8
        )
        let today = try String(
            contentsOf: sources.appendingPathComponent("AtriaTodayScreen.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(home.contains("let sleepProjection = sleepIsConfirmedNight"))
        XCTAssertTrue(home.contains("sleep.map(adaptiveSleepProjection)"))
        XCTAssertTrue(home.contains("adaptiveSleepProjection("))
        XCTAssertTrue(home.contains("yesterdayStrain: yesterdayStrain"))
        XCTAssertFalse(home.contains(
            "sleep?.durationHours / max(sleepGoalHours"
        ))

        let planStart = try XCTUnwrap(overview.range(
            of: "private var sleepPlanTargetHours"
        ))
        let planEnd = try XCTUnwrap(overview.range(
            of: "private var sleepPlanTargetText",
            range: planStart.upperBound..<overview.endIndex
        ))
        XCTAssertTrue(
            overview[planStart.lowerBound..<planEnd.lowerBound]
                .contains("yesterdayStrain: yesterdayStrainForLatestSleep")
        )

        let heroStart = try XCTUnwrap(overview.range(
            of: "private var sleepHeroState"
        ))
        let heroEnd = try XCTUnwrap(overview.range(
            of: "private var strainContributorRows",
            range: heroStart.upperBound..<overview.endIndex
        ))
        XCTAssertTrue(
            overview[heroStart.lowerBound..<heroEnd.lowerBound]
                .contains("yesterdayStrain: yesterdayStrainForLatestNight")
        )

        XCTAssertTrue(today.contains(
            "let current = sleepPerformancePercent"
        ))
        XCTAssertTrue(today.contains(
            "let previous = previousSleepPerformancePercent"
        ))
        XCTAssertFalse(today.contains(
            "let current = latestRollup?.sleepPerformance"
        ))
    }
}
