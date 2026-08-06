import XCTest
@testable import Atria

@MainActor
final class AtriaVitalsHistoryProjectionStoreTests: XCTestCase {
    func testPersistedDailyMetricHistoryCanPublishBeforeSessionDerivedResult() {
        let loadGeneration = 0

        XCTAssertTrue(SessionStore.shouldPublishPersistedDailyMetricHistory(
            loadGeneration: loadGeneration,
            currentGeneration: 0
        ))

        // The later session-derived publish is authoritative regardless of the
        // persisted load having completed first.
        XCTAssertFalse(SessionStore.shouldPublishPersistedDailyMetricHistory(
            loadGeneration: loadGeneration,
            currentGeneration: 1
        ))
    }

    func testPersistedDailyMetricHistoryCannotOverwriteSessionDerivedResult() {
        let loadGeneration = 0
        let generationAfterSessionDerivedPublish = 1

        XCTAssertFalse(SessionStore.shouldPublishPersistedDailyMetricHistory(
            loadGeneration: loadGeneration,
            currentGeneration: generationAfterSessionDerivedPublish
        ))
    }

    func testRequestRetainsPreviousImmutableProjection() {
        let readyKey = key(rollup: 1)
        let ready = AtriaHistoryProjection(key: readyKey, model: model(sessionsCount: 7))
        let store = AtriaVitalsHistoryProjectionStore(projection: ready)

        XCTAssertTrue(store.begin(key(rollup: 2)))
        XCTAssertEqual(store.projection, ready)
    }

    func testOnlyLatestRequestedRevisionCanPublish() {
        let store = AtriaVitalsHistoryProjectionStore()
        let firstKey = key(rollup: 1)
        let latestKey = key(rollup: 2)

        XCTAssertTrue(store.begin(firstKey))
        XCTAssertTrue(store.begin(latestKey))
        XCTAssertFalse(store.accept(model(sessionsCount: 1), for: firstKey))
        XCTAssertEqual(store.projection, .empty)
        XCTAssertTrue(store.accept(model(sessionsCount: 2), for: latestKey))
        XCTAssertEqual(store.projection.key, latestKey)
        XCTAssertEqual(store.projection.model.sessionsCount, 2)
    }

    func testPublishedAndPendingRevisionAreNotRequestedAgain() {
        let publishedKey = key(rollup: 1)
        let pendingKey = key(rollup: 2)
        let store = AtriaVitalsHistoryProjectionStore(
            projection: AtriaHistoryProjection(key: publishedKey, model: model(sessionsCount: 1))
        )

        XCTAssertFalse(store.begin(publishedKey))
        XCTAssertTrue(store.begin(pendingKey))
        XCTAssertFalse(store.begin(pendingKey))
    }

    func testCancelledRequestCanBeRetriedWithoutClearingPreviousProjection() {
        let publishedKey = key(rollup: 1)
        let cancelledKey = key(rollup: 2)
        let ready = AtriaHistoryProjection(key: publishedKey, model: model(sessionsCount: 1))
        let store = AtriaVitalsHistoryProjectionStore(projection: ready)

        XCTAssertTrue(store.begin(cancelledKey))
        store.cancel(cancelledKey)

        XCTAssertEqual(store.projection, ready)
        XCTAssertTrue(store.begin(cancelledKey))
    }

    func testEachSourceRevisionChangesProjectionKey() {
        XCTAssertNotEqual(key(), key(rollup: 2))
        XCTAssertNotEqual(key(), key(workouts: 2))
        XCTAssertNotEqual(key(), key(sleep: 2))
        XCTAssertNotEqual(key(), key(detections: 2))
        XCTAssertNotEqual(key(), key(reviewCandidateDays: [
            AtriaHistoryReviewCandidateDay(day: Date(timeIntervalSince1970: 1_800_000_000), count: 1)
        ]))
    }

    private func key(rollup: Int = 1,
                     workouts: Int = 1,
                     sleep: Int = 1,
                     detections: Int = 1,
                     reviewCandidateDays: [AtriaHistoryReviewCandidateDay] = []) -> AtriaHistoryRevisionKey {
        AtriaHistoryRevisionKey(rollup: rollup,
                                workouts: workouts,
                                sleep: sleep,
                                detections: detections,
                                reviewCandidateDays: reviewCandidateDays)
    }

    private func model(sessionsCount: Int) -> AtriaHistoryModel {
        AtriaHistoryModel(days: [],
                          sessionsCount: sessionsCount,
                          detectedCount: 0,
                          baselineReady: 0,
                          baselineTarget: 14,
                          detections: [])
    }
}
