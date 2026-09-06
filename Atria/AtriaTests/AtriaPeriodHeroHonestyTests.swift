import XCTest
@testable import Atria

/// 2026-09-03, from seeded renders of the recovery sheet. Two things in the
/// detail template said one thing while the number beside them said another:
///
///  * on Week and Month the hero shows `periodHeroText`, an aggregate, but the
///    state word under it still described a single day — Recovery read
///    "59% / Moderate" on a month whose latest day was 38%, and Sleep put a
///    30-day mean under last night's "98% of need". Strain alone said
///    "Period average"; every other metric now does too.
///  * an excluded recovery contributor carries weight 0 and a placeholder
///    zScore of 0, which the directional grammar read as "at or above
///    baseline" — so the HRV row said "Above baseline" next to its own value
///    of "HRV unavailable".
final class AtriaPeriodHeroHonestyTests: XCTestCase {
    private var source: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        }
    }

    func testAggregateHeroesSayTheyAreAnAverage() throws {
        let source = try source
        XCTAssertTrue(source.contains("private func periodHeroState(_ dayState: @autoclosure () -> String) -> String {"))
        XCTAssertTrue(source.contains("guard range != .day, state != \"Learning\" else { return state }"),
                      "the Day hero is untouched and Learning still describes calibration")
        XCTAssertTrue(source.contains("return \"Period average\""))
    }

    /// Every metric whose hero value comes from `periodHeroText`, plus the two
    /// that compute their own aggregate, must go through the wrapper. Strain
    /// is deliberately absent: its own hero state already says it.
    func testEveryAggregatingHeroIsWrapped() throws {
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

    /// The number itself must keep coming from the aggregate — the label was
    /// the defect, not the value.
    func testHeroValueStillAggregatesOnMultiDayRanges() throws {
        let source = try source
        XCTAssertTrue(source.contains("if range != .day, let summary {\n            return summary.averageText"))
        XCTAssertTrue(source.contains("return recoverySummaryForSelectedPeriod?.averageRaw"))
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
