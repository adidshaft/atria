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

    func testOverviewRootObservesOnlyProjectedConnectionStatus() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rootStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewTabContent: View"))
        let rootEnd = try XCTUnwrap(source.range(of: "private struct AtriaDisconnectedOverviewHost: View"))
        let root = String(source[rootStart.lowerBound..<rootEnd.lowerBound])

        XCTAssertTrue(root.contains("let statusStore: AtriaHomeModel.StatusStore"))
        XCTAssertTrue(root.contains("@StateObject private var connectionProjection: AtriaOverviewConnectionProjectionStore"))
        XCTAssertFalse(root.contains("@ObservedObject var statusStore"))
        XCTAssertTrue(root.contains("if connectionProjection.status != .connected"))
    }
}

@MainActor
final class AtriaDisconnectedOverviewProjectionStoreTests: XCTestCase {
    private let empty = AtriaDisconnectedOverviewProjectionState(hasSavedData: false,
                                                                  hasTrendHistory: false)

    func testEqualDisconnectedProjectionDoesNotPublish() {
        let projection = AtriaDisconnectedOverviewProjectionStore(state: empty)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(empty))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testRelevantDisconnectedProjectionPublishesExactlyOnce() {
        let projection = AtriaDisconnectedOverviewProjectionStore(state: empty)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }
        let returning = AtriaDisconnectedOverviewProjectionState(hasSavedData: true,
                                                                  hasTrendHistory: true)

        XCTAssertTrue(projection.refresh(returning))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testDisconnectedRootUsesNarrowProjectionAndLeafObservers() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "private struct AtriaDisconnectedOverviewHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "struct AtriaDisconnectedOverviewProjectionState"))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])
        let leafStart = try XCTUnwrap(source.range(of: "private struct AtriaDisconnectedFirstTimePanelHost: View"))
        let leafEnd = try XCTUnwrap(source.range(of: "private struct AtriaDisconnectedOverviewPanel: View"))
        let leaf = String(source[leafStart.lowerBound..<leafEnd.lowerBound])

        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaDisconnectedOverviewProjectionStore"))
        XCTAssertFalse(host.contains("@ObservedObject"))
        XCTAssertTrue(host.contains("projection.hasSavedData"))
        XCTAssertTrue(host.contains("projection.hasTrendHistory"))
        XCTAssertTrue(leaf.contains("@ObservedObject var statusStore"))
        XCTAssertTrue(leaf.contains("@ObservedObject var liveStore"))
        XCTAssertTrue(leaf.contains("@ObservedObject var homeStatsStore"))
        XCTAssertTrue(leaf.contains("@ObservedObject var snapshotStore"))
    }
}
