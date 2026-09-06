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
        XCTAssertTrue(source.contains("pulse.heartRateZone.map { \"Live · \\($0.compactLabel)\" } ?? \"Live\""))
        XCTAssertTrue(source.contains("pulse.heartRateZone.map { \" \\($0.spokenLabel).\" } ?? \"\""))
        XCTAssertFalse(source.contains("Live · Zone"))
    }
}
