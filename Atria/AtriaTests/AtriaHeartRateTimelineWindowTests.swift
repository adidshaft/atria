import XCTest
@testable import Atria

/// HR-timeline time-window zoom (2026-07-07, user request: 12h default, zoom
/// in to 1 min, out to 24h). Locks the windowing math and that the merge no
/// longer pre-downsamples away the resolution the tight zoom needs.
final class AtriaHeartRateTimelineWindowTests: XCTestCase {
    private func points(spanHours: Double, count: Int, endingAt end: Date) -> [AtriaHomeModel.HeartRateChartPoint] {
        let span = spanHours * 3600
        return (0..<count).map { index in
            let t = end.addingTimeInterval(-span + span * Double(index) / Double(max(count - 1, 1)))
            return AtriaHomeModel.HeartRateChartPoint(t: t, bpm: 70)
        }
    }

    func testDefaultWindowIsTwelveHours() {
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.defaultWindow, .hour12)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.hour12.seconds, 12 * 3600, accuracy: 0.5)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.min1.seconds, 60, accuracy: 0.5)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.Window.hour24.seconds, 24 * 3600, accuracy: 0.5)
    }

    func testWindowedKeepsOnlyLastTwelveHoursOfDay() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 24, count: 1440, endingAt: end)
        let windowed = AtriaVitalsHeartRateTimeline.windowed(pts, window: .hour12, displayBudget: 10_000)
        XCTAssertTrue(windowed.allSatisfy { $0.t >= end.addingTimeInterval(-12 * 3600) })
        XCTAssertLessThan(windowed.count, pts.count)
        XCTAssertGreaterThan(windowed.count, 600)
    }

    func testWindowedOneMinuteKeepsOnlyLastMinute() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 2, count: 7200, endingAt: end)
        let windowed = AtriaVitalsHeartRateTimeline.windowed(pts, window: .min1, displayBudget: 10_000)
        XCTAssertTrue(windowed.allSatisfy { $0.t >= end.addingTimeInterval(-60) })
        XCTAssertLessThanOrEqual(windowed.count, 62)
        XCTAssertGreaterThan(windowed.count, 0)
    }

    func testWindowedDownsamplesToBudget() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let pts = points(spanHours: 12, count: 5000, endingAt: end)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.windowed(pts, window: .hour12, displayBudget: 200).count, 200)
    }

    func testMergedKeepsFullResolution() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let historical = points(spanHours: 12, count: 720, endingAt: end.addingTimeInterval(-3600))
        let live = points(spanHours: 1, count: 300, endingAt: end)
        let merged = AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: live, historical: historical)
        XCTAssertGreaterThan(merged.count, 180, "must not pre-downsample to 180 or the 1-min zoom loses detail")
        XCTAssertEqual(merged, merged.sorted { $0.t < $1.t })
    }
    func testPinchOutZoomsIn() {
        // anchor 12h (index 7), pinch out 2x -> ~2 steps shorter window (6h, index 5).
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 7, magnification: 2, maxIndex: 8)
        XCTAssertEqual(idx, 5, accuracy: 0.5)
    }

    func testPinchInZoomsOutAndClamps() {
        // anchor 12h, pinch in to 0.5 -> ~2 steps wider (24h, clamped to 8).
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 7, magnification: 0.5, maxIndex: 8)
        XCTAssertEqual(idx, 8, accuracy: 0.01)
    }

    func testPinchClampsAtFloor() {
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 0, magnification: 8, maxIndex: 8)
        XCTAssertEqual(idx, 0, accuracy: 0.01)
    }

    func testNoPinchKeepsAnchor() {
        let idx = AtriaVitalsHeartRateTimeline.windowIndex(fromPinchAnchor: 4, magnification: 1, maxIndex: 8)
        XCTAssertEqual(idx, 4, accuracy: 0.01)
    }

    // downsampledSpan bounds the point count while PRESERVING the time span, so
    // the "last 12h/24h" windows can actually fill (2026-07-08 fix: historical
    // was capped to ~6000 raw ~1 Hz samples ≈ 100 min, so 12h showed ~1.7h).
    func testDownsampledSpanPreservesEndpointsAndBounds() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let dense = points(spanHours: 24, count: 50_000, endingAt: end)
        let thinned = AtriaVitalsHeartRateTimeline.downsampledSpan(dense, maxPoints: 2_500)
        XCTAssertEqual(thinned.count, 2_500)
        XCTAssertEqual(thinned.first?.t, dense.first?.t, "first sample (span start) must be preserved")
        XCTAssertEqual(thinned.last?.t, dense.last?.t, "last sample (span end) must be preserved")
        XCTAssertEqual(thinned, thinned.sorted { $0.t < $1.t }, "must stay time-ordered")
    }

    func testDownsampledSpanIsNoOpWhenAlreadyUnderBudget() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let sparse = points(spanHours: 3, count: 200, endingAt: end)
        XCTAssertEqual(AtriaVitalsHeartRateTimeline.downsampledSpan(sparse, maxPoints: 2_500), sparse)
    }

    // Regression for the actual complaint: 24h of history thinned to 2500 must
    // still let the 12h window reach ~12h back (not the old ~1.7h).
    func testDownsampledSpanStillFillsTwelveHourWindow() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let dense = points(spanHours: 24, count: 50_000, endingAt: end)
        let thinned = AtriaVitalsHeartRateTimeline.downsampledSpan(dense, maxPoints: 2_500)
        let windowed = AtriaVitalsHeartRateTimeline.windowed(thinned, window: .hour12, displayBudget: 400)
        let earliest = windowed.first?.t ?? end
        XCTAssertLessThanOrEqual(earliest.timeIntervalSince(end.addingTimeInterval(-12 * 3600)), 40,
                                 "12h window must reach ~12h back, within one downsample step")
        XCTAssertGreaterThan(windowed.count, 200)
    }
}

