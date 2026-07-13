import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaActivityProjectionStoreTests: XCTestCase {
    private func state(sleepRevision: Int = 1,
                       workoutsRevision: Int = 1,
                       rollupsRevision: Int = 1,
                       reviewFingerprint: String = "none") -> AtriaHomeModel.ActivityState {
        AtriaHomeModel.ActivityState(sleepHistorySnapshot: .empty,
                                     sleepHistorySnapshotRevision: sleepRevision,
                                     pendingSleepReview: nil,
                                     confirmedWorkouts: [],
                                     confirmedWorkoutsRevision: workoutsRevision,
                                     workoutReviewCandidate: nil,
                                     activityDetections: [],
                                     historySnapshotRevision: 0,
                                     reviewFingerprint: reviewFingerprint,
                                     dailyRollupHistory: [],
                                     dailyRollupHistoryRevision: rollupsRevision)
    }

    func testNoOpAndNonRelevantRefreshesDoNotPublish() {
        let initial = state()
        let store = AtriaHomeModel.ActivityStore(state: initial)
        var publications = 0
        let cancellable = store.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(store.refresh(initial))
        XCTAssertFalse(store.refresh(state()))
        XCTAssertEqual(publications, 0)

        withExtendedLifetime(cancellable) {}
    }

    func testRelevantRevisionsPublishExactlyOnceEach() {
        let store = AtriaHomeModel.ActivityStore(state: state())
        var publications = 0
        let cancellable = store.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(store.refresh(state(sleepRevision: 2)))
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(store.refresh(state(sleepRevision: 2, workoutsRevision: 2)))
        XCTAssertEqual(publications, 2)
        XCTAssertTrue(store.refresh(state(sleepRevision: 2,
                                          workoutsRevision: 2,
                                          rollupsRevision: 2)))
        XCTAssertEqual(publications, 3)
        XCTAssertTrue(store.refresh(state(sleepRevision: 2,
                                          workoutsRevision: 2,
                                          rollupsRevision: 2,
                                          reviewFingerprint: "pending-sleep")))
        XCTAssertEqual(publications, 4)

        withExtendedLifetime(cancellable) {}
    }
}
