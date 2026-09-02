import XCTest
@testable import Atria

/// 2026-09-02: the Health Monitor's Resting HR tile captioned a reading
/// with "current cycle", which said nothing. Against at least three
/// baseline mornings it now reads the distance from usual in the highlight
/// row's grammar; a thinner baseline keeps the old caption.
final class AtriaRestingHRTileCaptionTests: XCTestCase {
    func testCaptionReadsTheDistanceFromUsual() {
        XCTAssertEqual(AtriaHealthScreen.restingHeartRateDeltaCaption(value: 54, mean: 56.4, count: 5), "2 below usual")
        XCTAssertEqual(AtriaHealthScreen.restingHeartRateDeltaCaption(value: 59, mean: 56.4, count: 5), "3 above usual")
        XCTAssertEqual(AtriaHealthScreen.restingHeartRateDeltaCaption(value: 56, mean: 56.4, count: 5), "same as usual")
    }

    func testThinBaselineNeverPosesAsUsual() {
        XCTAssertNil(AtriaHealthScreen.restingHeartRateDeltaCaption(value: 54, mean: 56.4, count: 2))
    }

    func testTileFallsBackToTheProjectionDetail() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHealthScreen.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func restingHeartRateDetail(live: AtriaHealthMonitorLiveProjection) -> String {"))
        let window = String(source[start.lowerBound...].prefix(900))
        XCTAssertTrue(window.contains("let stats = vitalsStore.state.baseline.restingStats,"))
        XCTAssertTrue(window.contains("Self.restingHeartRateDeltaCaption(value: value, mean: stats.mean, count: stats.count)"))
        XCTAssertTrue(window.contains("return projection.restingHeartRateDetail"), "the projection's own caption remains the fallback")
    }
}
