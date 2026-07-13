import XCTest
@testable import Atria

final class AtriaHeartRateZoneConsistencyTests: XCTestCase {
    func testUserVisibleZoneModelMatchesWorkoutAndLiveActivityMaxHRBands() throws {
        let rest = 60
        let maxHR = 190
        let samples = [94, 95, 115, 134, 153, 172]
        let expectedNames = ["Rest", "Warm-up", "Fat burn", "Aerobic", "Anaerobic", "Max"]

        for (expectedIndex, bpm) in samples.enumerated() {
            let metricZone = try XCTUnwrap(Metrics.heartRateZone(bpm: bpm,
                                                                 rest: rest,
                                                                 max: maxHR))
            XCTAssertEqual(metricZone.index, expectedIndex)
            XCTAssertEqual(metricZone.name, expectedNames[expectedIndex])
            XCTAssertEqual(metricZone.index, HRZone.zone(for: bpm, maxHR: maxHR).rawValue)
        }
    }

    func testReserveFractionRemainsAvailableWithoutChangingVisibleZone() throws {
        let zone = try XCTUnwrap(Metrics.heartRateZone(bpm: 134, rest: 60, max: 190))

        XCTAssertEqual(zone.index, HRZone.aerobic.rawValue)
        XCTAssertEqual(zone.reserveFraction, 74.0 / 130.0, accuracy: 0.000_001)
    }
}
