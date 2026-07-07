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
}
