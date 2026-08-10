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

    func testInitialFirstUseAutomaticPlanStartsBroadImmediately() {
        let coldPowerOnStartsBroad =
            AtriaBLEManager.broadScanStartsImmediately(
                reason: "central_powered_on",
                allowBroadScan: true,
                hasEverConnected: false,
                retryCount: 0
            )
        XCTAssertTrue(coldPowerOnStartsBroad)
        XCTAssertTrue(
            AtriaBLEManager.isInitialAutomaticSetupReason(
                "central_powered_on"
            ),
            "the actual cold powered-on handoff must be first-use fast-path authority"
        )
        XCTAssertEqual(
            AtriaBLEManager.scanOrchestrationPlan(
                broadScanAllowed: true,
                useBroadImmediately: coldPowerOnStartsBroad,
                retryCount: 0,
                maximumRetryCount: 4
            ),
            .init(mode: .broad, schedulesWidening: false, schedulesRetry: true),
            "first-use pairing advertisements may omit filtered services"
        )
        XCTAssertFalse(
            AtriaBLEManager.broadScanStartsImmediately(
                reason: "manual",
                allowBroadScan: true,
                hasEverConnected: true,
                retryCount: 0
            ),
            "an established manual scan keeps the filtered-then-widen plan"
        )
    }

    func testSavedManualPlanStagesFilteredThenBroadThenBroadRetry() {
        let filtered = AtriaBLEManager.scanOrchestrationPlan(
            broadScanAllowed: true,
            useBroadImmediately: false,
            retryCount: 0,
            maximumRetryCount: 4
        )
        XCTAssertEqual(
            filtered,
            .init(mode: .filtered, schedulesWidening: true, schedulesRetry: true)
        )

        let widened = AtriaBLEManager.scanOrchestrationPlan(
            broadScanAllowed: true,
            useBroadImmediately: true,
            retryCount: 0,
            maximumRetryCount: 4
        )
        XCTAssertEqual(
            widened,
            .init(mode: .broad, schedulesWidening: false, schedulesRetry: true)
        )

        let retry = AtriaBLEManager.scanOrchestrationPlan(
            broadScanAllowed: true,
            useBroadImmediately: true,
            retryCount: 1,
            maximumRetryCount: 4
        )
        XCTAssertEqual(
            retry,
            .init(mode: .broad, schedulesWidening: false, schedulesRetry: true)
        )

        let exhausted = AtriaBLEManager.scanOrchestrationPlan(
            broadScanAllowed: true,
            useBroadImmediately: true,
            retryCount: 4,
            maximumRetryCount: 4
        )
        XCTAssertEqual(
            exhausted,
            .init(mode: .broad, schedulesWidening: false, schedulesRetry: false)
        )
    }

    func testFilteredOnlyPlanNeverSchedulesBroadWidening() {
        XCTAssertEqual(
            AtriaBLEManager.scanOrchestrationPlan(
                broadScanAllowed: false,
                useBroadImmediately: true,
                retryCount: 0,
                maximumRetryCount: 4
            ),
            .init(mode: .filtered, schedulesWidening: false, schedulesRetry: true)
        )
    }

    func testFirstQualifiedCurrentScanMatchOwnsDeterministically() {
        let candidates: [(name: String, qualifies: Bool)] = [
            ("Polar H10", false),
            ("WHOOP first", true),
            ("WHOOP second", true)
        ]
        var owner: String?

        for candidate in candidates where AtriaBLEManager.shouldClaimCurrentScanCandidate(
            hasStrapIdentity: candidate.qualifies,
            isActivelyScanning: true,
            hasCurrentPeripheralOwner: owner != nil
        ) {
            owner = candidate.name
        }

        XCTAssertEqual(owner, "WHOOP first")
        XCTAssertFalse(
            AtriaBLEManager.shouldClaimCurrentScanCandidate(
                hasStrapIdentity: true,
                isActivelyScanning: false,
                hasCurrentPeripheralOwner: false
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldClaimCurrentScanCandidate(
                hasStrapIdentity: true,
                isActivelyScanning: true,
                hasCurrentPeripheralOwner: true
            )
        )
    }

    func testGenericHeartRateServiceNeverQualifiesAsWHOOPIdentity() {
        XCTAssertFalse(
            AtriaBLEManager.scanCandidateHasStrapIdentity(
                advertisedServices: [CBUUID(string: "180D")],
                advertisedName: nil
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldClaimCurrentScanCandidate(
                hasStrapIdentity: false,
                isActivelyScanning: true,
                hasCurrentPeripheralOwner: false
            )
        )
    }
}
