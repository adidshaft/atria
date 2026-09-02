import XCTest
@testable import Atria

/// 2026-09-02 accessibility-size screenshot: the ring legend's Sleep chip
/// truncated "No sleep this cycle" to "No sleep this c…" at the one-line
/// contract's 0.6 floor. XXXL is a standard size, so the contract
/// stays through Extra Large and the caption may wrap from XX-Large up.
final class AtriaLegendChipAccessibilityTests: XCTestCase {
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
