import XCTest
@testable import Atria

/// Owner 2026-09-02: the ring's day pager was centred, and its right arrow
/// ran under the share button that overlays the hero's top-trailing corner.
/// The pager now sits at the leading edge; the action cluster keeps the
/// trailing corner to itself.
final class AtriaRingDayBrowserAlignmentTests: XCTestCase {
    func testPagerRowIsLeadingAlignedBelowTheActionOverlay() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        let nextDay = try XCTUnwrap(source.range(of: ".accessibilityLabel(\"Next day\")\n        }\n"))
        let after = String(source[nextDay.upperBound...].prefix(420))
        XCTAssertTrue(after.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
                      "the pager row hugs the leading edge")
        XCTAssertTrue(source.contains(".overlay(alignment: .topTrailing) { topActionMenu }"),
                      "the action cluster still overlays the trailing corner")
    }
}
