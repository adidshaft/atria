import XCTest
@testable import Atria

/// 2026-09-03 widget-sync pass: the timeline scheduled an entry at every
/// freshness, cycle and identity boundary, but only while that boundary fell
/// inside the fifteen-minute reload it requests. `.after()` is a request
/// WidgetKit grants from a budget, so a late reload left a stale cycle total
/// or a yesterday value on screen. Entries are pre-rendered and cost nothing
/// to carry, so boundaries up to four hours out now ride along and the face
/// corrects itself on time even when the reload slips.
final class AtriaWidgetTimelineHorizonTests: XCTestCase {
    private var source: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        }
    }

    func testBoundariesRideBeyondTheRequestedReload() throws {
        let s = try source
        XCTAssertTrue(s.contains("let entryHorizon = now.addingTimeInterval(4 * 60 * 60)"))
        XCTAssertEqual(s.components(separatedBy: "< entryHorizon").count - 1, 4,
                       "freshness, strain cycle, steps cycle and identity boundaries all ride")
        XCTAssertFalse(s.contains("staleAt < refreshAt"),
                       "a boundary must not be dropped just because the reload is requested sooner")
    }

    func testTheRequestedReloadCadenceIsUnchanged() throws {
        let s = try source
        XCTAssertTrue(s.contains("let refreshAt = now.addingTimeInterval(15 * 60)"),
                      "carrying later entries must not slow the reload request")
        XCTAssertTrue(s.contains("completion(Timeline(entries: entries, policy: .after(refreshAt)))"))
    }

    /// The live-sensor coalescing that keeps WidgetKit within budget is the
    /// other half of snappiness and stays exactly as it was.
    func testLiveSensorCoalescingIsUnchanged() {
        XCTAssertEqual(WidgetSnapshotPublisher.liveSensorTimelineReloadMinimumInterval, 60)
        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadMaximumInterval, 15 * 60)
    }
}
