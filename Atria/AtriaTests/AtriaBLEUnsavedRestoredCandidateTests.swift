import CoreBluetooth
import XCTest
@testable import Atria

final class AtriaBLEUnsavedRestoredCandidateTests: XCTestCase {
    func testUnsavedConnectingRestorationKeepsBoundedWatchdog() {
        XCTAssertTrue(
            AtriaBLEManager.shouldHoldUnsavedRestoredCandidate(
                state: .connecting,
                hasSavedStrap: false
            )
        )
    }

    func testUnsavedDisconnectingRestorationKeepsBoundedWatchdog() {
        XCTAssertTrue(
            AtriaBLEManager.shouldHoldUnsavedRestoredCandidate(
                state: .disconnecting,
                hasSavedStrap: false
            )
        )
    }

    func testConnectedOrTerminalCandidateDoesNotBlockAcquisition() {
        XCTAssertFalse(
            AtriaBLEManager.shouldHoldUnsavedRestoredCandidate(
                state: .connected,
                hasSavedStrap: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldHoldUnsavedRestoredCandidate(
                state: .disconnected,
                hasSavedStrap: false
            )
        )
    }

    func testSavedStrapKeepsExistingStandingConnectPolicy() {
        XCTAssertFalse(
            AtriaBLEManager.shouldHoldUnsavedRestoredCandidate(
                state: .connecting,
                hasSavedStrap: true
            )
        )
    }
}
