import XCTest

final class AtriaHealthDensityTests: XCTestCase {
    func testHealthMonitorUsesCompactGridsWithAccessibleLargeTypeFallback() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
            .appendingPathComponent("AtriaHealthScreen.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "LazyVGrid(columns: monitorGridColumns").count - 1,
            2,
            "Readiness and body metrics should stay grouped into compact grids"
        )
        XCTAssertTrue(source.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains("layout: .compactTile"))
        XCTAssertTrue(source.contains(".accessibilityLabel(accessibilityLabelText)"))
        XCTAssertTrue(source.contains("if let rangeText { parts.append(\"\\(rangeText).\") }"),
                      "Compact presentation must keep honest range evidence in VoiceOver")
        XCTAssertTrue(source.contains("if let hint { parts.append(hint) }"),
                      "Compact presentation must keep meaningful warning context in VoiceOver")
        XCTAssertFalse(source.contains("Divider().opacity(0.55)"),
                       "An unconstrained Divider in an overlay can become vertical and cut through metric tiles")
        // 2026-08-01 Vitals IA split migration: the shared-surface hairline
        // separators (".frame(height: 0.5)") are gone — each compact tile is
        // now its own flat card with a chevron press affordance, opening the
        // metric's existing detail sheet. Pin that pattern instead.
        XCTAssertFalse(source.contains(".frame(height: 0.5)"),
                       "Tiles are distinct flat cards now; a hairline separator would mean the shared-surface layout regressed")
        XCTAssertTrue(source.contains("private var pressableChevron: some View"),
                      "Each metric family card must keep its visible press affordance")
        XCTAssertTrue(source.contains("in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))"),
                      "Tile cards take their radius from the design-token scale")
        XCTAssertTrue(source.contains("onTap: { metricDetail = .recovery }"),
                      "Family cards open the existing metric detail sheets, not the education sheet")
    }
}
