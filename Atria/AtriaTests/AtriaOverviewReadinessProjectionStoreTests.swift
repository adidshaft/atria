import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaOverviewReadinessProjectionStoreTests: XCTestCase {
    func testNoOpRefreshDoesNotPublish() {
        let sessionStore = SessionStore()
        let projection = AtriaOverviewReadinessProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertEqual(projection.refreshAttemptCount, 0)
        XCTAssertFalse(projection.refresh())
        XCTAssertEqual(projection.refreshAttemptCount, 1)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testUnrelatedBroadStoreSignalDoesNotPublishOrBuildSnapshot() {
        let sessionStore = SessionStore()
        let projection = AtriaOverviewReadinessProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        sessionStore.objectWillChange.send()

        XCTAssertEqual(projection.refreshAttemptCount, 0)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testUnchangedDashboardRevisionPathSkipsSnapshotConstruction() {
        let sessionStore = SessionStore()
        let projection = AtriaOverviewReadinessProjectionStore(store: sessionStore)

        XCTAssertFalse(projection.refreshForDashboardRevision())
        XCTAssertEqual(projection.refreshAttemptCount, 0)
    }

    func testReadinessHostUsesRetainedProjectionInsteadOfSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewReadinessSectionHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "private func moveMetric", range: hostStart.lowerBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertFalse(host.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaOverviewReadinessProjectionStore"))
        XCTAssertTrue(host.contains("let projection = projectionStore.state"))
        XCTAssertTrue(host.contains("dailyRollupHistory: projection.dailyRollupHistory"))
        XCTAssertTrue(host.contains("confirmedWorkouts: projection.confirmedWorkouts"))
        XCTAssertTrue(host.contains("sleepHistory: debugSleepHistorySnapshot ?? projection.sleepHistory"))
        XCTAssertTrue(host.contains("pendingSleepReview: debugSleepHistorySnapshot == nil"))
        XCTAssertFalse(host.contains("dailyRollupHistory: store.dailyRollupHistory"))
        XCTAssertFalse(host.contains("confirmedWorkouts: store.confirmedWorkouts"))

        XCTAssertTrue(source.contains("store.$pendingSleepReviewNightForUI.dropFirst()"),
                      "the retained readiness projection must refresh the ring when a review becomes available")
        XCTAssertTrue(source.contains("pendingReview: pendingSleepReview"),
                      "the ring and sleep glance must use the same pending review projection")
    }
}

@MainActor
final class AtriaOverviewConnectionProjectionStoreTests: XCTestCase {
    func testEqualConnectionStatusDoesNotPublish() {
        let projection = AtriaOverviewConnectionProjectionStore(status: .disconnected)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(.disconnected))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testConnectionTransitionPublishesExactlyOnce() {
        let projection = AtriaOverviewConnectionProjectionStore(status: .disconnected)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refresh(.connected))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    /// REPLACED 2026-08-27. `AtriaOverviewTabContent` was the app's SECOND
    /// orphaned tab root — zero construction sites, exactly like
    /// AtriaVitalsTabContent. The Today tab renders `overviewContent` in
    /// AtriaHomeView, which builds AtriaTodayScreen directly and never touched
    /// this struct. Removing it orphaned AtriaDisconnectedOverviewHost, which
    /// orphaned AtriaDisconnectedOverviewProjectionStore and its State — the
    /// whole chain is gone, along with the behavioural tests that exercised a
    /// publish-gate nothing could publish to.
    ///
    /// The invariants those tests encoded are good ones (a root observes a
    /// narrow projection, not the whole status store; an equal projection does
    /// not publish). They are enforced where they matter by
    /// AtriaOverviewReadinessProjectionStoreTests above, whose store IS live.
    func testTheDeadOverviewTabRootStaysRemoved() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaOverviewSections.swift"),
            encoding: .utf8
        )
        for dead in ["struct AtriaOverviewTabContent",
                     "AtriaDisconnectedOverviewHost",
                     "AtriaDisconnectedOverviewProjectionStore",
                     "AtriaDisconnectedOverviewProjectionState"] {
            XCTAssertFalse(source.contains(dead),
                           "\(dead) had no reachable consumer")
        }

        // The live root must still exist, so this cannot pass by the file
        // having been emptied.
        XCTAssertTrue(source.contains("AtriaOverviewReadinessProjectionStore"),
                      "the readiness projection is live and must remain")
    }
}
