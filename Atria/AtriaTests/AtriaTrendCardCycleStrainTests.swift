import XCTest
@testable import Atria

/// 2026-09-03: the Vitals trend card plotted strain from
/// `makeOverviewTrendPoints`, which buckets TRIMP by CIVIL day, while the
/// strain detail sheet one tap away plots the physiological cycle
/// (`physiologicalCycleStrainByDisplayDay`, the 2026-08-30 rule). The same
/// date could therefore carry two different strain numbers on two surfaces —
/// widest for a shifted sleeper, whose evening work lands in the next civil
/// day but the same cycle.
final class AtriaTrendCardCycleStrainTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private func day(_ d: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: d, hour: hour))!
    }

    private func point(_ d: Int, strain: Double?, restingHR: Int? = 55, hrv: Int? = 60) -> AtriaTrendPoint {
        AtriaTrendPoint(id: UUID(), date: day(d), restingHR: restingHR, strain: strain, hrv: hrv)
    }

    func testCycleValueReplacesTheCivilBucketForThatDay() {
        let points = [point(1, strain: 4.0), point(2, strain: 9.0)]
        let cycle = [calendar.startOfDay(for: day(2)): 13.5]

        let applied = points.applyingCycleStrain(cycle, calendar: calendar)

        XCTAssertEqual(applied[0].strain, 4.0, "a day with no cycle row keeps its civil value")
        XCTAssertEqual(applied[1].strain, 13.5)
    }

    func testOnlyStrainMoves() {
        let original = point(2, strain: 9.0, restingHR: 51, hrv: 73)
        let applied = [original].applyingCycleStrain([calendar.startOfDay(for: day(2)): 2.5],
                                                     calendar: calendar)

        XCTAssertEqual(applied[0].strain, 2.5)
        XCTAssertEqual(applied[0].restingHR, 51, "overnight readings already key to their own night")
        XCTAssertEqual(applied[0].hrv, 73)
        XCTAssertEqual(applied[0].id, original.id)
        XCTAssertEqual(applied[0].date, original.date)
    }

    func testAnEmptyMapLeavesEverySeriesUntouched() {
        let points = [point(1, strain: 4.0), point(2, strain: nil), point(3, strain: 11.2)]
        XCTAssertEqual(points.applyingCycleStrain([:], calendar: calendar), points)
    }

    /// A day the cycle series says was empty must be able to CLEAR a civil
    /// bucket, not just raise it — otherwise strain the cycle rule excluded
    /// would survive on this card alone.
    func testACycleZeroOverridesANonZeroCivilBucket() {
        let applied = [point(2, strain: 9.0)]
            .applyingCycleStrain([calendar.startOfDay(for: day(2)): 0], calendar: calendar)
        XCTAssertEqual(applied[0].strain, 0)
        XCTAssertNil(applied[0].value(for: .strain),
                     "and a zero plots as no point, exactly as the card already treats zero")
    }

    /// Points are keyed by the start of their own day, the same lookup the
    /// detail sheet uses, so an afternoon-stamped point still finds its row.
    func testLookupIsByStartOfDayNotExactTimestamp() {
        let afternoon = AtriaTrendPoint(id: UUID(), date: day(2, hour: 16),
                                        restingHR: 55, strain: 9.0, hrv: 60)
        let applied = [afternoon].applyingCycleStrain([calendar.startOfDay(for: day(2)): 6.25],
                                                      calendar: calendar)
        XCTAssertEqual(applied[0].strain, 6.25)
    }

    func testVitalsHostAppliesTheMapAndMovesItsCacheKeyWithIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("?? state.overviewTrendPoints.applyingCycleStrain(cycleStrainByDisplayDay)"))
        XCTAssertTrue(source.contains("? state.overviewTrendPointsRevision &+ cycleStrainRevision"),
                      "the prepared-series cache keys on the revision, so it must move with the map")
        XCTAssertTrue(source.contains("lhs.cycleStrainRevision == rhs.cycleStrainRevision && lhs.state == rhs.state"),
                      "equality stays O(1) rather than walking the dictionary each render")
    }

    func testHealthScreenFeedsTheHostFromTheStore() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHealthScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("cycleStrainByDisplayDay: store.physiologicalCycleStrainByDisplayDay,"))
        XCTAssertTrue(source.contains("cycleStrainRevision: store.dailyRollupHistoryRevision)"),
                      "the store publishes the map in lockstep with that revision")
    }
}
