import XCTest
@testable import Atria

/// Overnight HRV/recovery/RHR must keep one number across Today, Day, Week,
/// and Month. Week/Month charts still plot the window; the hero is the latest
/// sleep-backed night in that window, not the average (device 2026-09-17:
/// Today 77 ms, Week averaged 45 and 77 into 61 ms).
///
/// Strain still names a period average because it is accumulated load, not a
/// morning score. An excluded recovery contributor must not claim a direction.
final class AtriaPeriodHeroHonestyTests: XCTestCase {
    private var source: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        }
    }

    func testOvernightHeroesNameTheLatestNight() throws {
        let source = try source
        XCTAssertTrue(source.contains("private func periodHeroState(_ dayState: @autoclosure () -> String) -> String {"))
        XCTAssertTrue(source.contains("guard range != .day, state != \"Learning\" else { return state }"),
                      "the Day hero is untouched and Learning still describes calibration")
        XCTAssertTrue(source.contains("return \"Latest night\""))
    }

    /// Every overnight metric whose hero value comes from `periodHeroText`
    /// goes through the latest-night wrapper. Strain keeps its own average.
    func testEveryOvernightHeroIsWrapped() throws {
        let source = try source
        for state in ["periodHeroState(recoveryHeroState)",
                      "periodHeroState(hrvBand == nil ? \"Learning\" : \"Typical\")",
                      "periodHeroState(restingBand == nil ? \"Learning\" : \"Typical\")",
                      "periodHeroState(respiratoryBand == nil ? \"Learning\" : \"Typical\")",
                      "periodHeroState(sleepHeroState)",
                      "periodHeroState(sleepPerformanceHeroState)"] {
            XCTAssertTrue(source.contains("heroState: \(state),"), "unwrapped hero: \(state)")
        }
        XCTAssertTrue(source.contains("heroState: strainHeroState,"),
                      "strain already says Period average inside its own state")
        XCTAssertTrue(source.contains("return \"Period average\"\n        }\n        if latest >= target + 1"),
                      "and that is where it says it")
    }

    func testOvernightHeroValueIsTheLatestNightNotTheAverage() throws {
        let source = try source
        XCTAssertTrue(source.contains("if let summary {\n            return summary.latestText"))
        XCTAssertTrue(source.contains("return recoverySummaryForSelectedPeriod?.latestRaw"))
        XCTAssertFalse(source.contains("return summary.averageText"))
        XCTAssertFalse(source.contains("return recoverySummaryForSelectedPeriod?.averageRaw"))
    }

    func testExcludedContributorDoesNotClaimADirection() throws {
        let source = try source
        XCTAssertTrue(source.contains("guard contributor.weight > 0 else { return \"Not included in this score\" }"))
        let start = try XCTUnwrap(source.range(of: "private func contributorNote("))
        let body = String(source[start.lowerBound...].prefix(900))
        let guardIndex = try XCTUnwrap(body.range(of: "guard contributor.weight > 0"))
        let switchIndex = try XCTUnwrap(body.range(of: "switch contributor.kind {"))
        XCTAssertTrue(guardIndex.lowerBound < switchIndex.lowerBound,
                      "the exclusion check runs before any directional wording")
        XCTAssertTrue(body.contains("\"Above baseline\" : \"Below baseline\""),
                      "a real HRV reading still reports its direction")
    }
}
