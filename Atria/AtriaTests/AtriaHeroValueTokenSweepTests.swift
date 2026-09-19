import XCTest
@testable import Atria

/// 2026-09-02 sweep: the recovery ring's centre value (40pt) and the Vitals
/// heart-rate reading (38pt) were the last hand-set hero values on the main
/// screens. Both take the card hero token, which scales with Dynamic Type;
/// the remaining fixed sizes are icons, chart axis labels, the shared hero
/// component itself, and the deliberately giant live pulse.
final class AtriaHeroValueTokenSweepTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/\(file)"), encoding: .utf8)
    }

    func testRingCentreValueUsesTheToken() throws {
        let overview = try source("AtriaOverviewSections.swift")
        let start = try XCTUnwrap(overview.range(of: "// Ring centre value (2026-09-02)"))
        XCTAssertTrue(String(overview[start.lowerBound...].prefix(260)).contains(".font(AtriaDesignTokens.Typography.cardHeroValue)"))
        XCTAssertFalse(overview.contains(".font(.system(size: 40, weight: .bold, design: .rounded))"))
    }

    func testHeartRateReadingUsesTheToken() throws {
        let vitals = try source("AtriaVitalsCollectionSections.swift")
        let start = try XCTUnwrap(vitals.range(of: "// Reading value (2026-09-02)"))
        XCTAssertTrue(String(vitals[start.lowerBound...].prefix(260)).contains(".font(AtriaDesignTokens.Typography.cardHeroValue)"))
        XCTAssertFalse(vitals.contains(".font(.system(size: 38, weight: .bold, design: .rounded))"))
    }
}
