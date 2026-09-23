import XCTest
@testable import Atria

/// 2026-09-02 light-mode audit: Today, the weekly report, Vitals, Journal
/// and Activity all held up because every identity hue carries a darker
/// light-mode variant. This pins that: a new `electric` hue without a
/// light variant would read as neon on cream.
final class AtriaAdaptiveHuePinTests: XCTestCase {
    func testEveryIdentityHueHasALightVariant() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/Metrics.swift"), encoding: .utf8)
        let hueLines = source.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("static let electric") }
        XCTAssertGreaterThanOrEqual(hueLines.count, 9, "the nine identity hues are declared here")
        for line in hueLines {
            XCTAssertTrue(line.contains("adaptive(dark:") && line.contains("light:"),
                          "identity hue without a light variant: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}
