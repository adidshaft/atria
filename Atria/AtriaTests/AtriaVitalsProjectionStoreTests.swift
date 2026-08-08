import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaVitalsProjectionStoreTests: XCTestCase {
    func testVitalsStressTimelineEndsAtNowAndKeepsRestoredCollectionGaps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history: [AtriaStressMonitorStore.StressHistoryPoint] = [
            .init(t: now.addingTimeInterval(-13 * 3_600), activation: 0.2, level: .low),
            .init(t: now.addingTimeInterval(-11 * 3_600), activation: 0.3, level: .low),
            .init(t: now.addingTimeInterval(-11 * 3_600 + 60), activation: 0.4, level: .medium),
            .init(t: now.addingTimeInterval(-5 * 3_600), activation: 0.8, level: .high),
            .init(t: now.addingTimeInterval(1), activation: 0.5, level: .medium),
        ]

        let points = AtriaVitalsStressTimelineProjection.points(
            history: history,
            referenceDate: now
        )

        XCTAssertEqual(points.map(\.reading.date), [
            now.addingTimeInterval(-11 * 3_600),
            now.addingTimeInterval(-11 * 3_600 + 60),
            now.addingTimeInterval(-5 * 3_600),
        ])
        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testVitalsStressCopyNeverCallsAGappedTimelineContinuous() {
        XCTAssertTrue(AtriaVitalsStressTimelineCopy.gapNote.contains(
            "no stress score was recorded"
        ))
        XCTAssertFalse(AtriaVitalsStressTimelineCopy.gapNote.contains(
            "strap was not collecting"
        ))
        XCTAssertFalse(AtriaVitalsStressTimelineCopy.accessibilityLabel
            .localizedCaseInsensitiveContains("continuous"))
        XCTAssertTrue(AtriaVitalsStressTimelineCopy.accessibilityLabel.contains(
            "Collection gaps remain blank"
        ))
    }

    func testNoOpRefreshDoesNotPublish() {
        let sessionStore = SessionStore()
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertEqual(projection.refreshAttemptCount, 0,
                       "Seeded @Published values must not replay into full projection rebuilds")
        XCTAssertFalse(projection.refresh())
        XCTAssertEqual(projection.refreshAttemptCount, 1)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testUnrelatedBroadStoreSignalDoesNotPublishVitalsState() {
        let sessionStore = SessionStore()
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        sessionStore.objectWillChange.send()

        XCTAssertEqual(publications, 0)
        XCTAssertFalse(projection.refresh())
        withExtendedLifetime(cancellable) {}
    }

    func testUnchangedDashboardRevisionPathSkipsSnapshotConstruction() {
        let sessionStore = SessionStore()
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)

        XCTAssertFalse(projection.refreshForDashboardRevision())
        XCTAssertEqual(projection.refreshAttemptCount, 0,
                       "Unrelated dashboard changes must not traverse Vitals arrays or baseline samples")
    }

    func testRelevantProfileChangeRefreshesProjectedMaxHeartRate() async {
        let sessionStore = SessionStore()
        let originalProfile = sessionStore.profile
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)
        let nextMeasuredMax = originalProfile.measuredMaxHR == 211 ? 210 : 211
        let updated = expectation(description: "Vitals projection receives committed profile")
        let cancellable = projection.$state
            .dropFirst()
            .filter { $0.maxHeartRate == nextMeasuredMax }
            .prefix(1)
            .sink { _ in updated.fulfill() }

        sessionStore.updateProfile {
            $0.maxHRSource = .measured
            $0.measuredMaxHR = nextMeasuredMax
        }

        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(projection.state.maxHeartRate, nextMeasuredMax)
        XCTAssertFalse(projection.refresh())

        sessionStore.updateProfile { $0 = originalProfile }
        withExtendedLifetime(cancellable) {}
    }
}
