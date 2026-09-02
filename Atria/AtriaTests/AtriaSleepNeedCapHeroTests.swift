import XCTest
@testable import Atria

/// Device 2026-09-02: a week of fragmented nights pinned the debt adder at
/// its maximum and the need at the 10 h ceiling, so "100% of need" read as a
/// need that never changes. The ledger behind "Show details" already says
/// "Capped"; the Sleep detail hero now says it where the number is.
final class AtriaSleepNeedCapHeroTests: XCTestCase {
    func testMaximumDebtPinsNeedAtTheCeilingAndFlagsTheClamp() {
        let capped = AtriaSleepBudget.sleepNeedComponents(baseHours: 8, yesterdayStrain: 0,
                                                          debtHours: 8, sameDayNapHours: 0)
        XCTAssertEqual(capped.totalHours, 10, accuracy: 0.001)
        XCTAssertTrue(capped.isClamped, "8 h base + 4 h debt adder exceeds the ceiling")

        let free = AtriaSleepBudget.sleepNeedComponents(baseHours: 8, yesterdayStrain: 0,
                                                        debtHours: 0, sameDayNapHours: 0)
        XCTAssertEqual(free.totalHours, 8, accuracy: 0.001)
        XCTAssertFalse(free.isClamped)
    }

    func testSleepHeroSaysCappedOnlyWhenTheNeedIsClamped() throws {
        let overview = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        let start = try XCTUnwrap(overview.range(of: "private var sleepHeroState"))
        let end = try XCTUnwrap(overview.range(of: "private var strainContributorRows",
                                               range: start.upperBound..<overview.endIndex))
        let body = String(overview[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(")?.isClamped ?? false"))
        XCTAssertTrue(body.contains("capped ? \"\\($0)% of need \\u{00b7} need capped\" : \"\\($0)% of need\""))
        XCTAssertTrue(body.contains("yesterdayStrain: yesterdayStrainForLatestNight"),
                      "the hero still reads yesterday's strain, never today's partial number")
    }
}
