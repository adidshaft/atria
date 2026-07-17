import XCTest
@testable import Atria

final class AtriaVitalsActivityGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffscreenArchiveNotificationIsRejected() {
        var gate = AtriaVitalsActivityGate(archiveNotificationMinimumInterval: 20)

        XCTAssertFalse(gate.shouldRefreshArchive(isActive: false,
                                                  reason: .notification,
                                                  now: start))
        XCTAssertNil(gate.lastArchiveRefreshAt)
    }

    func testFirstActivationSeedsImmediatelyThenReusesFreshArchiveCache() {
        var gate = AtriaVitalsActivityGate(archiveNotificationMinimumInterval: 120,
                                           activationMinimumInterval: 120)

        XCTAssertTrue(gate.shouldRefreshArchive(isActive: true,
                                                 reason: .activation,
                                                 now: start))
        XCTAssertFalse(gate.shouldRefreshArchive(isActive: true,
                                                  reason: .activation,
                                                  now: start.addingTimeInterval(119.9)))
        XCTAssertTrue(gate.shouldRefreshArchive(isActive: true,
                                                 reason: .activation,
                                                 now: start.addingTimeInterval(120)))
    }

    func testArchiveNotificationsAreThrottledBeforeWorkStarts() {
        var gate = AtriaVitalsActivityGate(archiveNotificationMinimumInterval: 120)

        XCTAssertTrue(gate.shouldRefreshArchive(isActive: true,
                                                 reason: .notification,
                                                 now: start))
        XCTAssertFalse(gate.shouldRefreshArchive(isActive: true,
                                                  reason: .notification,
                                                  now: start.addingTimeInterval(119.9)))
        XCTAssertTrue(gate.shouldRefreshArchive(isActive: true,
                                                 reason: .notification,
                                                 now: start.addingTimeInterval(120)))
    }
}
