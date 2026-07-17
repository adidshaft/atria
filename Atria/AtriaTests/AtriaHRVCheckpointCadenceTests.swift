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

    func testFourHourCheckpointMarkerSurvivesRelaunch() throws {
        let suiteName = "AtriaHRVCheckpointCadenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Date(timeIntervalSince1970: 80_000)

        SessionStore.persistLiveHRVCheckpointRefreshDate(first, userDefaults: defaults)
        let restored = try XCTUnwrap(
            SessionStore.readLiveHRVCheckpointRefreshDate(userDefaults: defaults)
        )

        XCTAssertEqual(restored, first)
        XCTAssertFalse(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: restored,
            now: first.addingTimeInterval((4 * 60 * 60) - 1),
            rrSampleCount: 10_000,
            duration: 4 * 60 * 60
        ))
        XCTAssertTrue(SessionStore.shouldRefreshHRVOnLiveCheckpoint(
            lastRefreshAt: restored,
            now: first.addingTimeInterval(4 * 60 * 60),
            rrSampleCount: 10_000,
            duration: 4 * 60 * 60
        ))
    }

    func testInvalidPersistedCheckpointMarkerFailsOpen() throws {
        let suiteName = "AtriaHRVCheckpointCadenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-date", forKey: SessionStore.liveHRVCheckpointLastRefreshKey)

        XCTAssertNil(SessionStore.readLiveHRVCheckpointRefreshDate(userDefaults: defaults))
    }
}
