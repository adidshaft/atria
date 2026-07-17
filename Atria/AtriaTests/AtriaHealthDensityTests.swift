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
        XCTAssertTrue(source.contains(".frame(height: 0.5)"),
                      "Metric tile separators must have an explicit horizontal hairline height")
    }
}
