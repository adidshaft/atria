import XCTest
@testable import Atria

/// 2026-09-02: the Customize sheet's reorder footer told sighted readers
/// about VoiceOver rotor actions that VoiceOver users already find. One
/// instruction stays beside the Edit button it refers to.
final class AtriaCustomizeFooterTests: XCTestCase {
    func testReorderFooterIsOneInstruction() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaCustomizeSheet.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Text(\"Tap Edit, then drag rows by the handle.\")"))
        XCTAssertFalse(source.contains("VoiceOver also offers"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Reorder metric cards\")"), "the Edit button keeps its spoken label")
    }
}
