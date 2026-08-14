import XCTest
@testable import Atria

/// GAP-03 — one zone authority: every user-visible zone index derives from
/// heart-rate reserve (restingHR + fraction × HRR), matching the live workout
/// screen, Live Activity, widget, haptics, and the frozen per-workout
/// boundaries. This test failing means a %HRmax path crept back in.
final class AtriaHeartRateZoneConsistencyTests: XCTestCase {
    func testUserVisibleZoneModelMatchesHRRBandsEverywhere() throws {
        let rest = 60
        let maxHR = 190
        // HRR = 130 → boundaries at 125 / 138 / 151 / 164 / 177 bpm.
        let samples = [94, 130, 145, 155, 170, 180]
        let expectedNames = ["Rest", "Warm-up", "Fat burn", "Aerobic", "Anaerobic", "Max"]

        for (expectedIndex, bpm) in samples.enumerated() {
            let metricZone = try XCTUnwrap(Metrics.heartRateZone(bpm: bpm,
                                                                 rest: rest,
                                                                 max: maxHR))
            XCTAssertEqual(metricZone.index, expectedIndex)
            XCTAssertEqual(metricZone.name, expectedNames[expectedIndex])
            XCTAssertEqual(metricZone.index,
                           HRZone.zone(for: bpm, maxHR: maxHR, restingHR: rest).rawValue,
                           "the glance zone and the workout zone must be the same calculation")
        }
    }

    func testZoneBoundariesMatchFrozenWorkoutBoundaryMath() throws {
        let boundaries = try XCTUnwrap(AtriaHRRZoneBoundaries(restingHR: 60, maxHR: 190))

        for zone in HRZone.allCases {
            let lower = boundaries.lowerBPM(for: zone)
            if zone != .rest {
                // The first BPM inside the zone maps back to that zone.
                XCTAssertEqual(Metrics.heartRateZone(bpm: lower, rest: 60, max: 190)?.index,
                               zone.rawValue,
                               "frozen boundary for \(zone.name) must agree with the live zone index")
                // One BPM below the boundary belongs to the zone beneath it.
                XCTAssertEqual(Metrics.heartRateZone(bpm: lower - 1, rest: 60, max: 190)?.index,
                               zone.rawValue - 1)
            }
        }
    }

    func testReserveFractionRemainsAvailableAndConsistent() throws {
        let zone = try XCTUnwrap(Metrics.heartRateZone(bpm: 155, rest: 60, max: 190))

        XCTAssertEqual(zone.index, HRZone.aerobic.rawValue)
        XCTAssertEqual(zone.reserveFraction, 95.0 / 130.0, accuracy: 0.000_001)
    }
}
