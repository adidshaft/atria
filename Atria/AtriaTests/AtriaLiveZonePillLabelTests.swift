import XCTest
@testable import Atria

/// Phone 2026-09-02: the Today live pill read "Live · Zone Z0", the word and
/// the letter saying the same thing twice. The zone now carries one compact
/// label in the live-workout grammar ("Below Z1", "Z3 Aerobic") and a spoken
/// one for VoiceOver, and the pill uses both.
final class AtriaLiveZonePillLabelTests: XCTestCase {
    func testRestingZoneReadsBelowZ1() throws {
        let zone = try XCTUnwrap(Metrics.heartRateZone(bpm: 55, rest: 50, max: 190))
        XCTAssertEqual(zone.index, 0)
        XCTAssertEqual(zone.compactLabel, "Below Z1")
        XCTAssertEqual(zone.spokenLabel, "Below zone 1")
    }

    func testAnActiveZoneReadsLetterAndName() throws {
        let zone = try XCTUnwrap(Metrics.heartRateZone(bpm: 150, rest: 50, max: 190))
        XCTAssertGreaterThan(zone.index, 0)
        XCTAssertEqual(zone.compactLabel, "\(zone.shortLabel) \(zone.name)")
        XCTAssertFalse(zone.compactLabel.contains("Zone Z"))
        XCTAssertEqual(zone.spokenLabel, "Zone \(zone.index), \(zone.name)")
    }

    func testTodayPillUsesTheLabels() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("motionStatus.liveStripTitle(zoneLabel: pulse.heartRateZone?.compactLabel"))
        XCTAssertTrue(source.contains("pulse.heartRateZone.map { \" \\($0.spokenLabel).\" } ?? \"\""))
        // 2026-09-27 (owner: no duplicated info on one screen): the Steps
        // tile owns the step count and its stale/held qualifier; the live
        // pill is the pulse only and hides without one.
        XCTAssertFalse(source.contains("\\(pulse.heartRate) bpm\\(liveStepSuffix)"))
        XCTAssertTrue(source.contains("if pulseStore.state.heartRate > 0 {"))
        XCTAssertFalse(source.contains("Live · Zone"))
    }
}
