import XCTest
@testable import Atria

/// Pure-logic coverage for the 2026-07-05 Today-surface additions: the
/// shared under/optimal/over zone tints and the daily HR-zone tile text.
final class AtriaTodayTileLogicTests: XCTestCase {

    // MARK: zoneTint bands

    func testSleepZoneBands() {
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 70), Metrics.electricYellow)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 84.9), Metrics.electricYellow)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 85), Metrics.electricGreen)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 104), Metrics.electricGreen)
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 110), Metrics.electricGreen)
        // Oversleep reads cool, never alarming.
        XCTAssertEqual(AtriaTriRing.zoneTint(.sleep, percent: 125), Metrics.electricStrain)
    }

    func testStrainZoneBands() {
        XCTAssertEqual(AtriaTriRing.zoneTint(.strain, percent: 40), Metrics.electricStrain)
        XCTAssertEqual(AtriaTriRing.zoneTint(.strain, percent: 90), Metrics.electricGreen)
        XCTAssertEqual(AtriaTriRing.zoneTint(.strain, percent: 110), Metrics.electricGreen)
        XCTAssertEqual(AtriaTriRing.zoneTint(.strain, percent: 120), Metrics.electricYellow)
        XCTAssertEqual(AtriaTriRing.zoneTint(.strain, percent: 155), Metrics.electricRed)
    }

    func testRecoveryZoneMatchesExistingBands() {
        XCTAssertEqual(AtriaTriRing.zoneTint(.recovery, percent: 20), Metrics.recoveryColor(20))
        XCTAssertEqual(AtriaTriRing.zoneTint(.recovery, percent: 50), Metrics.recoveryColor(50))
        XCTAssertEqual(AtriaTriRing.zoneTint(.recovery, percent: 80), Metrics.recoveryColor(80))
    }

    // MARK: TodayHRZoneMinutes text

    func testHRZonesNoWearIsHonest() {
        let empty = TodayHRZoneMinutes.empty
        XCTAssertEqual(empty.valueText, "--")
        XCTAssertEqual(empty.detailText, "No wear today")
        XCTAssertEqual(empty.accessibilityDetailText, "No heart rate zone data today.")
    }

    func testHRZonesRestingOnlyDay() {
        let resting = TodayHRZoneMinutes(restMinutes: 300, warmupMinutes: 12,
                                         fatBurnMinutes: 0, aerobicMinutes: 0,
                                         anaerobicMinutes: 0, maxMinutes: 0,
                                         hasSamples: true)
        XCTAssertEqual(resting.activeMinutes, 0)
        XCTAssertEqual(resting.valueText, "0m")
        XCTAssertEqual(resting.detailText, "Resting")
    }

    func testHRZonesSplitOmitsZeroBuckets() {
        let day = TodayHRZoneMinutes(restMinutes: 200, warmupMinutes: 30,
                                     fatBurnMinutes: 22, aerobicMinutes: 15,
                                     anaerobicMinutes: 0, maxMinutes: 2,
                                     hasSamples: true)
        XCTAssertEqual(day.activeMinutes, 39)
        XCTAssertEqual(day.valueText, "39m")
        XCTAssertEqual(day.detailText, "Z2 22 · Z3 15 · Z5 2")
        XCTAssertTrue(day.accessibilityDetailText.contains("22 minutes in zone 2"))
        XCTAssertFalse(day.accessibilityDetailText.contains("zone 4"))
    }
}
