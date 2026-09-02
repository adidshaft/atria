import XCTest
@testable import Atria

/// 2026-09-02: the Strain detail hero centred a hand-set 48pt value while
/// the Resting HR, HRV, respiratory and sleep heroes sat left on the shared
/// 56pt value component. The Strain hero now shares that anatomy, with its
/// target gauge beneath.
final class AtriaStrainHeroAnatomyTests: XCTestCase {
    func testStrainHeroUsesTheSharedLeftAlignedAnatomy() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "// Strain hero anatomy (2026-09-02)"))
        let window = String(source[start.lowerBound...].prefix(1_400))
        XCTAssertTrue(window.contains("VStack(alignment: .leading, spacing: 12) {"))
        XCTAssertTrue(window.contains("AtriaMetricHeroValueText(text: displayValue, tint: score == nil ? Color.secondary : tint)"))
        XCTAssertTrue(window.contains(".font(AtriaDesignTokens.Typography.metricLabel)"), "the state caption uses the template's token")
        let gauge = String(source[start.lowerBound...].prefix(2_600))
        XCTAssertTrue(gauge.contains("Text(\"21\")"), "the target gauge's end labels remain")
        XCTAssertFalse(source.contains(".font(.system(size: 48, weight: .bold, design: .rounded))"),
                       "no hand-set 48pt hero value remains in the overview sections")
    }
}
