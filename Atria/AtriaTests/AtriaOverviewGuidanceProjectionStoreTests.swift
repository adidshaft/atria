import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaOverviewGuidanceProjectionStoreTests: XCTestCase {
    private func state(sleepRevision: Int = 0,
                       rollupRevision: Int = 0) -> AtriaOverviewGuidanceProjectionState {
        AtriaOverviewGuidanceProjectionState(
            sleepHistory: .empty,
            sleepHistoryRevision: sleepRevision,
            dailyRollupHistory: [],
            dailyRollupHistoryRevision: rollupRevision,
            weeklyPlan: WeeklyPlan(rollups: [],
                                   now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        )
    }

    func testEqualGuidanceProjectionDoesNotPublish() {
        let initial = state()
        let projection = AtriaOverviewGuidanceProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testRelevantGuidanceProjectionPublishesExactlyOnce() {
        let projection = AtriaOverviewGuidanceProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refresh(state(sleepRevision: 1)))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testUnrelatedBroadSessionSignalDoesNotPublishGuidance() {
        let store = SessionStore()
        let projection = AtriaOverviewGuidanceProjectionStore(store: store)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        store.objectWillChange.send()

        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testGuidanceHostUsesNarrowProjectionInsteadOfSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewGuidanceSectionHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "struct AtriaOverviewGuidanceProjectionState"))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertFalse(host.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaOverviewGuidanceProjectionStore"))
        XCTAssertTrue(host.contains("projection.sleepHistory"))
        XCTAssertTrue(host.contains("projection.dailyRollupHistory"))
        XCTAssertTrue(host.contains("projection.weeklyPlan"))
    }
}
