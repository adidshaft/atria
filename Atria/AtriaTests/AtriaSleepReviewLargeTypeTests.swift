import XCTest
@testable import Atria

/// 2026-09-02 XXXL screenshot: the sleep review card's "Confirm" shrank to
/// "Con…" beside its icon at a third of the card width. From XX-Large up
/// the decorative icon goes and the word stays; the spoken label is
/// unchanged.
final class AtriaSleepReviewLargeTypeTests: XCTestCase {
    func testConfirmDropsItsIconAtLargeType() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct AtriaSleepReviewCard: View {"))
        let card = String(source[start.lowerBound...].prefix(9_000))
        XCTAssertTrue(card.contains("@Environment(\\.dynamicTypeSize) private var reviewDynamicTypeSize"))
        XCTAssertTrue(card.contains("if reviewDynamicTypeSize >= .xxLarge {\n                        Text(\"Confirm\")"))
        XCTAssertTrue(card.contains("Label(\"Confirm\", systemImage: \"checkmark.circle\")"), "the icon stays at standard sizes")
        XCTAssertTrue(card.contains(".accessibilityLabel(isNap ? \"Confirm nap\" : \"Confirm sleep\")"))
        // The header's time range clipped to "12:00 AM - 7:18…" at XXXL too;
        // it follows the same rule.
        let range = try XCTUnwrap(card.range(of: "Text(rangeText)"))
        XCTAssertTrue(String(card[range.lowerBound...].prefix(300)).contains(".lineLimit(reviewDynamicTypeSize >= .xxLarge ? 2 : 1)"))
    }
}
