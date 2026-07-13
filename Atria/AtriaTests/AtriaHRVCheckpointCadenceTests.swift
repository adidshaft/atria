import XCTest
@testable import Atria

final class AtriaHRVCheckpointCadenceTests: XCTestCase {
    func testCheckpointDoesNotConsumeCadenceBeforeHRVCanBeReady() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: nil,
            now: now,
            rrSampleCount: 719,
            duration: 4 * 60 * 60
        ))
        XCTAssertFalse(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: nil,
            now: now,
            rrSampleCount: 900,
            duration: (15 * 60) - 1
        ))
    }

    func testFirstEligibleCheckpointRefreshesThenUsesFourHourCadence() {
        let first = Date(timeIntervalSince1970: 20_000)

        XCTAssertTrue(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: nil,
            now: first,
            rrSampleCount: 900,
            duration: 20 * 60
        ))
        XCTAssertFalse(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: first,
            now: first.addingTimeInterval((4 * 60 * 60) - 1),
            rrSampleCount: 10_000,
            duration: 4 * 60 * 60
        ))
        XCTAssertTrue(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: first,
            now: first.addingTimeInterval(4 * 60 * 60),
            rrSampleCount: 10_000,
            duration: 4 * 60 * 60
        ))
    }

    func testClockRollbackAllowsRecoveryInsteadOfFreezingCadence() {
        let futureRefresh = Date(timeIntervalSince1970: 40_000)
        let rolledBackNow = Date(timeIntervalSince1970: 30_000)

        XCTAssertTrue(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: futureRefresh,
            now: rolledBackNow,
            rrSampleCount: 900,
            duration: 20 * 60
        ))
    }
}
