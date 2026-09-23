import XCTest
@testable import Atria

/// 2026-09-02: the "Wear it tonight" page said the recovery score "kicks in
/// after 3–4 nights". The engine scores recovery from the first saved sleep
/// on a provisional baseline, and trusted baselines take fourteen nights,
/// the count the metric heroes already show. The page now says both.
final class AtriaOnboardingExpectationsTests: XCTestCase {
    func testExpectationsMatchTheEngine() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOnboardingFlow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("detail: \"Your first sleep review to confirm, and a first recovery score.\")"))
        XCTAssertTrue(source.contains("title: \"Over the first two weeks\","))
        XCTAssertTrue(source.contains("detail: \"Scores firm up as Atria learns your baseline.\","))
        XCTAssertFalse(source.contains("detail: \"Your recovery score kicks in"), "no claim the engine does not make")
        XCTAssertEqual(PersonalBaseline.trustedMinimumSamples, 14, "two weeks is the trusted-baseline count")
    }
}
