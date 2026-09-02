import XCTest
@testable import Atria

/// 2026-09-02: with the strap disconnected and nothing scored, the Vitals
/// Live header showed "--" beside its chevron while the canvas below already
/// said "Strap disconnected". The value now hides under the same guard the
/// subtitle uses; the chevron remains as the tap affordance.
final class AtriaVitalsCurrentReadingHeaderTests: XCTestCase {
    func testDisconnectedEmptyHeaderHidesTheValueButKeepsTheChevron() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"), encoding: .utf8)
        let guardLine = "if !(projection.presentation == .empty && !isConnected) {"
        XCTAssertEqual(source.components(separatedBy: guardLine).count - 1, 2,
                       "subtitle and value share one declutter predicate")
        let start = try XCTUnwrap(source.range(of: "Spacer(minLength: 8)\n                // Same declutter as the subtitle"))
        let window = String(source[start.lowerBound...].prefix(1800))
        XCTAssertTrue(window.contains(guardLine))
        XCTAssertTrue(window.contains("Text(stressPresentation.numericScore.map {"))
        XCTAssertTrue(window.contains("if onOpenStressDetail != nil {"),
                      "the chevron is outside the guard and stays tappable")
    }
}
