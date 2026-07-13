import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaSleepSyncProjectionStoreTests: XCTestCase {
    func testUnchangedStateDoesNotPublish() {
        let initial = state()
        let projection = AtriaSleepSyncProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)

        withExtendedLifetime(cancellable) {}
    }

    func testEachRenderedInputPublishesOnceAndEqualityGatesRepeats() {
        let projection = AtriaSleepSyncProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        let latest = state(hasLatestSleep: true)
        XCTAssertTrue(projection.refresh(latest))
        XCTAssertFalse(projection.refresh(latest))

        let candidates = state(hasLatestSleep: true, candidateCount: 1)
        XCTAssertTrue(projection.refresh(candidates))
        XCTAssertFalse(projection.refresh(candidates))

        let pending = state(hasLatestSleep: true, candidateCount: 1, hasPendingReview: true)
        XCTAssertTrue(projection.refresh(pending))
        XCTAssertFalse(projection.refresh(pending))
        XCTAssertEqual(publications, 3)

        withExtendedLifetime(cancellable) {}
    }

    func testHostUsesOnlyNarrowSleepPublishers() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let stateStart = try XCTUnwrap(source.range(of: "struct AtriaSleepSyncProjectionState: Equatable"))
        let cardStart = try XCTUnwrap(
            source.range(of: "private struct AtriaSleepSyncNeededCard: View", range: stateStart.upperBound..<source.endIndex)
        )
        let chain = String(source[stateStart.lowerBound..<cardStart.lowerBound])

        XCTAssertTrue(chain.contains("@StateObject private var projectionStore: AtriaSleepSyncProjectionStore"))
        XCTAssertTrue(chain.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(chain.contains("store.$pendingSleepReviewNightForUI"))
        XCTAssertTrue(chain.contains("guard next != state else { return false }"))
        XCTAssertFalse(chain.contains("@ObservedObject var store: SessionStore"))
        XCTAssertFalse(chain.contains("store.$dashboardRevision"))
        XCTAssertFalse(chain.contains("store.objectWillChange"))
    }

    private func state(hasLatestSleep: Bool = false,
                       candidateCount: Int = 0,
                       hasPendingReview: Bool = false) -> AtriaSleepSyncProjectionState {
        AtriaSleepSyncProjectionState(
            hasLatestSleep: hasLatestSleep,
            candidateCount: candidateCount,
            hasPendingReview: hasPendingReview
        )
    }
}
