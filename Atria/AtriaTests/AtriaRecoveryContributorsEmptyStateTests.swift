import XCTest
@testable import Atria

/// 2026-09-02: with no scored recovery, the contributors card stacked a
/// heading that presumed a score ("Why today's recovery landed here"), an
/// empty notice, and a closing paragraph about how recovery is blended —
/// three pieces of prose for "nothing yet". The empty state now has a
/// neutral heading and the notice alone; the populated card is unchanged.
final class AtriaRecoveryContributorsEmptyStateTests: XCTestCase {
    func testEmptyStateHasNeutralHeadingAndNoClosingParagraph() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Text(\"Why today's recovery landed here\")"),
                      "the populated heading is unchanged")
        XCTAssertTrue(source.contains("if contributors.isEmpty {\n                        Text(\"Recovery contributors\")"),
                      "an empty card does not claim a recovery landed anywhere")
        let start = try XCTUnwrap(source.range(of: "Text(\"Recovery blends HRV, resting HR, sleep, and respiration against your personal baseline.\")"))
        let before = String(source[..<start.lowerBound].suffix(220))
        XCTAssertTrue(before.contains("if !contributors.isEmpty {"),
                      "the closing paragraph renders only with contributors to explain")
    }
}
