import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaTrendProjectionStoreTests: XCTestCase {
    private func state(points: [AtriaTrendPoint] = [],
                       revision: Int = 0,
                       restingHR: Int? = nil,
                       events: [AtriaChartEvent] = []) -> AtriaTrendChartProjectionState {
        AtriaTrendChartProjectionState(points: points,
                                       pointsRevision: revision,
                                       baselineRestingHR: restingHR,
                                       events: events)
    }

    func testEqualTrendProjectionDoesNotPublish() {
        let initial = state()
        let projection = AtriaTrendChartProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testRelevantTrendProjectionPublishesExactlyOnce() {
        let projection = AtriaTrendChartProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }
        let points = [AtriaTrendPoint(id: UUID(),
                                      date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                      restingHR: 58,
                                      strain: 8.2,
                                      hrv: 61)]

        XCTAssertTrue(projection.refresh(state(points: points, revision: 1, restingHR: 58)))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testTrendHostUsesNarrowProjectionInsteadOfWholeSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTrendChart.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewTrendChartHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "enum AtriaTrendRange", range: hostStart.lowerBound..<source.endIndex))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertTrue(host.contains("let store: SessionStore"))
        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaTrendChartProjectionStore"))
        XCTAssertFalse(host.contains("@ObservedObject var store"))
        XCTAssertTrue(host.contains("store.$overviewTrendPoints"))
        XCTAssertTrue(host.contains("store.$baseline"))
        XCTAssertTrue(host.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(host.contains("store.confirmedWorkoutsRevision != self.confirmedWorkoutsRevision"))
    }
}
