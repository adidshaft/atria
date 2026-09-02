import XCTest
@testable import Atria

/// 2026-09-02 accessibility-size screenshot: the ring legend's Sleep chip
/// truncated "No sleep this cycle" to "No sleep this c…" at the one-line
/// contract's 0.6 floor. XXXL is a standard size, so the contract
/// stays through Extra Large and the caption may wrap from XX-Large up.
final class AtriaLegendChipAccessibilityTests: XCTestCase {
    /// The ring centre's state ("Save sleep to score") truncated the same
    /// way at XXXL; it follows the same rule inside the ring.
    func testRingCentreStateWrapsFromXXLargeUp() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTriRing.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "Text(centerState)"))
        let window = String(source[start.lowerBound...].prefix(360))
        XCTAssertTrue(window.contains(".multilineTextAlignment(.center)"))
        XCTAssertTrue(window.contains(".lineLimit(legendDynamicTypeSize >= .xxLarge ? 2 : 1)"))
    }

    /// Three chips in a row truncated "Rec…" in the onboarding preview at
    /// XXXL; from XX-Large up the legend stacks its chips as full rows.
    func testLegendStacksFromXXLargeUp() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTriRing.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "if legendDynamicTypeSize >= .xxLarge {"))
        let window = String(source[start.lowerBound...].prefix(900))
        XCTAssertTrue(window.contains("VStack(spacing: 8) {"), "chips stack from XX-Large up")
        XCTAssertTrue(window.contains("} else {"))
        XCTAssertTrue(window.contains("HStack(spacing: 8) {"), "the row stays for standard sizes")
    }

    func testCaptionWrapsFromXXLargeUp() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTriRing.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var legendDynamicTypeSize"))
        let start = try XCTUnwrap(source.range(of: "Text(showsLegendDetail(metric) ? metric.detail : \" \")"))
        let window = String(source[start.lowerBound...].prefix(400))
        XCTAssertTrue(window.contains(".lineLimit(legendDynamicTypeSize >= .xxLarge ? 2 : 1)"))
        XCTAssertTrue(window.contains(".minimumScaleFactor(0.6)"), "the standard-size floor is unchanged")
    }
}
