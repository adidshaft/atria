import XCTest
@testable import Atria

/// 2026-09-02: the sleep review card's provenance line said "HR/RR
/// estimate", engineering shorthand for the beat-to-beat channel. The
/// wearer reads it as a heart-rate estimate; the motion verdict and the nap
/// suffix are unchanged.
final class AtriaSleepReviewCaptionTests: XCTestCase {
    func testProvenanceLineNamesTheEstimateInPlainWords() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("? \"Heart-rate estimate · motion unverified · saves as a nap\""))
        XCTAssertTrue(source.contains(": \"Heart-rate estimate · motion unverified\""))
        XCTAssertFalse(source.contains("\"HR/RR estimate"), "no engineering shorthand on the card")
    }
}
