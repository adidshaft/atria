import XCTest
@testable import Atria

/// 2026-09-02: the weekly and monthly report headlines were a fixed 26pt
/// that did not scale with Dynamic Type, while the page-title token already
/// covered exactly this role (a page's own headline under an inline nav
/// bar). Both sheets now take the token; the live-workout timer keeps its
/// own fixed size because it is a value, not a headline.
final class AtriaReportHeadlineTokenTests: XCTestCase {
    func testBothReportHeadlinesUseThePageTitleToken() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("size: 26"), "no fixed 26pt headline remains in the report sections")
        let headline = "Text(heroText)\n                            // Report headline (2026-09-02)"
        XCTAssertEqual(source.components(separatedBy: headline).count - 1, 2, "weekly and monthly")
        XCTAssertEqual(source.components(separatedBy: ".font(AtriaDesignTokens.Typography.pageTitle)").count - 1, 2)
    }
}
