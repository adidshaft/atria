import XCTest
@testable import Atria

/// 2026-09-02: the Journal's drinks stepper showed its count at a hand-set
/// 48pt that ignored Dynamic Type. It is a card hero value and takes that
/// token; the Journal's remaining fixed sizes are icons and the emoji scale.
final class AtriaJournalStepperTokenTests: XCTestCase {
    func testDrinksCountUsesTheCardHeroToken() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaJournalTab.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "Text(\"\\(drinks)\")"))
        let window = String(source[start.lowerBound...].prefix(420))
        XCTAssertTrue(window.contains(".font(AtriaDesignTokens.Typography.cardHeroValue)"))
        XCTAssertTrue(window.contains(".monospacedDigit()"))
        XCTAssertFalse(source.contains(".font(.system(size: 48, weight: .bold, design: .rounded))"),
                       "no hand-set 48pt value remains in the Journal")
    }
}
