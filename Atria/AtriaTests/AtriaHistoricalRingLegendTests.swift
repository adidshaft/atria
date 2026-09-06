import XCTest
@testable import Atria

/// 2026-09-02: browsing a past day, four of the five ring legends captioned
/// a real value with "Saved day". Recovery now reads its own state word,
/// strain its shared band name, and the overnight metrics say which night
/// they belong to; the no-value captions are unchanged.
final class AtriaHistoricalRingLegendTests: XCTestCase {
    func testStrainBandNamesAreTheSharedVocabulary() {
        XCTAssertEqual(Metrics.strainBandName(7.5), "Light")
        XCTAssertEqual(Metrics.strainBandName(12), "Moderate")
        XCTAssertEqual(Metrics.strainBandName(16), "High")
        XCTAssertEqual(Metrics.strainBandName(19.5), "All Out")
    }

    func testPastDayLegendsCaptionRealValues() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func historicalRingMetric"))
        let body = String(source[start.lowerBound...].prefix(5_200))
        XCTAssertTrue(body.contains("detail: percent.map { recoveryState(percent: $0) } ?? \"No saved score\","))
        XCTAssertTrue(body.contains("detail: strain.map { Metrics.strainBandName($0) } ?? \"No saved value\","))
        XCTAssertEqual(body.components(separatedBy: ": \"that night\",").count - 1, 2, "HRV and RHR")
        XCTAssertFalse(body.contains(": \"Saved day\","), "no filler caption remains under a value")
    }
}
