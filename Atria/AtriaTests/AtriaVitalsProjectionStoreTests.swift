import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaVitalsProjectionStoreTests: XCTestCase {
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
